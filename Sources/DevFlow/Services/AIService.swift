import Foundation

struct AIExecutionResult: Sendable {
    var finalMessage: String
    var rawOutput: String
}

struct AIExecutionStreamEvent: Sendable {
    var displayMessage: String?
    var byteOffset: Int64
}

enum AIExecutionMode: Sendable {
    case analysis
    case analysisRevision(previousPlan: String, userNote: String)
    case modification(confirmedPlan: String)

    var isAnalysis: Bool {
        switch self {
        case .analysis, .analysisRevision: true
        case .modification: false
        }
    }

    var phase: AIExecutionPhase {
        isAnalysis ? .analysis : .modification
    }
}

enum AIExecutionError: LocalizedError {
    case pendingUserInteraction(String)
    case incompleteProtocolOutput(AIExecutionPhase)

    var errorDescription: String? {
        switch self {
        case let .pendingUserInteraction(detail):
            "CLI 仍有未处理的确认请求（流水线为非交互，不会向用户弹窗）：\(detail)"
        case .incompleteProtocolOutput(.analysis):
            "分析未输出完整方案：Cursor 结束时没有 DEVFLOW 段落，也没有 createPlan 方案。请重试。"
        case .incompleteProtocolOutput(.modification):
            "编码未输出完整结果（缺少 DEVFLOW_SUMMARY / DEVFLOW_REASONING / DEVFLOW_TESTS / DEVFLOW_RISKS），不能进入交付确认。请重试。"
        }
    }
}

final class AIService: @unchecked Sendable {
    private let runner: DurableProcessRunner

    init(runner: DurableProcessRunner = DurableProcessRunner()) {
        self.runner = runner
    }

    func run(
        provider: AIProvider,
        modelID: String? = nil,
        reasoningEffort: String? = nil,
        ticket: Ticket,
        repositoryPath: String,
        helperContext: String,
        mode: AIExecutionMode,
        onStarted: @escaping @Sendable (AIExecutionRecord) async -> Void,
        onEvent: @escaping @Sendable (AIExecutionStreamEvent) async -> Void
    ) async throws -> AIExecutionResult {
        let prompt: String
        switch mode {
        case .analysis:
            prompt = PromptBuilder.buildAnalysis(ticket: ticket, helperContext: helperContext)
        case let .analysisRevision(previousPlan, userNote):
            prompt = PromptBuilder.buildAnalysisRevision(
                ticket: ticket,
                helperContext: helperContext,
                previousPlan: previousPlan,
                userNote: userNote
            )
        case let .modification(confirmedPlan):
            prompt = PromptBuilder.build(ticket: ticket, helperContext: helperContext, confirmedPlan: confirmedPlan)
        }
        let command: String
        let arguments: [String]

        switch provider {
        case .codex:
            command = "codex"
            var args = [
                "exec",
                "--json",
                "--sandbox", mode.isAnalysis ? "read-only" : "workspace-write",
                "--color", "never",
                "-C", repositoryPath
            ]
            if let modelID, !modelID.isEmpty {
                args += ["-m", modelID]
            }
            if let reasoningEffort, !reasoningEffort.isEmpty {
                args += ["-c", "model_reasoning_effort=\"\(reasoningEffort)\""]
            }
            args.append(prompt)
            arguments = args
        case .cursor:
            command = "cursor-agent"
            // 非交互：--force / --approve-mcps 自动放行；分析阶段强制 plan（只读）
            var args = [
                "-p",
                "--force",
                "--approve-mcps",
                "--output-format", "stream-json"
            ]
            if mode.isAnalysis {
                args += ["--mode", "plan"]
            }
            if let modelID, !modelID.isEmpty {
                args += ["--model", cursorModelArgument(modelID: modelID, reasoningEffort: reasoningEffort)]
            }
            args.append(prompt)
            arguments = args
        case .claude:
            command = "claude"
            var args = [
                "-p",
                "--output-format", "stream-json",
                "--verbose",
                "--permission-mode", "bypassPermissions"
            ]
            if let modelID, !modelID.isEmpty {
                args += ["--model", modelID]
            }
            if let reasoningEffort, !reasoningEffort.isEmpty {
                args += ["--effort", reasoningEffort]
            }
            args.append(prompt)
            arguments = args
        }

        let execution = try runner.start(
            phase: mode.phase,
            command: command,
            arguments: arguments,
            workingDirectory: repositoryPath
        )
        await onStarted(execution)
        let result = try await runner.monitor(execution: execution) { line, offset in
            let event = Self.parseEvent(line, provider: provider)
            await onEvent(AIExecutionStreamEvent(displayMessage: event.displayMessage, byteOffset: offset))
        }

        do {
            return try Self.executionResult(from: result, command: command, provider: provider, phase: mode.phase)
        } catch AIExecutionError.incompleteProtocolOutput(.analysis) {
            guard provider == .cursor,
                  let sessionID = Self.extractSessionID(from: result.standardOutput) else {
                throw AIExecutionError.incompleteProtocolOutput(.analysis)
            }
            // Cursor 常在调研中途 exit 0 且不产出 Plan；自动续跑一轮强制收束
            await onEvent(AIExecutionStreamEvent(
                displayMessage: "分析尚未收束，正在续跑同一会话并要求输出完整方案…",
                byteOffset: Int64(result.standardOutput.utf8.count)
            ))
            return try await continueCursorAnalysis(
                sessionID: sessionID,
                modelID: modelID,
                reasoningEffort: reasoningEffort,
                repositoryPath: repositoryPath,
                previous: result,
                onStarted: onStarted,
                onEvent: onEvent
            )
        }
    }

    private func continueCursorAnalysis(
        sessionID: String,
        modelID: String?,
        reasoningEffort: String?,
        repositoryPath: String,
        previous: DurableProcessResult,
        onStarted: @escaping @Sendable (AIExecutionRecord) async -> Void,
        onEvent: @escaping @Sendable (AIExecutionStreamEvent) async -> Void
    ) async throws -> AIExecutionResult {
        var args = [
            "-p",
            "--force",
            "--approve-mcps",
            "--output-format", "stream-json",
            "--mode", "plan",
            "--resume", sessionID,
            PromptBuilder.buildAnalysisContinuation()
        ]
        if let modelID, !modelID.isEmpty {
            args.insert(contentsOf: ["--model", cursorModelArgument(modelID: modelID, reasoningEffort: reasoningEffort)], at: args.count - 1)
        }

        let execution = try runner.start(
            phase: .analysis,
            command: "cursor-agent",
            arguments: args,
            workingDirectory: repositoryPath
        )
        await onStarted(execution)
        let continued = try await runner.monitor(execution: execution) { line, offset in
            let event = Self.parseEvent(line, provider: .cursor)
            await onEvent(AIExecutionStreamEvent(displayMessage: event.displayMessage, byteOffset: offset))
        }

        let combined = DurableProcessResult(
            exitCode: continued.exitCode,
            standardOutput: previous.standardOutput + "\n" + continued.standardOutput,
            standardError: previous.standardError + "\n" + continued.standardError,
            launchError: continued.launchError ?? previous.launchError
        )
        return try Self.executionResult(
            from: combined,
            command: "cursor-agent",
            provider: .cursor,
            phase: .analysis
        )
    }

    private func cursorModelArgument(modelID: String, reasoningEffort: String?) -> String {
        guard let reasoningEffort, !reasoningEffort.isEmpty, !modelID.contains("[") else {
            return modelID
        }
        return "\(modelID)[effort=\(reasoningEffort)]"
    }

    private static func extractSessionID(from stdout: String) -> String? {
        for line in stdout.split(separator: "\n").map(String.init) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionID = json["session_id"] as? String,
                  !sessionID.isEmpty else { continue }
            return sessionID
        }
        return nil
    }

    func resume(
        execution: AIExecutionRecord,
        provider: AIProvider,
        onEvent: @escaping @Sendable (AIExecutionStreamEvent) async -> Void
    ) async throws -> AIExecutionResult {
        let result = try await runner.monitor(execution: execution) { line, offset in
            let event = Self.parseEvent(line, provider: provider)
            await onEvent(AIExecutionStreamEvent(displayMessage: event.displayMessage, byteOffset: offset))
        }
        return try Self.executionResult(
            from: result,
            command: provider.rawValue,
            provider: provider,
            phase: execution.phase
        )
    }

    func inspect(execution: AIExecutionRecord) -> DurableExecutionStatus {
        runner.inspect(execution: execution)
    }

    func cancel(execution: AIExecutionRecord) {
        runner.cancel(execution: execution)
    }

    private static func executionResult(
        from result: DurableProcessResult,
        command: String,
        provider: AIProvider,
        phase: AIExecutionPhase
    ) throws -> AIExecutionResult {
        guard result.exitCode == 0 else {
            let message = result.launchError
                ?? (result.standardError.isEmpty ? result.standardOutput : result.standardError)
            throw ProcessRunnerError.failed(command: command, code: result.exitCode, message: message)
        }

        let rawOutput = result.standardOutput + result.standardError
        let lines = result.standardOutput.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if let pending = pendingInteractionSummary(in: lines) {
            throw AIExecutionError.pendingUserInteraction(pending)
        }

        var candidates: [String] = []
        for line in lines {
            let event = parseEvent(line, provider: provider)
            if let text = event.candidateText, !text.isEmpty {
                candidates.append(text)
            }
            if let final = event.finalMessage, !final.isEmpty {
                candidates.append(final)
            }
        }

        // Cursor --mode plan 的真实方案在 createPlanToolCall，不在 result 文本里
        if phase == .analysis, provider == .cursor,
           let cursorPlan = extractCursorCreatePlan(from: lines) {
            candidates.append(PromptBuilder.wrapCursorPlanAsAnalysisProtocol(cursorPlan))
        }

        let finalMessage = candidates.last(where: { PromptBuilder.hasRequiredProtocolMarkers($0, phase: phase) })
        guard let finalMessage else {
            throw AIExecutionError.incompleteProtocolOutput(phase)
        }

        return AIExecutionResult(finalMessage: finalMessage, rawOutput: rawOutput)
    }

    /// 从 Cursor plan 模式的 createPlan 工具/交互事件中提取方案正文。
    private static func extractCursorCreatePlan(from lines: [String]) -> String? {
        var latest: String?
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let plan = cursorPlanMarkdown(from: json), plan.count >= 80 {
                latest = plan
            }
        }
        return latest
    }

    private static func cursorPlanMarkdown(from json: [String: Any]) -> String? {
        if let toolCall = json["tool_call"] as? [String: Any],
           let createPlan = toolCall["createPlanToolCall"] as? [String: Any],
           let args = createPlan["args"] as? [String: Any],
           let plan = args["plan"] as? String {
            return plan
        }

        if (json["type"] as? String) == "interaction_query",
           (json["query_type"] as? String) == "createPlanRequestQuery",
           let query = json["query"] as? [String: Any],
           let createPlanQuery = query["createPlanRequestQuery"] as? [String: Any],
           let args = createPlanQuery["args"] as? [String: Any],
           let plan = args["plan"] as? String {
            return plan
        }

        return nil
    }

    /// 若进程退出时仍有未应答的 interaction_query，视为失败（非交互流水线不会代用户确认）。
    private static func pendingInteractionSummary(in lines: [String]) -> String? {
        var pending: [Int: String] = [:]
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["type"] as? String) == "interaction_query" else { continue }
            let subtype = json["subtype"] as? String ?? ""
            let queryType = json["query_type"] as? String ?? "interaction"
            let id = interactionID(from: json) ?? 0
            if subtype == "request" {
                pending[id] = queryType
            } else if subtype == "response" {
                pending.removeValue(forKey: id)
            }
        }
        guard !pending.isEmpty else { return nil }
        return pending.values.sorted().joined(separator: ", ")
    }

    private static func interactionID(from json: [String: Any]) -> Int? {
        if let query = json["query"] as? [String: Any], let id = query["id"] as? Int { return id }
        if let response = json["response"] as? [String: Any], let id = response["id"] as? Int { return id }
        return json["id"] as? Int
    }

    private static func parseEvent(
        _ line: String,
        provider: AIProvider
    ) -> (displayMessage: String?, finalMessage: String?, candidateText: String?) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (line, nil, nil)
        }

        let type = json["type"] as? String ?? ""
        if type == "interaction_query", (json["subtype"] as? String) == "request" {
            let queryType = json["query_type"] as? String ?? "确认"
            if queryType == "createPlanRequestQuery" {
                return ("Cursor 已生成分析方案，正在确认…", nil, nil)
            }
            return ("CLI 自动处理确认请求：\(queryType)", nil, nil)
        }

        switch provider {
        case .cursor:
            if type == "assistant",
               let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String {
                return (text, nil, text)
            }
            if type == "tool_call" {
                if let plan = cursorPlanMarkdown(from: json), plan.count >= 80 {
                    return ("Cursor 已产出分析方案（Plan）", nil, nil)
                }
                return (nil, nil, nil)
            }
            if type == "result", let result = json["result"] as? String {
                // 不把「进程退出」打进日志，避免误以为异常；结果文本仅作候选
                return (nil, result, result)
            }
        case .claude:
            if type == "system", let subtype = json["subtype"] as? String, subtype == "init" {
                let model = json["model"] as? String
                return (model.map { "Claude Code 已启动（\($0)）" } ?? "Claude Code 已启动", nil, nil)
            }
            if type == "assistant" {
                let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]]
                    ?? json["content"] as? [[String: Any]]
                if let blocks = content {
                    if let text = blocks.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String, !text.isEmpty {
                        return (text, nil, text)
                    }
                    if blocks.contains(where: { ($0["type"] as? String) == "tool_use" }) {
                        return (nil, nil, nil)
                    }
                }
            }
            if type == "result" {
                let result = json["result"] as? String
                let isError = json["is_error"] as? Bool ?? false
                if isError {
                    return (result ?? "Claude Code 执行失败", result, result)
                }
                return ("Claude Code 已完成", result, result)
            }
        case .codex:
            if type == "item.completed",
               let item = json["item"] as? [String: Any],
               let itemType = item["type"] as? String,
               itemType == "agent_message",
               let text = item["text"] as? String {
                return (text, text, text)
            }
            if type == "item.started" {
                return (nil, nil, nil)
            }
            if type == "turn.completed" { return ("Codex 已完成本轮任务", nil, nil) }
            if let message = json["message"] as? String { return (message, nil, nil) }
        }
        return (nil, nil, nil)
    }
}

enum PromptBuilder {
    static func buildAnalysis(ticket: Ticket, helperContext: String) -> String {
        """
        你正在通过 DevFlow 工作台分析公司工单。当前处于只读分析阶段，绝对不要修改、创建或删除任何文件，也不要执行会写入仓库的命令。

        工单编号：\(ticket.issueNumber)
        标题：\(ticket.title)
        描述：
        \(ticket.displayDescription)

        用户提供的辅助定位信息：
        \(helperContext.isEmpty ? "未提供，请自行在仓库中定位。" : helperContext)

        分析要求：
        1. 只依据标题和描述提取有价值信息（目标、现象、期望、约束、相关模块等）；不要依赖类型、优先级等元数据做判断。
        2. 若描述主要是链接（如需求 Wiki、文档、设计稿），请尽量打开并阅读链接内容；能访问则把其中的需求要点纳入分析，无法访问则明确说明并基于现有信息继续。
        3. 结合仓库规则和相关实现，定位问题根因。
        4. 给出聚焦的修改方案，明确涉及的文件、修改步骤和验证方式。
        5. 说明潜在影响和需要人工关注的风险。
        6. 不要执行 git commit、git pull、git push，也不要修改知识库工单。
        7. 这是非交互流水线：绝对不要向用户提问、不要等待确认、不要停在“下一步建议用户确认”的半成品状态；信息不足时给出合理假设，并在风险中写明待确认点。
        8. 过程进度说明不算完成。调研充分后必须收束：优先调用 createPlan 提交完整方案；或在最终回复中输出下列固定段落。缺少方案将导致任务失败并自动续跑/重试。
        9. 最终回复必须完整包含以下固定段落标题（标题行原样输出），并在标题下填写真实结论，不要复述本说明文字：

        DEVFLOW_ROOT_CAUSE:
        <根因>

        DEVFLOW_PLAN:
        1. <修改步骤、涉及文件、验证方式>

        DEVFLOW_RISKS:
        - <风险；没有则写：未发现明显额外风险>
        """
    }

    /// Cursor 分析中途结束后的续跑提示：禁止继续发散探索，强制产出方案。
    static func buildAnalysisContinuation() -> String {
        """
        上一轮分析已中途结束，但还没有提交完整方案。现在不要再大范围探索，基于已有结论立即收束。

        请立刻完成其一（优先 1）：
        1) 调用 createPlan 提交完整修改方案（含根因、步骤、涉及文件、验证与风险）
        2) 或在最终回复中原样输出：

        DEVFLOW_ROOT_CAUSE:
        <根因>

        DEVFLOW_PLAN:
        1. <修改步骤、涉及文件、验证方式>

        DEVFLOW_RISKS:
        - <风险；没有则写：未发现明显额外风险>

        仅进度更新、继续排查类回复视为失败。
        """
    }

    static func buildAnalysisRevision(
        ticket: Ticket,
        helperContext: String,
        previousPlan: String,
        userNote: String
    ) -> String {
        """
        你正在通过 DevFlow 工作台修订已有分析方案。当前仍是只读分析阶段，绝对不要修改、创建或删除任何文件。

        工单编号：\(ticket.issueNumber)
        标题：\(ticket.title)
        描述：
        \(ticket.displayDescription)

        用户提供的辅助定位信息：
        \(helperContext.isEmpty ? "未提供" : helperContext)

        上一版分析方案：
        \(previousPlan)

        用户补充说明（必须纳入修订）：
        \(userNote)

        修订要求：
        1. 在上一版方案基础上吸收用户补充，给出更新后的完整方案，不要从零重写无关部分。
        2. 不要向用户提问等待回复；信息不足时给出合理假设并写入风险。
        3. 优先调用 createPlan 提交完整方案；或最终回复必须包含：

        DEVFLOW_ROOT_CAUSE:
        <根因>

        DEVFLOW_PLAN:
        1. <修改步骤、涉及文件、验证方式>

        DEVFLOW_RISKS:
        - <风险；没有则写：未发现明显额外风险>
        """
    }

    static func build(ticket: Ticket, helperContext: String, confirmedPlan: String = "") -> String {
        """
        你正在通过 DevFlow 工作台解决公司工单。用户已确认修改方案，请按方案在当前 Git 仓库中修改代码。

        工单编号：\(ticket.issueNumber)
        项目：\(ticket.projectName)
        类型：\(ticket.kind.rawValue)
        优先级：\(ticket.priority.rawValue)
        标题：\(ticket.title)
        描述：
        \(ticket.displayDescription)

        用户提供的辅助定位信息：
        \(helperContext.isEmpty ? "未提供，请自行在仓库中定位。" : helperContext)

        用户已确认的分析与修改方案：
        \(confirmedPlan.isEmpty ? "未提供，请基于工单重新确认最小修改范围。" : confirmedPlan)

        工作要求：
        1. 先检查仓库规则和相关实现，定位根因后再修改。
        2. 保持改动聚焦，不修改无关文件，不做格式化清理。
        3. 在合理范围内运行测试或静态检查。
        4. 不要执行 git commit、git pull、git push，也不要修改知识库工单；这些步骤由 DevFlow 在人工审批后执行。
        5. 不要覆盖用户原有未提交改动。
        6. 这是非交互流水线：绝对不要向用户提问或等待确认；按已确认方案直接改完。
        7. 过程进度说明不算完成。必须落实方案中的代码修改后，用一次最终回复输出完整报告；只改测试/无关文件或缺少下列标记将导致任务失败。
        8. 最终回复必须完整包含以下固定段落标题（标题行原样输出），并在标题下填写真实结论，不要复述本说明文字：

        DEVFLOW_SUMMARY:
        <修改了什么>

        DEVFLOW_REASONING:
        <根因与修改理由>

        DEVFLOW_TESTS:
        - <测试结果；未执行则说明原因>

        DEVFLOW_RISKS:
        - <风险；没有则写：未发现明显额外风险>
        """
    }

    /// 将 Cursor Plan 模式的 markdown 方案包装为 DevFlow 分析协议，便于统一闸门与展示。
    static func wrapCursorPlanAsAnalysisProtocol(_ planMarkdown: String) -> String {
        let plan = planMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        DEVFLOW_ROOT_CAUSE:
        见下方 Cursor 分析方案中的根因说明。

        DEVFLOW_PLAN:
        \(plan)

        DEVFLOW_RISKS:
        - 请结合方案正文中的风险、验证与人工确认项检查
        """
    }

    static func hasRequiredProtocolMarkers(_ text: String, phase: AIExecutionPhase) -> Bool {
        // 排除 prompt / 原始日志回声：这些会误带上标记字样但没有真实方案
        if isProtocolTemplateEcho(text) { return false }

        switch phase {
        case .analysis:
            guard text.contains("DEVFLOW_ROOT_CAUSE:"),
                  text.contains("DEVFLOW_PLAN:"),
                  text.contains("DEVFLOW_RISKS:") else { return false }
            let cause = section("DEVFLOW_ROOT_CAUSE:", until: "DEVFLOW_PLAN:", in: text)
            let plan = section("DEVFLOW_PLAN:", until: "DEVFLOW_RISKS:", in: text)
            let risks = section("DEVFLOW_RISKS:", until: nil, in: text)
            return isMeaningfulProtocolSection(cause)
                && isMeaningfulProtocolSection(plan)
                && isMeaningfulProtocolSection(risks)
        case .modification:
            guard text.contains("DEVFLOW_SUMMARY:"),
                  text.contains("DEVFLOW_REASONING:"),
                  text.contains("DEVFLOW_TESTS:"),
                  text.contains("DEVFLOW_RISKS:") else { return false }
            let summary = section("DEVFLOW_SUMMARY:", until: "DEVFLOW_REASONING:", in: text)
            let reasoning = section("DEVFLOW_REASONING:", until: "DEVFLOW_TESTS:", in: text)
            let tests = section("DEVFLOW_TESTS:", until: "DEVFLOW_RISKS:", in: text)
            let risks = section("DEVFLOW_RISKS:", until: nil, in: text)
            return isMeaningfulProtocolSection(summary)
                && isMeaningfulProtocolSection(reasoning)
                && isMeaningfulProtocolSection(tests)
                && isMeaningfulProtocolSection(risks)
        }
    }

    /// 是否为 prompt 模板或整段 stdout 误提取（非模型真实输出）。
    static func isProtocolTemplateEcho(_ text: String) -> Bool {
        if text.contains("最终回复必须完整包含以下固定段落") { return true }
        if text.contains("\"type\":\"user\"") || text.contains("\"type\": \"user\"") { return true }
        if text.contains("\"type\":\"thinking\"") || text.contains("\"type\": \"thinking\"") { return true }
        if text.contains("<根因>") || text.contains("<修改了什么>") { return true }
        if text.contains("说明问题根因（含从标题/描述/链接中提炼的关键信息）") { return true }
        if text.contains("简要说明修改了什么。") && text.contains("说明根因以及为什么这样修改。") { return true }
        // 误把整份 stream-json 日志当成方案
        if text.count > 20_000, text.contains("session_id") { return true }
        return false
    }

    private static func isMeaningfulProtocolSection(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return false }
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">") { return false }
        if trimmed == "说明问题根因（含从标题/描述/链接中提炼的关键信息）。" { return false }
        if trimmed == "简要说明修改了什么。" { return false }
        if trimmed == "说明根因以及为什么这样修改。" { return false }
        return true
    }

    /// 从候选文本中截取协议段落（仅用于已通过校验的模型输出）。
    static func extractProtocolBlock(from text: String, phase: AIExecutionPhase) -> String? {
        guard hasRequiredProtocolMarkers(text, phase: phase) else { return nil }
        let startMarker: String
        switch phase {
        case .analysis: startMarker = "DEVFLOW_ROOT_CAUSE:"
        case .modification: startMarker = "DEVFLOW_SUMMARY:"
        }
        guard let range = text.range(of: startMarker) else { return nil }
        return String(text[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseReport(finalMessage: String, rawOutput: String, changedFiles: [String], diff: String) -> AIReport {
        let summary = section("DEVFLOW_SUMMARY:", until: "DEVFLOW_REASONING:", in: finalMessage)
        let reasoning = section("DEVFLOW_REASONING:", until: "DEVFLOW_TESTS:", in: finalMessage)
        let testsText = section("DEVFLOW_TESTS:", until: "DEVFLOW_RISKS:", in: finalMessage)
        let risksText = section("DEVFLOW_RISKS:", until: nil, in: finalMessage)
        return AIReport(
            summary: summary.isEmpty ? finalMessage : summary,
            reasoning: reasoning.isEmpty ? "AI 未按结构返回原因说明，请查看代码差异与执行日志。" : reasoning,
            changedFiles: changedFiles,
            tests: listItems(testsText),
            risks: listItems(risksText),
            diff: diff,
            rawOutput: rawOutput
        )
    }

    private static func section(_ start: String, until end: String?, in text: String) -> String {
        guard let startRange = text.range(of: start) else { return "" }
        let contentStart = startRange.upperBound
        let contentEnd = end.flatMap { text.range(of: $0, range: contentStart..<text.endIndex)?.lowerBound } ?? text.endIndex
        return text[contentStart..<contentEnd].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func listItems(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.hasPrefix("-") ? String($0.dropFirst()).trimmingCharacters(in: .whitespaces) : $0 }
            .filter { !$0.isEmpty }
    }
}
