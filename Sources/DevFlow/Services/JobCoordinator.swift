import Foundation

@MainActor
final class JobCoordinator {
    private unowned let appState: AppState
    private let gitService = GitService()
    private let aiService = AIService()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(appState: AppState) {
        self.appState = appState
    }

    func start(
        ticket: Ticket,
        repository: RepositoryConfig,
        branch: String,
        provider: AIProvider,
        helperContext: String
    ) async {
        guard appState.activeWorkItem(for: ticket.id) == nil else { return }

        var item = WorkItem(
            ticketID: ticket.id,
            provider: provider,
            repositoryPath: repository.path,
            branch: branch,
            helperContext: helperContext,
            stage: .preparing,
            logs: [JobLogEntry(message: "正在检查仓库：\(repository.displayName)")]
        )
        appState.addOrUpdate(workItem: item)
        appState.setTicketStatus(ticket.id, .processing)
        appState.closeTicketModal()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let validation = await gitService.validateRepository(path: repository.path)
                guard validation.isGitRepository else {
                    throw JobError.repository(validation.message)
                }
                guard validation.isClean else {
                    throw JobError.repository(validation.message)
                }

                append("仓库校验通过，当前分支：\(validation.currentBranch)", to: item.id)
                try await gitService.checkoutBranch(branch, at: repository.path)
                append("已切换到分支：\(branch)", to: item.id)
                setStage(.runningAI, for: item.id)
                append("正在启动 \(provider.rawValue)", to: item.id)

                let execution = try await aiService.run(
                    itemID: item.id,
                    provider: provider,
                    ticket: ticket,
                    repositoryPath: repository.path,
                    helperContext: helperContext
                ) { [weak self] message in
                    Task { @MainActor in self?.append(message, to: item.id) }
                }

                setStage(.reviewing, for: item.id)
                append("正在收集代码差异和修改文件", to: item.id)
                let files = try await gitService.changedFiles(at: repository.path)
                guard !files.isEmpty else {
                    throw JobError.noChanges
                }
                let diff = try await gitService.diff(at: repository.path)
                let report = PromptBuilder.parseReport(
                    finalMessage: execution.finalMessage,
                    rawOutput: execution.rawOutput,
                    changedFiles: files,
                    diff: diff
                )
                updateItem(item.id) {
                    $0.report = report
                    $0.stage = .awaitingApproval
                    $0.updatedAt = Date()
                    $0.logs.append(JobLogEntry(message: "修改报告已生成，等待人工确认"))
                }
            } catch is CancellationError {
                setFailure("任务已取消", stage: .cancelled, for: item.id)
            } catch {
                setFailure(error.localizedDescription, stage: .failed, for: item.id)
            }
            tasks[item.id] = nil
        }

        tasks[item.id] = task
    }

    func cancel(itemID: UUID) {
        aiService.cancel(itemID: itemID)
        tasks[itemID]?.cancel()
        setFailure("用户取消了任务，未执行 commit、push 或工单更新", stage: .cancelled, for: itemID)
    }

    func dismiss(itemID: UUID) {
        updateItem(itemID) { $0.stage = .cancelled }
    }

    func requestRevision(itemID: UUID) {
        updateItem(itemID) {
            $0.stage = .cancelled
            $0.logs.append(JobLogEntry(message: "用户要求继续修改，可重新配置并启动下一轮"))
        }
    }

    func discard(itemID: UUID) {
        guard let item = item(id: itemID) else { return }
        Task {
            do {
                try await gitService.restoreUncommittedChanges(at: item.repositoryPath)
                updateItem(itemID) {
                    $0.stage = .cancelled
                    $0.logs.append(JobLogEntry(message: "已放弃本轮修改并恢复未提交文件"))
                }
                appState.closeTicketModal()
            } catch {
                setFailure("放弃修改失败：\(error.localizedDescription)", stage: .failed, for: itemID)
            }
        }
    }

    func approveAndDeliver(itemID: UUID, commitMessage: String, manualAssignee: String) async {
        guard let currentItem = item(id: itemID), let ticket = appState.tickets.first(where: { $0.id == currentItem.ticketID }) else { return }
        guard currentItem.stage == .awaitingApproval else { return }
        let repository = appState.repositories.first { $0.path == currentItem.repositoryPath }
        let remote = repository?.remoteName ?? "origin"

        do {
            let deliveryAssignee = try deliveryAssignee(for: ticket, manualAssignee: manualAssignee)
            setStage(.committing, for: itemID)
            append("正在创建本地 commit", to: itemID)
            let commitHash = try await gitService.commit(message: commitMessage, at: currentItem.repositoryPath)
            updateItem(itemID) { $0.commitHash = commitHash }
            append("本地 commit 完成：\(String(commitHash.prefix(8)))", to: itemID)

            setStage(.pulling, for: itemID)
            append("正在从 \(remote)/\(currentItem.branch) 拉取最新代码", to: itemID)
            let pull = try await gitService.pullLatest(remote: remote, branch: currentItem.branch, at: currentItem.repositoryPath)
            if !pull.conflicts.isEmpty {
                let files = pull.conflicts.joined(separator: "、")
                setFailure("拉取发生冲突，已停止 push。请人工合并：\(files)", stage: .failed, for: itemID)
                return
            }
            append(pull.hadRemoteBranch ? "已拉取并应用远程最新代码" : pull.output, to: itemID)

            setStage(.pushing, for: itemID)
            append("正在 push 到 \(remote)/\(currentItem.branch)", to: itemID)
            try await gitService.push(remote: remote, branch: currentItem.branch, at: currentItem.repositoryPath)
            append("代码 push 成功", to: itemID)

            setStage(.updatingTicket, for: itemID)
            if ticket.sourceURL == nil {
                append("当前为示例工单，未绑定知识库地址，跳过远程工单更新", to: itemID)
            } else {
                do {
                    try await appState.knowledgeBaseSession.updateTicket(ticket: ticket, statusName: "待测试", assignee: deliveryAssignee)
                    append(deliveryLogMessage(for: ticket, assignee: deliveryAssignee), to: itemID)
                } catch {
                    setFailure("代码已 push，但工单更新失败：\(error.localizedDescription)。仅可重试工单更新。", stage: .partial, for: itemID)
                    return
                }
            }

            updateItem(itemID) {
                $0.stage = .completed
                $0.updatedAt = Date()
                $0.logs.append(JobLogEntry(message: "交付流程已完成"))
            }
            applyDeliveredTicketState(ticketID: ticket.id, assignee: deliveryAssignee)
        } catch {
            setFailure(error.localizedDescription, stage: .failed, for: itemID)
        }
    }

    func retryTicketUpdate(itemID: UUID, manualAssignee: String) async {
        guard let currentItem = item(id: itemID), currentItem.stage == .partial,
              let ticket = appState.tickets.first(where: { $0.id == currentItem.ticketID }) else { return }
        do {
            let deliveryAssignee = try deliveryAssignee(for: ticket, manualAssignee: manualAssignee)
            setStage(.updatingTicket, for: itemID)
            try await appState.knowledgeBaseSession.updateTicket(ticket: ticket, statusName: "待测试", assignee: deliveryAssignee)
            updateItem(itemID) {
                $0.stage = .completed
                $0.errorMessage = nil
                $0.logs.append(JobLogEntry(message: deliveryLogMessage(for: ticket, assignee: deliveryAssignee)))
            }
            applyDeliveredTicketState(ticketID: ticket.id, assignee: deliveryAssignee)
        } catch {
            setFailure("工单更新仍然失败：\(error.localizedDescription)", stage: .partial, for: itemID)
        }
    }

    private func item(id: UUID) -> WorkItem? {
        appState.workItems.first { $0.id == id }
    }

    private func deliveryAssignee(for ticket: Ticket, manualAssignee: String) throws -> String {
        if ticket.kind == .feature {
            return ""
        }
        if ticket.requiresAuthorReassignment {
            let author = ticket.normalizedAuthor
            if author.isEmpty, ticket.sourceURL != nil {
                throw JobError.missingTicketAuthor
            }
            return author
        }
        return manualAssignee.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func deliveryLogMessage(for ticket: Ticket, assignee: String) -> String {
        if ticket.kind == .feature {
            return "工单已转为待测试，负责人保持不变"
        }
        if ticket.requiresAuthorReassignment {
            return assignee.isEmpty
                ? "工单已转为待测试，未获取到创建人，负责人保持不变"
                : "工单已转为待测试并转交给创建人 \(assignee)"
        }
        return assignee.isEmpty
            ? "工单已转为待测试，负责人保持不变"
            : "工单已转为待测试并转交给 \(assignee)"
    }

    private func applyDeliveredTicketState(ticketID: Int, assignee: String) {
        guard let index = appState.tickets.firstIndex(where: { $0.id == ticketID }) else { return }
        appState.tickets[index].status = .testing
        if !assignee.isEmpty {
            appState.tickets[index].assignee = assignee
        }
        appState.persistState()
    }

    private func append(_ message: String, to itemID: UUID, level: String = "info") {
        updateItem(itemID) {
            $0.logs.append(JobLogEntry(message: message, level: level))
            $0.updatedAt = Date()
        }
    }

    private func setStage(_ stage: JobStage, for itemID: UUID) {
        updateItem(itemID) {
            $0.stage = stage
            $0.updatedAt = Date()
        }
    }

    private func setFailure(_ message: String, stage: JobStage, for itemID: UUID) {
        updateItem(itemID) {
            $0.stage = stage
            $0.errorMessage = message
            $0.updatedAt = Date()
            $0.logs.append(JobLogEntry(message: message, level: "error"))
        }
    }

    private func updateItem(_ itemID: UUID, mutation: (inout WorkItem) -> Void) {
        guard var item = item(id: itemID) else { return }
        mutation(&item)
        appState.addOrUpdate(workItem: item)
    }
}

enum JobError: LocalizedError {
    case repository(String)
    case noChanges
    case missingTicketAuthor

    var errorDescription: String? {
        switch self {
        case let .repository(message): message
        case .noChanges: "AI 未产生代码改动，请查看执行日志后重新尝试"
        case .missingTicketAuthor: "未获取到工单创建人，无法按规则转交。请先刷新工单后再执行人工审批。"
        }
    }
}
