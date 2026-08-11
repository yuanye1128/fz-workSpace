import Foundation

struct AIExecutionResult: Sendable {
    var finalMessage: String
    var rawOutput: String
}

final class AIService: @unchecked Sendable {
    private let runner: ProcessRunner

    init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    func run(
        itemID: UUID,
        provider: AIProvider,
        ticket: Ticket,
        repositoryPath: String,
        helperContext: String,
        onEvent: @escaping @Sendable (String) -> Void
    ) async throws -> AIExecutionResult {
        let prompt = PromptBuilder.build(ticket: ticket, helperContext: helperContext)
        let command: String
        let arguments: [String]

        switch provider {
        case .codex:
            command = "codex"
            arguments = [
                "exec",
                "--json",
                "--sandbox", "workspace-write",
                "--color", "never",
                "-C", repositoryPath,
                prompt
            ]
        case .cursor:
            command = "cursor-agent"
            arguments = [
                "-p",
                "--force",
                "--output-format", "stream-json",
                prompt
            ]
        case .claude:
            command = "claude"
            arguments = [
                "-p",
                "--output-format", "stream-json",
                "--verbose",
                "--permission-mode", "bypassPermissions",
                prompt
            ]
        }

        var finalMessage = ""
        let result = try await runner.run(
            id: itemID,
            command: command,
            arguments: arguments,
            workingDirectory: repositoryPath
        ) { line in
            let event = Self.parseEvent(line, provider: provider)
            if let message = event.displayMessage, !message.isEmpty {
                onEvent(message)
            }
        }

        guard result.exitCode == 0 else {
            throw ProcessRunnerError.failed(command: command, code: result.exitCode, message: result.standardError.isEmpty ? result.standardOutput : result.standardError)
        }

        for line in result.standardOutput.split(separator: "\n").map(String.init) {
            let event = Self.parseEvent(line, provider: provider)
            if let final = event.finalMessage, !final.isEmpty {
                finalMessage = final
            }
        }
        if finalMessage.isEmpty { finalMessage = result.standardOutput }
        return AIExecutionResult(finalMessage: finalMessage, rawOutput: result.standardOutput + result.standardError)
    }

    func cancel(itemID: UUID) {
        runner.cancel(id: itemID)
    }

    private static func parseEvent(_ line: String, provider: AIProvider) -> (displayMessage: String?, finalMessage: String?) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (line, nil)
        }

        let type = json["type"] as? String ?? ""
        switch provider {
        case .cursor:
            if type == "assistant",
               let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String {
                return (text, nil)
            }
            if type == "tool_call", let subtype = json["subtype"] as? String {
                return (subtype == "started" ? "Cursor 正在调用工具" : "Cursor 工具执行完成", nil)
            }
            if type == "result", let result = json["result"] as? String {
                return ("Cursor 已完成", result)
            }
        case .claude:
            if type == "system", let subtype = json["subtype"] as? String, subtype == "init" {
                let model = json["model"] as? String
                return (model.map { "Claude Code 已启动（\($0)）" } ?? "Claude Code 已启动", nil)
            }
            if type == "assistant" {
                let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]]
                    ?? json["content"] as? [[String: Any]]
                if let blocks = content {
                    if let text = blocks.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String, !text.isEmpty {
                        return (text, nil)
                    }
                    if let tool = blocks.first(where: { ($0["type"] as? String) == "tool_use" }),
                       let name = tool["name"] as? String {
                        return ("Claude Code 正在调用工具：\(name)", nil)
                    }
                }
            }
            if type == "result" {
                let result = json["result"] as? String
                let isError = json["is_error"] as? Bool ?? false
                if isError {
                    return (result ?? "Claude Code 执行失败", result)
                }
                return ("Claude Code 已完成", result)
            }
        case .codex:
            if type == "item.completed",
               let item = json["item"] as? [String: Any],
               let itemType = item["type"] as? String,
               itemType == "agent_message",
               let text = item["text"] as? String {
                return (text, text)
            }
            if type == "item.started", let item = json["item"] as? [String: Any], let itemType = item["type"] as? String {
                return ("Codex 正在执行：\(itemType)", nil)
            }
            if type == "turn.completed" { return ("Codex 已完成本轮任务", nil) }
            if let message = json["message"] as? String { return (message, nil) }
        }
        return (nil, nil)
    }
}

enum PromptBuilder {
    static func build(ticket: Ticket, helperContext: String) -> String {
        """
        你正在通过 DevFlow 工作台解决公司工单。请直接在当前 Git 仓库中定位并修复问题。

        工单编号：\(ticket.issueNumber)
        项目：\(ticket.projectName)
        类型：\(ticket.kind.rawValue)
        优先级：\(ticket.priority.rawValue)
        标题：\(ticket.title)
        描述：
        \(ticket.displayDescription)

        用户提供的辅助定位信息：
        \(helperContext.isEmpty ? "未提供，请自行在仓库中定位。" : helperContext)

        工作要求：
        1. 先检查仓库规则和相关实现，定位根因后再修改。
        2. 保持改动聚焦，不修改无关文件，不做格式化清理。
        3. 在合理范围内运行测试或静态检查。
        4. 不要执行 git commit、git pull、git push，也不要修改知识库工单；这些步骤由 DevFlow 在人工审批后执行。
        5. 不要覆盖用户原有未提交改动。
        6. 最终回复必须使用以下固定段落，方便工作台生成报告：

        DEVFLOW_SUMMARY:
        简要说明修改了什么。

        DEVFLOW_REASONING:
        说明根因以及为什么这样修改。

        DEVFLOW_TESTS:
        - 列出实际执行的测试及结果；未执行时说明原因。

        DEVFLOW_RISKS:
        - 列出可能影响的其他区域和建议人工检查项；没有时写“未发现明显额外风险”。
        """
    }

    static func parseReport(finalMessage: String, rawOutput: String, changedFiles: [String], diff: String) -> AIReport {
        let summary = section("DEVFLOW_SUMMARY:", until: "DEVFLOW_REASONING:", in: finalMessage)
        let reasoning = section("DEVFLOW_REASONING:", until: "DEVFLOW_TESTS:", in: finalMessage)
        let testsText = section("DEVFLOW_TESTS:", until: "DEVFLOW_RISKS:", in: finalMessage)
        let risksText = section("DEVFLOW_RISKS:", until: nil, in: finalMessage)
        return AIReport(
            summary: summary.isEmpty ? finalMessage : summary,
            reasoning: reasoning.isEmpty ? "AI 未按结构返回原因说明，请查看原始输出。" : reasoning,
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
