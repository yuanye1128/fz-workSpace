import Foundation

@MainActor
final class JobCoordinator {
    private unowned let appState: AppState
    private let gitService = GitService()
    private let aiService = AIService()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var didRecoverPersistedJobs = false
    /// 同一主仓库的 merge/push 串行，避免并行合回互相踩踏。
    private var repositoryMergeBusy: Set<String> = []
    private var repositoryMergeWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(appState: AppState) {
        self.appState = appState
    }

    func start(
        ticket: Ticket,
        repository: RepositoryConfig,
        branch: String,
        provider: AIProvider,
        modelID: String?,
        reasoningEffort: String?,
        helperContext: String
    ) async {
        guard appState.activeWorkItem(for: ticket.id) == nil else { return }
        guard !ticket.kind.usesRequirementPlanning else { return }

        let itemID = UUID()
        let taskBranch = "devflow/\(ticket.id)-\(String(itemID.uuidString.prefix(8)).lowercased())"
        let worktreePath = Self.worktreePath(
            repositoryPath: repository.path,
            ticketID: ticket.id,
            itemID: itemID,
            kind: "task"
        )

        let item = WorkItem(
            id: itemID,
            ticketID: ticket.id,
            provider: provider,
            modelID: modelID,
            reasoningEffort: reasoningEffort,
            repositoryPath: repository.path,
            branch: branch,
            taskBranch: taskBranch,
            worktreePath: worktreePath,
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
                    modelID: item.modelID,
                    reasoningEffort: item.reasoningEffort,
                    ticket: ticket,
                    repositoryPath: item.workingDirectory,
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

    /// 确认方案阶段：用户补充说明后重新分析并更新方案。
    func reviseAnalysisPlan(itemID: UUID, userNote: String) {
        let note = userNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty,
              let item = item(id: itemID), item.stage == .awaitingPlanApproval,
              let ticket = appState.tickets.first(where: { $0.id == item.ticketID }) else { return }

        let previousPlan = item.analysisPlan ?? ""
        let mergedHelper: String = {
            if item.helperContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "用户补充：\(note)"
            }
            return item.helperContext + "\n用户补充：\(note)"
        }()

        updateItem(itemID) {
            $0.helperContext = mergedHelper
            $0.stage = .analyzing
            $0.execution = nil
            $0.errorMessage = nil
            $0.updatedAt = Date()
            $0.logs.append(JobLogEntry(message: "用户补充：\(note)"))
            $0.logs.append(JobLogEntry(message: "正在根据补充信息修订分析方案"))
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let execution = try await aiService.run(
                    provider: item.provider,
                    modelID: item.modelID,
                    reasoningEffort: item.reasoningEffort,
                    ticket: ticket,
                    repositoryPath: item.workingDirectory,
                    helperContext: mergedHelper,
                    mode: .analysisRevision(previousPlan: previousPlan, userNote: note),
                    onStarted: { [weak self] execution in
                        await self?.recordStartedExecution(execution, for: item.id)
                    },
                    onEvent: { [weak self] event in
                        await self?.handle(event, for: item.id)
                    }
                )
                try completeAnalysis(execution, for: item.id)
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
                let mainBranchBefore = validation.currentBranch
                if validation.isClean {
                    append("仓库校验通过，主仓库当前分支：\(mainBranchBefore)（保持不动）", to: item.id)
                } else {
                    append("主仓库有未提交改动，已保留；当前分支：\(mainBranchBefore)（保持不动）", to: item.id)
                }

                if let worktreePath = item.worktreePath, let taskBranch = item.taskBranch {
                    try await gitService.createTaskWorktree(
                        repositoryPath: repository.path,
                        targetBranch: item.branch,
                        taskBranch: taskBranch,
                        worktreePath: worktreePath
                    )
                    let mainBranchAfter = try await gitService.currentBranch(at: repository.path)
                    append("已创建独立 worktree：\(worktreePath)", to: item.id)
                    append("任务分支：\(taskBranch) ← 基于 \(item.branch)", to: item.id)
                    if mainBranchAfter != mainBranchBefore {
                        throw JobError.repository("创建 worktree 后主仓库分支从 \(mainBranchBefore) 变为 \(mainBranchAfter)，已中止")
                    }
                } else {
                    try await gitService.checkoutBranch(item.branch, at: repository.path)
                    append("已切换到分支：\(item.branch)", to: item.id)
                }

                setStage(.analyzing, for: item.id)
                append("正在使用 \(providerDescription(for: item)) 分析问题和生成修改方案", to: item.id)

                let execution = try await aiService.run(
                    provider: item.provider,
                    modelID: item.modelID,
                    reasoningEffort: item.reasoningEffort,
                    ticket: ticket,
                    repositoryPath: item.workingDirectory,
                    helperContext: item.helperContext,
                    mode: .analysis,
                    onStarted: { [weak self] execution in
                        await self?.recordStartedExecution(execution, for: item.id)
                    },
                    onEvent: { [weak self] event in
                        await self?.handle(event, for: item.id)
                    }
                )
                try completeAnalysis(execution, for: item.id)
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
        Task { await cleanupWorktreesIfNeeded(itemID: itemID, deleteTaskBranch: true) }
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
                    try completeAnalysis(result, for: itemID)
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
                if let worktreePath = item.worktreePath {
                    try await gitService.removeWorktree(worktreePath: worktreePath, repositoryPath: item.repositoryPath)
                    if let taskBranch = item.taskBranch {
                        try await gitService.deleteBranch(taskBranch, at: item.repositoryPath)
                    }
                    if let mergePath = item.mergeWorktreePath {
                        try await gitService.removeWorktree(worktreePath: mergePath, repositoryPath: item.repositoryPath)
                    }
                    updateItem(itemID) {
                        $0.stage = .cancelled
                        $0.worktreePath = nil
                        $0.mergeWorktreePath = nil
                        $0.logs.append(JobLogEntry(message: "已放弃本轮修改并移除任务 worktree"))
                    }
                } else {
                    try await gitService.restoreUncommittedChanges(at: item.repositoryPath)
                    updateItem(itemID) {
                        $0.stage = .cancelled
                        $0.logs.append(JobLogEntry(message: "已放弃本轮修改并恢复未提交文件"))
                    }
                }
                appState.closeTicketModal()
            } catch {
                setFailure("放弃修改失败：\(error.localizedDescription)", stage: .failed, for: itemID)
            }
        }
    }

    func approveAndDeliver(
        itemID: UUID,
        commitMessage: String,
        manualAssignee: String,
        reassignToAuthor: Bool = true
    ) async {
        guard let currentItem = item(id: itemID), let ticket = appState.tickets.first(where: { $0.id == currentItem.ticketID }) else { return }
        guard currentItem.stage == .awaitingApproval else { return }
        let repository = appState.repositories.first { $0.path == currentItem.repositoryPath }
        let remote = repository?.remoteName ?? "origin"

        do {
            let deliveryAssignee = try deliveryAssignee(
                for: ticket,
                manualAssignee: manualAssignee,
                reassignToAuthor: reassignToAuthor
            )

            if currentItem.worktreePath != nil, currentItem.taskBranch != nil {
                try await deliverViaWorktreeMerge(
                    itemID: itemID,
                    ticket: ticket,
                    remote: remote,
                    commitMessage: commitMessage,
                    deliveryAssignee: deliveryAssignee,
                    reassignToAuthor: reassignToAuthor
                )
            } else {
                try await deliverInPlace(
                    itemID: itemID,
                    ticket: ticket,
                    remote: remote,
                    commitMessage: commitMessage,
                    deliveryAssignee: deliveryAssignee,
                    reassignToAuthor: reassignToAuthor
                )
            }
        } catch {
            setFailure(error.localizedDescription, stage: .failed, for: itemID)
        }
    }

    private func deliverViaWorktreeMerge(
        itemID: UUID,
        ticket: Ticket,
        remote: String,
        commitMessage: String,
        deliveryAssignee: String,
        reassignToAuthor: Bool
    ) async throws {
        guard let currentItem = item(id: itemID),
              let worktreePath = currentItem.worktreePath,
              let taskBranch = currentItem.taskBranch else { return }

        let mainBranchBefore = try await gitService.currentBranch(at: currentItem.repositoryPath)

        setStage(.committing, for: itemID)
        append("正在任务 worktree 创建本地 commit", to: itemID)
        let commitHash = try await gitService.commit(message: commitMessage, at: worktreePath)
        updateItem(itemID) { $0.commitHash = commitHash }
        append("本地 commit 完成：\(String(commitHash.prefix(8)))", to: itemID)

        try await withRepositoryMergeLock(currentItem.repositoryPath) {
            let mergePath = Self.worktreePath(
                repositoryPath: currentItem.repositoryPath,
                ticketID: currentItem.ticketID,
                itemID: itemID,
                kind: "merge"
            )
            let mergeBranch = "devflow/merge-\(currentItem.ticketID)-\(String(itemID.uuidString.prefix(8)).lowercased())"

            setStage(.pulling, for: itemID)
            append("正在准备目标分支 \(currentItem.branch) 的合并工作区（主仓库分支保持不动）", to: itemID)
            try await gitService.createMergeWorktree(
                repositoryPath: currentItem.repositoryPath,
                targetBranch: currentItem.branch,
                mergeBranch: mergeBranch,
                worktreePath: mergePath
            )
            updateItem(itemID) { $0.mergeWorktreePath = mergePath }

            let pull = try await gitService.pullLatest(remote: remote, branch: currentItem.branch, at: mergePath)
            if !pull.conflicts.isEmpty {
                let files = pull.conflicts.joined(separator: "、")
                throw JobError.needsManualGit(
                    "拉取目标分支发生冲突，请在合并工作区自行处理：\(mergePath)\n冲突文件：\(files)"
                )
            }
            append(pull.hadRemoteBranch ? "已同步远程 \(currentItem.branch) 最新代码" : pull.output, to: itemID)

            setStage(.merging, for: itemID)
            append("正在将 \(taskBranch) squash 合回 \(currentItem.branch)", to: itemID)
            let merge = try await gitService.squashMergeBranch(
                taskBranch,
                intoCheckoutAt: mergePath,
                message: commitMessage
            )
            if !merge.success {
                if merge.conflicts.isEmpty {
                    throw JobError.needsManualGit(
                        "自动 squash 合回未能确定结果，请在合并工作区自行处理：\(mergePath)\n\(merge.output)"
                    )
                }
                let files = merge.conflicts.joined(separator: "、")
                throw JobError.needsManualGit(
                    "squash 合回冲突，请在合并工作区自行解决后推送：\(mergePath)\n冲突文件：\(files)"
                )
            }
            append("squash 合回成功：\(String((merge.mergedCommitHash ?? "").prefix(8)))", to: itemID)

            setStage(.pushing, for: itemID)
            append("正在 push \(currentItem.branch) 到 \(remote)", to: itemID)
            try await gitService.pushHEAD(toRemoteBranch: currentItem.branch, remote: remote, at: mergePath)
            if let hash = merge.mergedCommitHash {
                try await gitService.updateLocalBranchRef(currentItem.branch, to: hash, at: currentItem.repositoryPath)
            }
            append("代码 push 成功（已合回 \(currentItem.branch)）", to: itemID)

            try await gitService.removeWorktree(worktreePath: mergePath, repositoryPath: currentItem.repositoryPath)
            try await gitService.deleteBranch(mergeBranch, at: currentItem.repositoryPath)
            try await gitService.removeWorktree(worktreePath: worktreePath, repositoryPath: currentItem.repositoryPath)
            try await gitService.deleteBranch(taskBranch, at: currentItem.repositoryPath)
            updateItem(itemID) {
                $0.mergeWorktreePath = nil
                $0.worktreePath = nil
                $0.taskBranch = nil
            }

            let mainBranchAfter = try await gitService.currentBranch(at: currentItem.repositoryPath)
            if mainBranchAfter != mainBranchBefore {
                append("警告：主仓库当前分支从 \(mainBranchBefore) 变为 \(mainBranchAfter)", to: itemID, level: "error")
            } else {
                append("主仓库当前分支未变动：\(mainBranchBefore)", to: itemID)
            }
        }

        setStage(.updatingTicket, for: itemID)
        if ticket.sourceURL == nil {
                append("当前为本地测试工单，跳过远程工单更新", to: itemID)
        } else {
            do {
                try await appState.knowledgeBaseSession.updateTicket(
                    ticket: ticket,
                    statusName: "待测试",
                    assignee: deliveryAssignee
                )
                append(deliveryLogMessage(for: ticket, assignee: deliveryAssignee, reassignToAuthor: reassignToAuthor), to: itemID)
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
    }

    private func deliverInPlace(
        itemID: UUID,
        ticket: Ticket,
        remote: String,
        commitMessage: String,
        deliveryAssignee: String,
        reassignToAuthor: Bool
    ) async throws {
        guard let currentItem = item(id: itemID) else { return }

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
                append("当前为本地测试工单，跳过远程工单更新", to: itemID)
        } else {
            do {
                try await appState.knowledgeBaseSession.updateTicket(
                    ticket: ticket,
                    statusName: "待测试",
                    assignee: deliveryAssignee
                )
                append(deliveryLogMessage(for: ticket, assignee: deliveryAssignee, reassignToAuthor: reassignToAuthor), to: itemID)
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
    }

    func retryTicketUpdate(itemID: UUID, manualAssignee: String, reassignToAuthor: Bool = true) async {
        guard let currentItem = item(id: itemID), currentItem.stage == .partial,
              let ticket = appState.tickets.first(where: { $0.id == currentItem.ticketID }) else { return }
        do {
            let deliveryAssignee = try deliveryAssignee(
                for: ticket,
                manualAssignee: manualAssignee,
                reassignToAuthor: reassignToAuthor
            )
            setStage(.updatingTicket, for: itemID)
            try await appState.knowledgeBaseSession.updateTicket(
                ticket: ticket,
                statusName: "待测试",
                assignee: deliveryAssignee
            )
            updateItem(itemID) {
                $0.stage = .completed
                $0.errorMessage = nil
                $0.logs.append(JobLogEntry(message: deliveryLogMessage(for: ticket, assignee: deliveryAssignee, reassignToAuthor: reassignToAuthor)))
            }
            applyDeliveredTicketState(ticketID: ticket.id, assignee: deliveryAssignee)
        } catch {
            setFailure("工单更新仍然失败：\(error.localizedDescription)", stage: .partial, for: itemID)
        }
    }

    private func item(id: UUID) -> WorkItem? {
        appState.workItems.first { $0.id == id }
    }

    private func providerDescription(for item: WorkItem) -> String {
        var parts = [item.provider.rawValue]
        if let modelID = item.modelID, !modelID.isEmpty {
            parts.append(modelID)
        }
        if let effort = item.reasoningEffort, !effort.isEmpty {
            parts.append(AIReasoningEffort.displayName(for: effort))
        }
        return parts.joined(separator: " · ")
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

    private func completeAnalysis(_ execution: AIExecutionResult, for itemID: UUID) throws {
        guard PromptBuilder.hasRequiredProtocolMarkers(execution.finalMessage, phase: .analysis) else {
            throw AIExecutionError.incompleteProtocolOutput(.analysis)
        }
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
        guard PromptBuilder.hasRequiredProtocolMarkers(execution.finalMessage, phase: .modification) else {
            throw AIExecutionError.incompleteProtocolOutput(.modification)
        }
        guard let currentItem = item(id: itemID) else { return }
        setStage(.reviewing, for: itemID)
        append("正在收集代码差异和修改文件", to: itemID)
        let files = try await gitService.changedFiles(at: currentItem.workingDirectory)
        guard !files.isEmpty else { throw JobError.noChanges }
        let diff = try await gitService.diff(at: currentItem.workingDirectory)
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

    private func deliveryAssignee(
        for ticket: Ticket,
        manualAssignee: String,
        reassignToAuthor: Bool = true
    ) throws -> String {
        if ticket.kind == .feature {
            return ""
        }
        if ticket.requiresAuthorReassignment {
            guard reassignToAuthor else { return "" }
            let author = ticket.normalizedAuthor
            if author.isEmpty, ticket.sourceURL != nil {
                throw JobError.missingTicketAuthor
            }
            return author
        }
        return manualAssignee.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func deliveryLogMessage(
        for ticket: Ticket,
        assignee: String,
        reassignToAuthor: Bool = true
    ) -> String {
        if ticket.kind == .feature {
            return "工单已转为待测试，负责人保持不变"
        }
        if ticket.requiresAuthorReassignment {
            if !reassignToAuthor {
                return "工单已转为待测试，按选择未转交创建人"
            }
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

    private func withRepositoryMergeLock(_ repositoryPath: String, _ body: () async throws -> Void) async throws {
        while repositoryMergeBusy.contains(repositoryPath) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                repositoryMergeWaiters[repositoryPath, default: []].append(continuation)
            }
        }
        repositoryMergeBusy.insert(repositoryPath)
        defer {
            repositoryMergeBusy.remove(repositoryPath)
            let waiters = repositoryMergeWaiters.removeValue(forKey: repositoryPath) ?? []
            waiters.forEach { $0.resume() }
        }
        try await body()
    }

    private func cleanupWorktreesIfNeeded(itemID: UUID, deleteTaskBranch: Bool) async {
        guard let current = item(id: itemID) else { return }
        if let mergePath = current.mergeWorktreePath {
            try? await gitService.removeWorktree(worktreePath: mergePath, repositoryPath: current.repositoryPath)
        }
        if let worktreePath = current.worktreePath {
            try? await gitService.removeWorktree(worktreePath: worktreePath, repositoryPath: current.repositoryPath)
        }
        if deleteTaskBranch, let taskBranch = current.taskBranch {
            try? await gitService.deleteBranch(taskBranch, at: current.repositoryPath)
        }
        updateItem(itemID) {
            $0.worktreePath = nil
            $0.mergeWorktreePath = nil
            if deleteTaskBranch { $0.taskBranch = nil }
        }
    }

    static func worktreePath(repositoryPath: String, ticketID: Int, itemID: UUID, kind: String) -> String {
        let repo = URL(fileURLWithPath: repositoryPath)
        let short = String(itemID.uuidString.prefix(8)).lowercased()
        return repo
            .deletingLastPathComponent()
            .appendingPathComponent(".devflow-worktrees")
            .appendingPathComponent(repo.lastPathComponent)
            .appendingPathComponent("\(kind)-\(ticketID)-\(short)")
            .path
    }
}

enum JobError: LocalizedError {
    case repository(String)
    case noChanges
    case missingTicketAuthor
    case needsManualGit(String)

    var errorDescription: String? {
        switch self {
        case let .repository(message): message
        case .noChanges: "AI 未产生代码改动，请查看执行日志后重新尝试"
        case .missingTicketAuthor: "未获取到工单创建人，无法按规则转交。请先刷新工单后再执行人工审批。"
        case let .needsManualGit(message): message
        }
    }
}
