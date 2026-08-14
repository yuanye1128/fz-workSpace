import Foundation
import Security

enum AgentCredentialStore {
    private static let service = "net.fzyun.fzworkspace.agent"
    private static let account = "api-key"

    static func saveAPIKey(_ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var item = query
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    static func loadAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func saveAPIKey(_ value: String, for providerID: UUID) {
        save(value, account: providerID.uuidString)
    }

    static func loadAPIKey(for providerID: UUID) -> String {
        load(account: providerID.uuidString)
    }

    private static func save(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var item = query
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func load(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

enum CustomAIProviderService {
    static func fetchModels(apiURL: String, apiKey: String) async throws -> [String] {
        guard let endpoint = modelsEndpoint(from: apiURL) else {
            throw AgentServiceError.invalidConfiguration
        }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentServiceError.invalidResponse("没有收到 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentServiceError.server("获取模型失败：HTTP \(http.statusCode)")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentServiceError.invalidResponse("模型列表不是 JSON")
        }
        let rawModels = (root["data"] as? [[String: Any]]) ?? (root["models"] as? [[String: Any]]) ?? []
        return rawModels.compactMap { item in
            (item["id"] as? String ?? item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private static func modelsEndpoint(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: trimmed), components.scheme != nil, components.host != nil else { return nil }
        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("models") {
            return components.url
        }
        if path.hasSuffix("chat/completions") {
            path = String(path.dropLast("chat/completions".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if path.isEmpty { path = "v1" }
        if !path.hasSuffix("v1") && !path.hasSuffix("api") { path += "/v1" }
        components.path = "/\(path)/models"
        return components.url
    }
}

struct AgentToolRequest: Sendable {
    let name: String
    let arguments: [String: String]
}

enum AgentServiceError: LocalizedError {
    case invalidConfiguration
    case invalidResponse(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "请先在设置中填写 Agent API URL、API Key 和模型。"
        case let .invalidResponse(message):
            "Agent 返回格式无法解析：\(message)"
        case let .server(message):
            message
        }
    }
}

/// OpenAI Chat Completions 兼容的流式 Agent。工具调用在本机执行，结果再回传给模型继续生成。
final class AgentService: @unchecked Sendable {
    private let session: URLSession
    private let maxToolRounds = 8

    init(session: URLSession = .shared) {
        self.session = session
    }

    func run(
        messages: [AgentChatMessage],
        apiURL: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        confirmTool: @escaping @Sendable (AgentToolRequest) async -> Bool,
        onDelta: @escaping @Sendable (String) async -> Void,
        onTool: @escaping @Sendable (String) async -> Void
    ) async throws {
        guard let endpoint = Self.endpoint(from: apiURL),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentServiceError.invalidConfiguration
        }

        var requestMessages: [[String: Any]] = []
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            requestMessages.append(["role": "system", "content": systemPrompt])
        }
        requestMessages.append(contentsOf: messages.map { ["role": $0.role, "content": $0.content] })

        for _ in 0..<maxToolRounds {
            let response = try await stream(
                endpoint: endpoint,
                apiKey: apiKey,
                model: model,
                messages: requestMessages,
                onDelta: onDelta
            )
            guard !response.toolCalls.isEmpty else { return }

            let assistantToolCalls: [[String: Any]] = response.toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": ["name": call.name, "arguments": call.arguments]
                ]
            }
            requestMessages.append([
                "role": "assistant",
                "content": response.content,
                "tool_calls": assistantToolCalls
            ])

            for call in response.toolCalls {
                let parsedArguments = (try? Self.object(from: call.arguments)) ?? [:]
                let toolRequest = AgentToolRequest(name: call.name, arguments: parsedArguments)
                await onTool("正在请求本地工具：\(call.name)")
                let result: String
                if await confirmTool(toolRequest) {
                    result = LocalAgentToolExecutor.execute(toolRequest)
                } else {
                    result = "用户拒绝执行此工具。"
                }
                requestMessages.append([
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": result
                ])
                await onTool("工具执行完成：\(call.name)")
            }
        }
        throw AgentServiceError.server("工具调用轮次超过限制，已停止本次请求。")
    }

    private struct ToolCall {
        var id: String
        var name: String
        var arguments: String
    }

    private struct StreamResult {
        var content: String
        var toolCalls: [ToolCall]
    }

    private func stream(
        endpoint: URL,
        apiKey: String,
        model: String,
        messages: [[String: Any]],
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> StreamResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "tools": Self.toolDefinitions,
            "tool_choice": "auto"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentServiceError.invalidResponse("没有收到 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentServiceError.server("HTTP \(http.statusCode)，请检查 API URL、Key 和模型配置。")
        }

        var content = ""
        var calls: [Int: ToolCall] = [:]
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                throw AgentServiceError.server(message)
            }
            guard let choice = (json["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { continue }
            if let text = delta["content"] as? String, !text.isEmpty {
                content += text
                await onDelta(text)
            }
            if let chunks = delta["tool_calls"] as? [[String: Any]] {
                for chunk in chunks {
                    let index = chunk["index"] as? Int ?? 0
                    var call = calls[index] ?? ToolCall(id: "", name: "", arguments: "")
                    if let id = chunk["id"] as? String { call.id += id }
                    if let function = chunk["function"] as? [String: Any] {
                        if let name = function["name"] as? String { call.name += name }
                        if let arguments = function["arguments"] as? String { call.arguments += arguments }
                    }
                    calls[index] = call
                }
            }
        }
        return StreamResult(content: content, toolCalls: calls.keys.sorted().compactMap { calls[$0] })
    }

    private static func endpoint(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: trimmed), components.scheme != nil, components.host != nil else { return nil }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("chat/completions") {
            return components.url
        }
        components.path = path.isEmpty ? "/v1/chat/completions" : "/\(path)/chat/completions"
        return components.url
    }

    private static func object(from string: String) throws -> [String: String] {
        guard let data = string.data(using: .utf8),
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentServiceError.invalidResponse("工具参数不是 JSON")
        }
        return raw.reduce(into: [String: String]()) { result, pair in
            if let value = pair.value as? String { result[pair.key] = value }
            else if let value = pair.value as? NSNumber { result[pair.key] = value.stringValue }
        }
    }

    private static let toolDefinitions: [[String: Any]] = [
        ["type": "function", "function": [
            "name": "read_file",
            "description": "读取本机指定路径的文本文件。",
            "parameters": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]]
        ]],
        ["type": "function", "function": [
            "name": "list_directory",
            "description": "列出本机指定目录下的文件和目录。",
            "parameters": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]]
        ]],
        ["type": "function", "function": [
            "name": "run_command",
            "description": "在本机工作目录执行一条 shell 命令。只有用户明确批准时才能执行。",
            "parameters": ["type": "object", "properties": ["command": ["type": "string"], "workingDirectory": ["type": "string"]], "required": ["command"]]
        ]]
    ]
}

enum LocalAgentToolExecutor {
    static func execute(_ request: AgentToolRequest) -> String {
        switch request.name {
        case "read_file":
            guard let path = request.arguments["path"] else { return "缺少 path 参数。" }
            guard let data = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath) else { return "无法读取文件：\(path)" }
            return String(decoding: data.prefix(200_000), as: UTF8.self)
        case "list_directory":
            guard let path = request.arguments["path"] else { return "缺少 path 参数。" }
            let expanded = (path as NSString).expandingTildeInPath
            do { return try FileManager.default.contentsOfDirectory(atPath: expanded).joined(separator: "\n") }
            catch { return "无法列出目录：\(error.localizedDescription)" }
        case "run_command":
            guard let command = request.arguments["command"], !command.isEmpty else { return "缺少 command 参数。" }
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            if let directory = request.arguments["workingDirectory"], !directory.isEmpty {
                process.currentDirectoryURL = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
            }
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() }
            catch { return "命令启动失败：\(error.localizedDescription)" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data.prefix(200_000), as: UTF8.self)
            return "退出码：\(process.terminationStatus)\n\(output)"
        default:
            return "未知工具：\(request.name)"
        }
    }
}
