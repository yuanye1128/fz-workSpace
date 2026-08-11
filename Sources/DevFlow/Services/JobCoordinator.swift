import Foundation

@MainActor
final class JobCoordinator {
    private unowned let appState: AppState
    private let gitService = GitService()
    private let aiService = AIService()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var didRecoverPersistedJobs = false

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

        let item = WorkItem(
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

        startAnalysis(for: item, ticket: ticket, repository: repository)
    }

    func approveAnalysisPlan(itemID: UUID) {
        guard let item = item(id: itemID), item.stage == .awaitingPlanApproval,
              let ticket = appState.tickets.first(where: { $0.id == item.ticketID }) else { return }

        updateItem(itemID) {
            $0.stage = .runningAI
            $0.execution = nil
            $0.errorMessage = nil
            $0.updatedAt = Date()
            $0.logs.append(JobLogEntry(message: "修改方案已确认，正在开始修改代码"))
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let execution = try await aiService.run(
                    provider: item.provider,
                    ticket: ticket,
                    repositoryPath: item.repositoryPath,
                    helperContext: item.helperContext,
                    mode: .modification(confirmedPlan: item.analysisPlan ?? ""),
                    onStarted: { [weak self] execution in
                        await self?.recordStartedExecution(execution, for: item.id)
                    },
                    onEvent: { [weak self] event in
                        await self?.handle(event, for: item.id)
                    }
                )
                try await completeModification(execution, for: item.id)
            } catch is CancellationError {
                guard self.item(id: item.id)?.stage != .cancelled else {
                    tasks[item.id] = nil
                    return
                }
                setFailure("任务已取消", stage: .cancelled, for: item.id)
            } catch DurableExecutionError.interrupted {
                setInterrupted(for: item.id)
            } catch {
                setFailure(error.localizedDescription, stage: .failed, for: item.id)
            }
            tasks[item.id] = nil
        }

        tasks[item.id] = task
    }

    private func startAnalysis(for item: WorkItem, ticket: Ticket, repository: RepositoryConfig) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let validation = await gitService.validateRepository(path: repository.path)
                guard validation.isGitRepository else {
                    throw JobError.repository(validation.message)
                }
                if validation.isClean {
                    append("仓库校验通过，当前分支：\(validation.currentBranch)", to: item.id)
                } else {
                    append("检测到本地未提交改动，已保留并继续；当前分支：\(validation.currentBranch)", to: item.id)
                }
                try await gitService.checkoutBranch(item.branch, at: repository.path)
                append("已切换到分支：\(item.branch)", to: item.id)
                setStage(.analyzing, for: item.id)
                append("正在使用 \(item.provider.rawValue) 分析问题和生成修改方案", to: item.id)

                let execution = try await aiService.run(
                    provider: item.provider,
                    ticket: ticket,
                    repositoryPath: repository.path,
                    helperContext: item.helperContext,
                    mode: .analysis,
                    onStarted: { [weak self] execution in
                        await self?.recordStartedExecution(execution, for: item.id)
                    },
                    onEvent: { [weak self] event in
                        await self?.handle(event, for: item.id)
                    }
                )
                completeAnalysis(execution, for: item.id)
            } catch is CancellationError {
                guard self.item(id: item.id)?.stage != .cancelled else {
                    tasks[item.id] = nil
                    return
                }
                setFailure("任务已取消", stage: .cancelled, for: item.id)
            } catch DurableExecutionError.interrupted {
                setInterrupted(for: item.id)
            } catch {
                setFailure(error.localizedDescription, stage: .failed, for: item.id)
            }
            tasks[item.id] = nil
        }

        tasks[item.id] = task
    }

    func cancel(itemID: UUID) {
        if let execution = item(id: itemID)?.execution {
            aiService.cancel(execution: execution)
        }
        tasks[itemID]?.cancel()
        setFailure("用户取消了任务，未执行 commit、push 或工单更新", stage: .cancelled, for: itemID)
    }

    func recoverPersistedJobs() {
        guard !didRecoverPersistedJobs else { return }
        didRecoverPersistedJobs = true
        let recoverableIDs = appState.workItems
            .filter { $0.stage == .analyzing || $0.stage == .runningAI || $0.stage == .reviewing }
            .map(\.id)
        recoverableIDs.forEach { recover(itemID: $0) }
    }

    func recover(itemID: UUID) {
        guard tasks[itemID] == nil, let currentItem = item(id: itemID) else { return }
        guard let execution = currentItem.execution,
              execution.phase == expectedPhase(for: currentItem.stage) || currentItem.stage == .interrupted else {
            setInterrupted(for: itemID)
            return
        }

        updateItem(itemID) {
            $0.stage = execution.phase == .analysis ? .analyzing : .runningAI
            $0.errorMessage = nil
            $0.execution?.state = .reconnecting
            $0.updatedAt = Date()
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                switch aiService.inspect(execution: execution) {
                case .running:
                    updateItem(itemID) {
                        $0.execution?.state = .recovered
                        $0.logs.append(JobLogEntry(message: "已恢复后台任务，正在继续接收日志"))
                        $0.updatedAt = Date()
                    }
                case .completed:
                    append("后台任务已完成，正在恢复执行结果", to: itemID)
                case .interrupted:
                    setInterrupted(for: itemID)
                    tasks[itemID] = nil
                    return
                }

                let result = try await aiService.resume(
                    execution: execution,
                    provider: currentItem.provider
                ) { [weak self] event in
                    await self?.handle(event, for: itemID)
                }
                if execution.phase == .analysis {
                    completeAnalysis(result, for: itemID)
                } else {
                    try await completeModification(result, for: itemID)
                }
            } catch is CancellationError {
                if self.item(id: itemID)?.stage != .cancelled {
                    setFailure("任务已取消", stage: .cancelled, for: itemID)
                }
            } catch DurableExecutionError.interrupted {
                setInterrupted(for: itemID)
            } catch {
                setFailure(error.localizedDescription, stage: .failed, for: itemID)
            }
            tasks[itemID] = nil
        }
        tasks[itemID] = task
    }

    func dismiss(itemID: UUID) {
        updateItem(itemID) { $0.stage = .cancelled }
    }

    func requestRevision(itemID: UUID) {
        updateItem(itemID) {
            let message = $0.stage == .awaitingPlanApproval
                ? "用户要求重新配置后再生成修改方案"
                : "用户要求继续修改，可重新配置并启动下一轮"
            $0.stage = .cancelled
            $0.logs.append(JobLogEntry(message: message))
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

    private func expectedPhase(for stage: JobStage) -> AIExecutionPhase? {
        switch stage {
        case .analyzing: .analysis
        case .runningAI, .reviewing: .modification
        default: nil
        }
    }

    private func recordStartedExecution(_ execution: AIExecutionRecord, for itemID: UUID) {
        updateItem(itemID) {
            var runningExecution = execution
            runningExecution.state = .running
            $0.execution = runningExecution
            $0.errorMessage = nil
            $0.updatedAt = Date()
        }
    }

    private func handle(_ event: AIExecutionStreamEvent, for itemID: UUID) {
        guard let message = event.displayMessage, !message.isEmpty else { return }
        updateItem(itemID) {
            $0.execution?.lastOutputOffset = event.byteOffset
            if $0.execution?.state != .recovered {
                $0.execution?.state = .running
            }
            $0.logs.append(JobLogEntry(message: message))
            $0.updatedAt = Date()
        }
    }

    private func completeAnalysis(_ execution: AIExecutionResult, for itemID: UUID) {
        updateItem(itemID) {
            $0.analysisPlan = execution.finalMessage
            $0.stage = .awaitingPlanApproval
            $0.execution?.state = .completed
            $0.errorMessage = nil
            $0.updatedAt = Date()
            $0.logs.append(JobLogEntry(message: "分析与修改方案已生成，等待用户确认"))
        }
    }

    private func completeModification(_ execution: AIExecutionResult, for itemID: UUID) async throws {
        guard let currentItem = item(id: itemID) else { return }
        setStage(.reviewing, for: itemID)
        append("正在收集代码差异和修改文件", to: itemID)
        let files = try await gitService.changedFiles(at: currentItem.repositoryPath)
        guard !files.isEmpty else { throw JobError.noChanges }
        let diff = try await gitService.diff(at: currentItem.repositoryPath)
        let report = PromptBuilder.parseReport(
            finalMessage: execution.finalMessage,
            rawOutput: execution.rawOutput,
            changedFiles: files,
            diff: diff
        )
        updateItem(itemID) {
            $0.report = report
            $0.stage = .awaitingApproval
            $0.execution?.state = .completed
            $0.errorMessage = nil
            $0.updatedAt = Date()
            $0.logs.append(JobLogEntry(message: "修改报告已生成，等待人工确认"))
        }
    }

    private func setInterrupted(for itemID: UUID) {
        updateItem(itemID) {
            $0.stage = .interrupted
            $0.execution?.state = .interrupted
            $0.errorMessage = "未检测到仍在运行的 AI 后台进程，也没有找到完整执行结果。"
            $0.updatedAt = Date()
            if $0.logs.last?.message != $0.errorMessage {
                $0.logs.append(JobLogEntry(message: $0.errorMessage ?? "执行已中断", level: "error"))
            }
        }
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
            if stage == .cancelled {
                $0.execution?.state = .interrupted
            } else if stage == .failed {
                $0.execution?.state = .completed
            }
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
