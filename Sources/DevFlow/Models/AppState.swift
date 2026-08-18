import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var tickets: [Ticket] = []
    @Published var projects: [Project] = []
    @Published var repositories: [RepositoryConfig] = []
    @Published var workItems: [WorkItem] = []
    @Published var planningSessions: [RequirementPlanSession] = []
    @Published var destination: SidebarDestination = .all
    @Published var selectedProjectID: String?
    @Published var searchText = ""
    @Published var filters = TicketFilters()
    @Published var sortOption: TicketSortOption = .priority
    @Published var boardLayout: BoardLayout = .cards
    @Published var selectedTicket: Ticket?
    @Published var showingTicketModal = false
    @Published var ticketModalCloseRequestID = 0
    @Published var focusSolveConfiguration = false
    @Published var showingKnowledgeBaseSession = false
    @Published var syncStatus: SyncStatus = .idle
    @Published private(set) var isSynchronizing = false
    @Published var autoSyncIntervalHours: Int = 2
    @Published var hasAuthenticatedSession = false
    @Published var hasUnreadNewTickets = false
    @Published var showingNewTicketsPopover = false
    @Published var newTicketNotifications: [Ticket] = []
    @Published var themePreference: ThemePreference = .system {
        didSet {
            guard oldValue != themePreference else { return }
            UserDefaults.standard.set(themePreference.rawValue, forKey: "themePreference")
            applyAppearance()
        }
    }
    /// 每次主题应用后递增，强制 SwiftUI 重建根视图以清除旧的 preferredColorScheme 缓存
    @Published private(set) var themeRevision = 0
    @Published var knowledgeBaseURL = KnowledgeBaseQuery.allAssignedIssuesURL
    @Published var defaultTestAssignee = ""
    @Published var selectedTicketForReport: Ticket?
    @Published var aiProviderOrder: [AIProvider] = Array(AIProvider.allCases)
    @Published var isTestModeEnabled = false
    @Published var agentAPIURL = ""
    @Published var agentAPIKey = ""
    @Published var agentModelID = ""
    @Published var agentSystemPrompt = "你是一个可以调用本地工具的开发助手。需要读取或修改项目时，先说明原因。"
    @Published var customAIProviders: [CustomAIProviderConfig] = []
    @Published var agentInitialPrompt: String?
    @Published var agentSelectedProviderID: UUID?

    static let localTestTicketIDBase = 9_000_000

    let persistence: PersistenceStore
    lazy var knowledgeBaseSession = KnowledgeBaseSessionController()
    lazy var jobCoordinator = JobCoordinator(appState: self)
    lazy var requirementPlanner = RequirementPlanner(appState: self)
    private var syncInProgress = false
    private var hasPerformedLaunchSync = false
    private var automaticSyncLoopStarted = false
    private var systemThemeObserver: NSObjectProtocol?

    init(persistence: PersistenceStore = PersistenceStore()) {
        self.persistence = persistence
        if let storedTheme = UserDefaults.standard.string(forKey: "themePreference"),
           let preference = ThemePreference(rawValue: storedTheme) {
            // 直接赋值会触发 didSet；先静默写入再统一 apply
            themePreference = preference
        }
        loadPersistedState()
        applyAppearance()
        observeSystemThemeChanges()
    }

    deinit {
        if let systemThemeObserver {
            DistributedNotificationCenter.default().removeObserver(systemThemeObserver)
        }
    }

    /// SwiftUI 使用的颜色方案：跟随系统时解析为当前系统深/浅，避免 preferredColorScheme(nil) 失效。
    var preferredSwiftUIColorScheme: ColorScheme {
        switch themePreference {
        case .light: .light
        case .dark: .dark
        case .system: Self.systemIsDark ? .dark : .light
        }
    }

    private static var systemIsDark: Bool {
        if UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" {
            return true
        }
        // 应用外观被强制覆盖时，effectiveAppearance 不可靠；再读一次系统外观名
        guard let application = NSApp else { return false }
        let appearance = application.effectiveAppearance
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua
    }

    func applyAppearance() {
        guard let application = NSApp else {
            themeRevision &+= 1
            return
        }
        switch themePreference {
        case .system:
            application.appearance = nil
            for window in application.windows {
                window.appearance = nil
            }
        case .light:
            let appearance = NSAppearance(named: .aqua)
            application.appearance = appearance
            for window in application.windows {
                window.appearance = appearance
            }
        case .dark:
            let appearance = NSAppearance(named: .darkAqua)
            application.appearance = appearance
            for window in application.windows {
                window.appearance = appearance
            }
        }
        themeRevision &+= 1
    }

    private func observeSystemThemeChanges() {
        systemThemeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.themePreference == .system else { return }
                // 系统深浅切换后，清掉窗口覆盖并刷新 SwiftUI
                NSApp.appearance = nil
                for window in NSApp.windows {
                    window.appearance = nil
                }
                self.themeRevision &+= 1
            }
        }
    }

    /// 没有任何缓存工单且尚未建立会话时，首页才展示登录引导。
    /// 测试模式开启时允许在无登录状态下使用本地假工单。
    var needsLogin: Bool { tickets.isEmpty && !hasAuthenticatedSession && !isTestModeEnabled }

    var clampedAutoSyncIntervalHours: Int {
        min(8, max(1, autoSyncIntervalHours))
    }

    var orderedAIProviders: [AIProvider] {
        AIProvider.normalizedOrder(aiProviderOrder)
    }

    func moveAIProvider(_ provider: AIProvider, to target: AIProvider) {
        var order = orderedAIProviders
        guard let from = order.firstIndex(of: provider),
              let to = order.firstIndex(of: target),
              from != to else { return }
        order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        aiProviderOrder = order
    }

    var filteredTickets: [Ticket] {
        let source = destination == .completed ? completedHistoryTickets : tickets
        return source
            .filter { ticket in
                if let selectedProjectID, ticket.projectID != selectedProjectID { return false }
                switch destination {
                case .all: break
                case .processing:
                    guard isInProcessingList(ticket) else { return false }
                case .approval:
                    guard activeWorkItem(for: ticket.id)?.stage.requiresUserApproval == true else { return false }
                case .completed:
                    break
                case .repositories, .agent, .settings:
                    return false
                }
                if !searchText.isEmpty {
                    let query = searchText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    let haystack = "\(ticket.id) \(ticket.title) \(ticket.description)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    guard haystack.contains(query) else { return false }
                }
                if let kind = filters.kind, ticket.kind != kind { return false }
                if let priority = filters.priority, ticket.priority != priority { return false }
                // 交付成功后本地状态是「待测试」，已完成面板按任务记录收口，不再套用状态筛选。
                if destination != .completed, let status = filters.status, ticket.status != status { return false }
                if let version = filters.version, ticket.targetVersion != version { return false }
                return true
            }
            .sorted(by: sortComparator)
    }

    private var sortComparator: (Ticket, Ticket) -> Bool {
        switch sortOption {
        case .priority:
            return { lhs, rhs in
                if lhs.priority.sortRank != rhs.priority.sortRank {
                    return lhs.priority.sortRank < rhs.priority.sortRank
                }
                return lhs.updatedAt > rhs.updatedAt
            }
        case .updated:
            return { $0.updatedAt > $1.updatedAt }
        case .version:
            return { lhs, rhs in
                if lhs.targetVersion != rhs.targetVersion {
                    return lhs.targetVersion > rhs.targetVersion
                }
                return lhs.priority.sortRank < rhs.priority.sortRank
            }
        }
    }

    /// 处理中：有进行中的任务且尚未到“等待用户确认”；或本地状态为处理中且无确认中任务。
    func isInProcessingList(_ ticket: Ticket) -> Bool {
        if let item = activeWorkItem(for: ticket.id) {
            return !item.stage.requiresUserApproval
        }
        return ticket.status == .processing
    }

    func isInCompletedList(_ ticket: Ticket) -> Bool {
        ticket.status == .completed
            || ticket.status == .testing
            || hasCompletedWorkItem(for: ticket.id)
    }

    func hasCompletedWorkItem(for ticketID: Int) -> Bool {
        workItems.contains { $0.ticketID == ticketID && $0.stage == .completed }
    }

    /// 已完成面板：当前列表里的已完成工单，加上任务还在、工单已被同步掉的本地记录。
    var completedHistoryTickets: [Ticket] {
        var result: [Ticket] = []
        var seen = Set<Int>()
        for ticket in tickets where isInCompletedList(ticket) {
            result.append(ticket)
            seen.insert(ticket.id)
        }
        for item in workItems where item.stage == .completed {
            guard !seen.contains(item.ticketID) else { continue }
            result.append(Self.placeholderTicket(forCompletedWork: item))
            seen.insert(item.ticketID)
        }
        return result
    }

    var availableVersions: [String] {
        Array(Set(tickets.map(\.targetVersion))).sorted().reversed()
    }

    var selectedTitle: String {
        if let projectID = selectedProjectID, let project = projects.first(where: { $0.id == projectID }) {
            return project.name
        }
        return destination.rawValue
    }

    func ticketCount(for projectID: String) -> Int {
        tickets.filter { $0.projectID == projectID }.count
    }

    func destinationCount(_ destination: SidebarDestination) -> Int? {
        switch destination {
        case .all:
            tickets.count
        case .processing:
            tickets.filter { isInProcessingList($0) }.count
        case .approval:
            workItems.filter { $0.stage.requiresUserApproval }.count
        case .completed:
            completedHistoryTickets.count
        default:
            nil
        }
    }

    func select(destination: SidebarDestination) {
        selectedProjectID = nil
        self.destination = destination
    }

    func select(project: Project) {
        destination = .all
        selectedProjectID = project.id
    }

    func open(ticket: Ticket, focusSolve: Bool = false) {
        selectedTicket = ticket
        focusSolveConfiguration = focusSolve
        showingTicketModal = true
    }

    func closeTicketModal() {
        showingTicketModal = false
        focusSolveConfiguration = false
    }

    func requestTicketModalClose() {
        guard showingTicketModal else { return }
        ticketModalCloseRequestID += 1
    }

    func activeWorkItem(for ticketID: Int) -> WorkItem? {
        workItems.last { item in
            item.ticketID == ticketID && ![.completed, .cancelled, .failed].contains(item.stage)
        }
    }

    func setTicketStatus(_ ticketID: Int, _ status: TicketStatus) {
        guard let index = tickets.firstIndex(where: { $0.id == ticketID }) else { return }
        tickets[index].status = status
        persistState()
    }

    /// 从「我的处理中」移除：取消进行中任务，并把本地状态从处理中恢复为新建。
    func removeFromProcessing(ticketID: Int) {
        if let item = activeWorkItem(for: ticketID) {
            jobCoordinator.cancel(itemID: item.id)
        }
        if planningSession(for: ticketID) != nil {
            requirementPlanner.cancel(ticketID: ticketID)
        }
        if let index = tickets.firstIndex(where: { $0.id == ticketID }), tickets[index].status == .processing {
            tickets[index].status = .new
        }
        persistState()
    }

    func repositories(for ticket: Ticket) -> [RepositoryConfig] {
        repositories.filter { $0.projectID == ticket.projectID }
    }

    func upsert(repository: RepositoryConfig) {
        if let index = repositories.firstIndex(where: { $0.id == repository.id }) {
            repositories[index] = repository
        } else {
            repositories.append(repository)
        }
        persistState()
    }

    func removeRepository(id: UUID) {
        repositories.removeAll { $0.id == id }
        persistState()
    }

    func beginSyncIfPossible() -> Bool {
        guard !syncInProgress else { return false }
        syncInProgress = true
        isSynchronizing = true
        return true
    }

    func finishSync() {
        syncInProgress = false
        isSynchronizing = false
    }

    func updateTickets(_ newTickets: [Ticket], newlyDiscoveredTickets: [Ticket] = []) {
        let selectedTicketID = selectedTicket?.id
        let mergedTickets = mergedTicketsPreservingActiveWork(newTickets)
        tickets = mergedTickets
        projects = Self.rebuildProjects(from: mergedTickets)
        recoverCompletedWorkHistoryIfNeeded()
        if let selectedTicketID {
            selectedTicket = mergedTickets.first(where: { $0.id == selectedTicketID })
        }
        hasAuthenticatedSession = true
        syncStatus = .synced(Date())
        if !newlyDiscoveredTickets.isEmpty {
            newTicketNotifications = newlyDiscoveredTickets
            hasUnreadNewTickets = true
        }
        persistState()
    }

    func mergedTicketsPreservingActiveWork(_ syncedTickets: [Ticket]) -> [Ticket] {
        let syncedTicketIDs = Set(syncedTickets.map(\.id))
        let retainedTickets = tickets.filter { ticket in
            guard !syncedTicketIDs.contains(ticket.id) else { return false }
            if ticket.isLocalTest { return true }
            if activeWorkItem(for: ticket.id) != nil { return true }
            if planningSession(for: ticket.id) != nil { return true }
            return hasCompletedWorkItem(for: ticket.id)
        }
        return syncedTickets + retainedTickets
    }

    @discardableResult
    func createLocalTestTicket(
        title: String,
        description: String,
        priority: TicketPriority = .normal,
        kind: TicketKind = .bug
    ) -> Ticket? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        let project = resolveProjectForLocalTestTicket()
        if projects.first(where: { $0.id == project.id }) == nil {
            projects.append(project)
            projects.sort { $0.name < $1.name }
        }

        let nextID = nextLocalTestTicketID()
        let ticket = Ticket(
            id: nextID,
            projectID: project.id,
            projectName: project.name,
            kind: kind,
            priority: priority,
            status: .new,
            title: trimmedTitle,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            targetVersion: "test",
            updatedAt: Date(),
            assignee: "本地测试",
            sourceURL: nil,
            author: "本地测试",
            isLocalTest: true
        )
        tickets.insert(ticket, at: 0)
        persistState()
        return ticket
    }

    func deleteLocalTestTicket(id: Int) {
        guard let index = tickets.firstIndex(where: { $0.id == id && $0.isLocalTest }) else { return }
        guard activeWorkItem(for: id) == nil else { return }
        tickets.remove(at: index)
        if selectedTicket?.id == id {
            closeTicketModal()
            selectedTicket = nil
        }
        projects = Self.rebuildProjects(from: tickets)
        // 若仓库仍引用某项目，保留项目列表中对应项
        for repository in repositories where projects.first(where: { $0.id == repository.projectID }) == nil {
            projects.append(
                Project(
                    id: repository.projectID,
                    name: repository.displayName,
                    symbol: Self.projectSymbol(for: repository.displayName)
                )
            )
        }
        projects.sort { $0.name < $1.name }
        persistState()
    }

    private func nextLocalTestTicketID() -> Int {
        let maxLocal = tickets.filter(\.isLocalTest).map(\.id).max() ?? (Self.localTestTicketIDBase - 1)
        return max(Self.localTestTicketIDBase, maxLocal + 1)
    }

    private func resolveProjectForLocalTestTicket() -> Project {
        if let selectedProjectID,
           let selected = projects.first(where: { $0.id == selectedProjectID }) {
            return selected
        }
        if let repository = repositories.first(where: \.isDefault) ?? repositories.first {
            if let existing = projects.first(where: { $0.id == repository.projectID }) {
                return existing
            }
            return Project(
                id: repository.projectID,
                name: repository.displayName,
                symbol: Self.projectSymbol(for: repository.displayName)
            )
        }
        if let first = projects.first {
            return first
        }
        return Project(id: "local-test", name: "本地测试", symbol: "flask")
    }

    func markLoginRequired() {
        hasAuthenticatedSession = false
        syncStatus = .loginRequired
        persistence.clearCookies()
        persistState()
    }

    func addOrUpdate(workItem: WorkItem) {
        if let index = workItems.firstIndex(where: { $0.id == workItem.id }) {
            workItems[index] = workItem
        } else {
            workItems.append(workItem)
        }
        persistState()
    }

    func planningSession(for ticketID: Int) -> RequirementPlanSession? {
        planningSessions.last { $0.ticketID == ticketID }
    }

    func boardStatusTitle(for ticket: Ticket) -> String {
        if planningSession(for: ticket.id)?.awaitsUserConfirmation == true {
            return "待确认"
        }
        if let item = activeWorkItem(for: ticket.id), !item.stage.requiresUserApproval {
            return TicketStatus.processing.rawValue
        }
        return ticket.status.rawValue
    }

    func boardActionTitle(for ticket: Ticket) -> String {
        if planningSession(for: ticket.id)?.awaitsUserConfirmation == true {
            return "去确认"
        }
        return ticket.kind.boardActionTitle
    }

    func addOrUpdate(planningSession: RequirementPlanSession) {
        if let index = planningSessions.firstIndex(where: { $0.id == planningSession.id }) {
            planningSessions[index] = planningSession
        } else {
            planningSessions.append(planningSession)
        }
        persistState()
    }

    func removePlanningSession(ticketID: Int) {
        planningSessions.removeAll { $0.ticketID == ticketID }
        persistState()
    }

    func persistState() {
        AgentCredentialStore.saveAPIKey(agentAPIKey)
        let lastSyncedAt: Date? = {
            if case let .synced(date) = syncStatus { return date }
            return nil
        }()
        persistence.save(
            AppSnapshot(
                tickets: tickets,
                repositories: repositories,
                workItems: workItems,
                planningSessions: planningSessions,
                knowledgeBaseURL: knowledgeBaseURL,
                defaultTestAssignee: defaultTestAssignee,
                syncIntervalHours: clampedAutoSyncIntervalHours,
                hasAuthenticatedSession: hasAuthenticatedSession,
                lastSyncedAt: lastSyncedAt,
                aiProviderOrder: orderedAIProviders,
                isTestModeEnabled: isTestModeEnabled,
                agentAPIURL: agentAPIURL,
                agentAPIKey: "",
                agentModelID: agentModelID,
                agentSystemPrompt: agentSystemPrompt,
                customAIProviders: customAIProviders
            )
        )
    }

    /// 进程启动时若曾登录或本地已有 Cookie，则先恢复 Cookie 再同步最新工单。
    /// 仅执行一次：关闭窗口从程序坞再开不会再次同步。
    func restoreSessionIfNeeded() async {
        guard !hasPerformedLaunchSync else { return }
        hasPerformedLaunchSync = true
        await knowledgeBaseSession.prepareSession(using: persistence)
        guard hasAuthenticatedSession || persistence.hasPersistedCookies || !tickets.isEmpty else {
            syncStatus = .loginRequired
            return
        }
        knowledgeBaseSession.statusMessage = "正在后台更新工单"
        await knowledgeBaseSession.sync(using: self, background: true)
    }

    func runAutomaticSyncLoop() async {
        guard !automaticSyncLoopStarted else { return }
        automaticSyncLoopStarted = true
        while !Task.isCancelled {
            let interval = clampedAutoSyncIntervalHours
            do {
                try await Task.sleep(nanoseconds: UInt64(interval) * 60 * 60 * 1_000_000_000)
            } catch {
                automaticSyncLoopStarted = false
                return
            }
            guard !Task.isCancelled else {
                automaticSyncLoopStarted = false
                return
            }
            guard hasAuthenticatedSession || persistence.hasPersistedCookies || !tickets.isEmpty else { continue }
            await knowledgeBaseSession.sync(using: self, background: true)
        }
        automaticSyncLoopStarted = false
    }

    func presentNewTicketNotifications() {
        guard !newTicketNotifications.isEmpty else { return }
        hasUnreadNewTickets = false
        showingNewTicketsPopover = true
    }

    func registerNewTickets(_ tickets: [Ticket]) {
        guard !tickets.isEmpty else { return }
        newTicketNotifications = tickets
        hasUnreadNewTickets = true
    }

    func persistCookiesBeforeExit() async {
        guard hasAuthenticatedSession || persistence.hasPersistedCookies else { return }
        await knowledgeBaseSession.persistCookies(using: persistence)
    }

    private func loadPersistedState() {
        guard let snapshot = persistence.load() else {
            syncStatus = .loginRequired
            return
        }
        tickets = snapshot.tickets
        projects = Self.rebuildProjects(from: snapshot.tickets)
        repositories = snapshot.repositories
        workItems = snapshot.workItems
        planningSessions = snapshot.planningSessions
        knowledgeBaseURL = KnowledgeBaseQuery.migratedURL(snapshot.knowledgeBaseURL)
        defaultTestAssignee = snapshot.defaultTestAssignee
        autoSyncIntervalHours = min(8, max(1, snapshot.syncIntervalHours))
        hasAuthenticatedSession = snapshot.hasAuthenticatedSession
        aiProviderOrder = AIProvider.normalizedOrder(snapshot.aiProviderOrder)
        isTestModeEnabled = snapshot.isTestModeEnabled
        agentAPIURL = snapshot.agentAPIURL
        agentAPIKey = AgentCredentialStore.loadAPIKey()
        if agentAPIKey.isEmpty, !snapshot.agentAPIKey.isEmpty {
            agentAPIKey = snapshot.agentAPIKey
            AgentCredentialStore.saveAPIKey(agentAPIKey)
        }
        agentModelID = snapshot.agentModelID
        agentSystemPrompt = snapshot.agentSystemPrompt
        customAIProviders = snapshot.customAIProviders
        if customAIProviders.isEmpty, !agentAPIURL.isEmpty {
            let migratedProvider = CustomAIProviderConfig(
                name: "默认自定义模型",
                apiURL: agentAPIURL,
                modelIDs: agentModelID.isEmpty ? [] : [agentModelID],
                selectedModelID: agentModelID,
                systemPrompt: agentSystemPrompt
            )
            customAIProviders = [migratedProvider]
            if !agentAPIKey.isEmpty {
                AgentCredentialStore.saveAPIKey(agentAPIKey, for: migratedProvider.id)
            }
        }
        syncStatus = snapshot.lastSyncedAt.map(SyncStatus.synced)
            ?? (hasAuthenticatedSession || !tickets.isEmpty || isTestModeEnabled ? .idle : .loginRequired)
        recoverInterruptedPlanningSessions()
        recoverCompletedWorkHistoryIfNeeded()
    }

    /// 拆解进行到一半时退出：回到可重试状态，避免一直停在「生成中」。
    func recoverInterruptedPlanningSessions() {
        var changed = false
        for index in planningSessions.indices where planningSessions[index].phase == .compiling {
            planningSessions[index].recoverIfInterrupted()
            changed = true
        }
        if changed { persistState() }
    }

    /// 任务记录丢失时，用本地 Jobs 目录补回已交付工单的流程历史。
    func recoverCompletedWorkHistoryIfNeeded() {
        let ticketIDsMissingHistory = Set(
            tickets.compactMap { ticket -> Int? in
                guard ticket.status == .testing || ticket.status == .completed else { return nil }
                guard !workItems.contains(where: { $0.ticketID == ticket.id }) else { return nil }
                return ticket.id
            }
        )
        guard !ticketIDsMissingHistory.isEmpty else { return }
        let recovered = JobHistoryRecovery.recoverWorkItems(forTicketIDs: ticketIDsMissingHistory)
        guard !recovered.isEmpty else { return }
        workItems.append(contentsOf: recovered)
        persistState()
    }

    private static func placeholderTicket(forCompletedWork item: WorkItem) -> Ticket {
        let summary = item.report?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = summary.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            ?? "工单 #\(item.ticketID)"
        return Ticket(
            id: item.ticketID,
            projectID: "completed-history",
            projectName: "已完成",
            kind: .task,
            priority: .normal,
            status: .completed,
            title: title,
            description: "该工单已不在当前知识库列表中，仍可查看本地交付记录。",
            targetVersion: "",
            updatedAt: item.updatedAt,
            assignee: "",
            sourceURL: nil
        )
    }

    private static func rebuildProjects(from tickets: [Ticket]) -> [Project] {
        var seen: [String: Ticket] = [:]
        for ticket in tickets where seen[ticket.projectID] == nil {
            seen[ticket.projectID] = ticket
        }
        return seen.values
            .map { ticket in
                Project(
                    id: ticket.projectID,
                    name: ticket.projectName,
                    symbol: projectSymbol(for: ticket.projectName)
                )
            }
            .sorted { $0.name < $1.name }
    }

    private static func projectSymbol(for project: String) -> String {
        if project.contains("移动") { return "iphone" }
        if project.contains("数据") { return "server.rack" }
        if project.contains("云") { return "cube" }
        return "square.grid.2x2"
    }
}
