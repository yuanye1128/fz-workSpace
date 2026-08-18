import AppKit
import Foundation

enum ExternalAgentLauncher {
    struct TaskContext: Sendable {
        var ticket: Ticket
        var repositoryPath: String
        var branch: String
        var helperContext: String
        var navigationMaterialPath: String? = nil
        var provider: AIProvider
        var developmentDocument: String? = nil
        /// Project-level MCP is opt-in. The UI sets this only when the user
        /// explicitly hands the task to Cursor; other clients remain unchanged.
        var enableWorkGraphMCP: Bool = false
    }

    enum LaunchError: LocalizedError {
        case missingRepository
        case unsupportedProvider
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingRepository:
                return "请先选择代码仓库"
            case .unsupportedProvider:
                return "暂不支持打开该客户端"
            case let .launchFailed(message):
                return message
            }
        }
    }

    @discardableResult
    static func launch(_ context: TaskContext) throws -> URL {
        var context = context
        context.repositoryPath = try validatedRepositoryPath(context.repositoryPath)
        let taskFileURL = try writeTaskFile(for: context)
        let prompt = launchPrompt(taskFileURL: taskFileURL, context: context)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)

        switch context.provider {
        case .cursor:
            try openCursor(
                repositoryPath: context.repositoryPath,
                taskFilePath: taskFileURL.path,
                enableWorkGraphMCP: context.enableWorkGraphMCP
            )
        case .codex:
            try openCodexApp(repositoryPath: context.repositoryPath)
        case .claude:
            try openClaude(repositoryPath: context.repositoryPath, prompt: prompt)
        }

        return taskFileURL
    }

    private static func writeTaskFile(for context: TaskContext) throws -> URL {
        // 写到仓库内，外部客户端打开工程后可直接看到
        let directory = URL(fileURLWithPath: context.repositoryPath, isDirectory: true)
            .appendingPathComponent(".devflow", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent("current-task.md")
        let content = taskFileMarkdown(for: context)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    static func taskFileMarkdown(for context: TaskContext) -> String {
        let helper = context.helperContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let navigationMaterial = NavigationMaterialContext.markdownSection(path: context.navigationMaterialPath)
        let source = context.ticket.sourceURL?.absoluteString ?? "无"
        let header = """
        # DevFlow \(context.ticket.kind.rawValue)任务

        - 工单编号：\(context.ticket.issueNumber)
        - 类型：\(context.ticket.kind.rawValue)
        - 标题：\(context.ticket.title)
        - 项目：\(context.ticket.projectName)
        - 仓库：\(context.repositoryPath)
        - 分支：\(context.branch)
        - 原工单：\(source)
        """

        if let document = context.developmentDocument?.trimmingCharacters(in: .whitespacesAndNewlines),
           !document.isEmpty {
            return """
            \(header)

            ## 协作说明

            工作台已完成需求拆解。请按下方开发计划直接实施，不要重新澄清需求；计划已写到可动手的粒度，按步骤改对应文件，非关键细节以「假设」为准，不要扩大「明确不做」中的范围。
            \(navigationMaterial)

            \(document)
            """
        }

        return """
        \(header)

        ## 描述

        \(context.ticket.displayDescription)

        ## 辅助定位

        \(helper.isEmpty ? "未提供" : helper)
        \(navigationMaterial)

        ## 协作说明

        这是一个适合多轮沟通的工单（\(context.ticket.kind.rawValue)），请在当前仓库中与用户协作后实现。
        若描述中包含 Wiki / 文档链接，请先尝试打开并提炼要点。
        保持改动聚焦，完成一阶段后先与用户确认再继续。
        """
    }

    private static func launchPrompt(taskFileURL: URL, context: TaskContext) -> String {
        let relativePath = ".devflow/current-task.md"
        if let document = context.developmentDocument, !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return """
            请先阅读任务说明文件：\(relativePath)（绝对路径：\(taskFileURL.path)）
            当前仓库：\(context.repositoryPath)
            当前分支：\(context.branch)
            工单：\(context.ticket.issueNumber) \(context.ticket.title)
            工作台已完成需求拆解并写好开发计划。请按该文档的分步实现实施，不要重新澄清需求，也不要扩大「明确不做」的范围。
            """
            .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return """
        请先阅读任务说明文件：\(relativePath)（绝对路径：\(taskFileURL.path)）
        当前仓库：\(context.repositoryPath)
        当前分支：\(context.branch)
        工单：\(context.ticket.issueNumber) \(context.ticket.title)
        这是 \(context.ticket.kind.rawValue) 类任务，请与我多轮沟通后实现；描述里若有 Wiki/文档链接请先查阅。
        """
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func openCodexApp(repositoryPath: String) throws {
        let codex = resolveExecutable(
            named: "codex",
            candidates: [
                NSHomeDirectory() + "/.local/bin/codex",
                "/usr/local/bin/codex",
                "/opt/homebrew/bin/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex"
            ]
        )
        guard let codex else {
            throw LaunchError.launchFailed("未找到 codex 命令，请确认已安装 Codex 客户端")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = ["app", repositoryPath]
        do {
            try process.run()
        } catch {
            throw LaunchError.launchFailed("打开 Codex 客户端失败：\(error.localizedDescription)")
        }
    }

    private static func openCursor(
        repositoryPath: String,
        taskFilePath: String,
        enableWorkGraphMCP: Bool
    ) throws {
        let mcpTransaction: WorkGraphProjectMCPConfiguration.Transaction?
        if enableWorkGraphMCP {
            guard let executablePath = Bundle.main.executableURL?.path else {
                throw LaunchError.launchFailed("无法定位 DevFlow WorkGraph MCP 可执行文件")
            }
            do {
                mcpTransaction = try WorkGraphProjectMCPConfiguration.install(
                    repositoryPath: repositoryPath,
                    executablePath: executablePath
                )
            } catch {
                throw LaunchError.launchFailed(error.localizedDescription)
            }
        } else {
            mcpTransaction = nil
        }

        let candidates = [
            "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
            NSHomeDirectory() + "/.local/bin/cursor",
            "/usr/local/bin/cursor"
        ]

        if let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--new-window", repositoryPath, taskFilePath]
            do {
                try process.run()
                return
            } catch {
                try? mcpTransaction?.rollback()
                throw LaunchError.launchFailed("打开 Cursor 失败：\(error.localizedDescription)")
            }
        }

        guard FileManager.default.fileExists(atPath: "/Applications/Cursor.app") else {
            try? mcpTransaction?.rollback()
            throw LaunchError.launchFailed("未找到 Cursor 应用，请先安装 Cursor")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-na", "Cursor", "--args", repositoryPath, taskFilePath]
        do {
            try process.run()
        } catch {
            try? mcpTransaction?.rollback()
            throw LaunchError.launchFailed("打开 Cursor 失败：\(error.localizedDescription)")
        }
    }

    private static func validatedRepositoryPath(_ rawPath: String) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { throw LaunchError.missingRepository }
        let url = URL(fileURLWithPath: trimmed, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LaunchError.missingRepository
        }
        return url.path
    }

    private static func openClaude(repositoryPath: String, prompt: String) throws {
        // Claude 桌面端暂无稳定的「打开仓库+提示」CLI，回退到终端交互会话
        if FileManager.default.fileExists(atPath: "/Applications/Claude.app") {
            let openApp = Process()
            openApp.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openApp.arguments = ["-a", "Claude"]
            try? openApp.run()
        }
        try openInTerminal(
            directory: repositoryPath,
            command: "claude \(shellEscape(prompt))"
        )
    }

    private static func openInTerminal(directory: String, command: String) throws {
        let script = """
        tell application "Terminal"
          activate
          do script "cd \(appleScriptEscape(directory)) && \(command)"
        end tell
        """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            throw LaunchError.launchFailed("无法创建 Terminal 脚本")
        }
        appleScript.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "打开 Terminal 失败"
            throw LaunchError.launchFailed(message)
        }
    }

    private static func resolveExecutable(named name: String, candidates: [String]) -> String? {
        if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return match
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
