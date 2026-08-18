import Foundation

struct AppSnapshot: Codable {
    var tickets: [Ticket]
    var repositories: [RepositoryConfig]
    var workItems: [WorkItem]
    var planningSessions: [RequirementPlanSession]
    var knowledgeBaseURL: String
    var defaultTestAssignee: String
    var syncIntervalHours: Int
    var hasAuthenticatedSession: Bool
    var lastSyncedAt: Date?
    var aiProviderOrder: [AIProvider]
    var isTestModeEnabled: Bool
    var agentAPIURL: String
    var agentAPIKey: String
    var agentModelID: String
    var agentSystemPrompt: String
    var customAIProviders: [CustomAIProviderConfig]

    init(
        tickets: [Ticket],
        repositories: [RepositoryConfig],
        workItems: [WorkItem],
        planningSessions: [RequirementPlanSession] = [],
        knowledgeBaseURL: String,
        defaultTestAssignee: String,
        syncIntervalHours: Int,
        hasAuthenticatedSession: Bool,
        lastSyncedAt: Date? = nil,
        aiProviderOrder: [AIProvider] = Array(AIProvider.allCases),
        isTestModeEnabled: Bool = false,
        agentAPIURL: String = "",
        agentAPIKey: String = "",
        agentModelID: String = "",
        agentSystemPrompt: String = "你是一个可以调用本地工具的开发助手。需要读取或修改项目时，先说明原因。",
        customAIProviders: [CustomAIProviderConfig] = []
    ) {
        self.tickets = tickets
        self.repositories = repositories
        self.workItems = workItems
        self.planningSessions = planningSessions
        self.knowledgeBaseURL = knowledgeBaseURL
        self.defaultTestAssignee = defaultTestAssignee
        self.syncIntervalHours = syncIntervalHours
        self.hasAuthenticatedSession = hasAuthenticatedSession
        self.lastSyncedAt = lastSyncedAt
        self.aiProviderOrder = AIProvider.normalizedOrder(aiProviderOrder)
        self.isTestModeEnabled = isTestModeEnabled
        self.agentAPIURL = agentAPIURL
        self.agentAPIKey = agentAPIKey
        self.agentModelID = agentModelID
        self.agentSystemPrompt = agentSystemPrompt
        self.customAIProviders = customAIProviders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tickets = try container.decode([Ticket].self, forKey: .tickets)
        repositories = try container.decode([RepositoryConfig].self, forKey: .repositories)
        workItems = (try? container.decode([WorkItem].self, forKey: .workItems)) ?? []
        planningSessions = (try? container.decode([RequirementPlanSession].self, forKey: .planningSessions)) ?? []
        knowledgeBaseURL = try container.decode(String.self, forKey: .knowledgeBaseURL)
        defaultTestAssignee = try container.decode(String.self, forKey: .defaultTestAssignee)
        syncIntervalHours = try container.decodeIfPresent(Int.self, forKey: .syncIntervalHours) ?? 2
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        // 旧版 state.json 无此字段：仅用于判断是否曾登录，不再据此恢复工单列表
        hasAuthenticatedSession = try container.decodeIfPresent(Bool.self, forKey: .hasAuthenticatedSession)
            ?? !tickets.isEmpty
        let storedOrder = (try container.decodeIfPresent([String].self, forKey: .aiProviderOrder) ?? [])
            .compactMap(AIProvider.init(rawValue:))
        aiProviderOrder = AIProvider.normalizedOrder(storedOrder)
        isTestModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isTestModeEnabled) ?? false
        agentAPIURL = try container.decodeIfPresent(String.self, forKey: .agentAPIURL) ?? ""
        agentAPIKey = try container.decodeIfPresent(String.self, forKey: .agentAPIKey) ?? ""
        agentModelID = try container.decodeIfPresent(String.self, forKey: .agentModelID) ?? ""
        agentSystemPrompt = try container.decodeIfPresent(String.self, forKey: .agentSystemPrompt)
            ?? "你是一个可以调用本地工具的开发助手。需要读取或修改项目时，先说明原因。"
        customAIProviders = (try? container.decode([CustomAIProviderConfig].self, forKey: .customAIProviders)) ?? []
    }
}

final class PersistenceStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let fileURL: URL
    private let cookiesURL: URL

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        let directory: URL
        if let directoryURL {
            directory = directoryURL
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            directory = base.appendingPathComponent("DevFlow", isDirectory: true)
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("state.json")
        cookiesURL = directory.appendingPathComponent("kb-cookies.json")
    }

    func save(_ snapshot: AppSnapshot) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("DevFlow persistence save failed: \(error.localizedDescription)")
        }
    }

    func load() -> AppSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AppSnapshot.self, from: data)
    }

    var hasPersistedCookies: Bool {
        guard let data = try? Data(contentsOf: cookiesURL),
              let cookies = try? JSONDecoder().decode([PersistedHTTPCookie].self, from: data) else {
            return false
        }
        return !cookies.isEmpty
    }

    func saveCookies(_ cookies: [HTTPCookie], hostHint: String = "fzyun.net") {
        let relevant = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            return domain.contains(hostHint) || hostHint.contains(domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }
        let payload = relevant.map { PersistedHTTPCookie(cookie: $0) }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            try data.write(to: cookiesURL, options: .atomic)
        } catch {
            NSLog("DevFlow cookie save failed: \(error.localizedDescription)")
        }
    }

    func loadCookies() -> [HTTPCookie] {
        guard let data = try? Data(contentsOf: cookiesURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([PersistedHTTPCookie].self, from: data) else { return [] }
        return stored.compactMap(\.httpCookie)
    }

    func clearCookies() {
        try? fileManager.removeItem(at: cookiesURL)
    }
}

/// 像浏览器配置文件一样，把知识库 Cookie 显式落到磁盘，避免 WK session cookie 随进程退出丢失。
private struct PersistedHTTPCookie: Codable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var isSecure: Bool
    var isHTTPOnly: Bool
    var expiresDate: Date?

    init(cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        isSecure = cookie.isSecure
        isHTTPOnly = cookie.isHTTPOnly
        // session cookie 在浏览器里也会随配置文件保留；这里写成 30 天便于跨启动恢复
        expiresDate = cookie.expiresDate ?? Date().addingTimeInterval(60 * 60 * 24 * 30)
    }

    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .expires: expiresDate ?? Date().addingTimeInterval(60 * 60 * 24 * 30),
            .discard: "FALSE"
        ]
        if isSecure { properties[.secure] = "TRUE" }
        if isHTTPOnly { properties[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)
    }
}
