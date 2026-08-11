import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var tickets: [Ticket] = []
    @Published var projects: [Project] = []
    @Published var repositories: [RepositoryConfig] = []
    @Published var workItems: [WorkItem] = []
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
        didSet { UserDefaults.standard.set(themePreference.rawValue, forKey: "themePreference") }
    }
    @Published var knowledgeBaseURL = KnowledgeBaseQuery.allAssignedIssuesURL
    @Published var defaultTestAssignee = ""
    @Published var selectedTicketForReport: Ticket?

    let persistence = PersistenceStore()
    lazy var knowledgeBaseSession = KnowledgeBaseSessionController()
    lazy var jobCoordinator = JobCoordinator(appState: self)
    private var syncInProgress = false

    init() {
        if let storedTheme = UserDefaults.standard.string(forKey: "themePreference"),
           let preference = ThemePreference(rawValue: storedTheme) {
            themePreference = preference
        }
        loadPersistedState()
    }

    /// 没有任何缓存工单且尚未建立会话时，首页才展示登录引导。
    var needsLogin: Bool { tickets.isEmpty && !hasAuthenticatedSession }

    var clampedAutoSyncIntervalHours: Int {
        min(8, max(1, autoSyncIntervalHours))
    }

    var filteredTickets: [Ticket] {
        tickets
            .filter { ticket in
                if let selectedProjectID, ticket.projectID != selectedProjectID { return false }
                switch destination {
                case .all: break
                case .processing:
                    guard isInProcessingList(ticket) else { return false }
                case .approval:
                    guard activeWorkItem(for: ticket.id)?.stage == .awaitingApproval else { return false }
                case .completed:
                    guard ticket.status == .completed || workItems.contains(where: { $0.ticketID == ticket.id && $0.stage == .completed }) else { return false }
                case .repositories, .settings:
                    return false
                }
                if !searchText.isEmpty {
                    let query = searchText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    let haystack = "\(ticket.id) \(ticket.title) \(ticket.description)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    guard haystack.contains(query) else { return false }
                }
                if let kind = filters.kind, ticket.kind != kind { return false }
                if let priority = filters.priority, ticket.priority != priority { return false }
                if let status = filters.status, ticket.status != status { return false }
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

    /// 处理中：有进行中的任务且尚未到“等待确认”；或本地状态为处理中且无确认中任务。
    func isInProcessingList(_ ticket: Ticket) -> Bool {
        if let item = activeWorkItem(for: ticket.id) {
            return item.stage != .awaitingApproval
        }
        return ticket.status == .processing
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
        case .processing:
            tickets.filter { isInProcessingList($0) }.count
        case .approval:
            workItems.filter { $0.stage == .awaitingApproval }.count
        case .completed:
            workItems.filter { $0.stage == .completed }.count
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
        tickets = newTickets
        if let selectedTicketID {
            selectedTicket = newTickets.first(where: { $0.id == selectedTicketID })
        }
        hasAuthenticatedSession = true
        syncStatus = .synced(Date())
        if !newlyDiscoveredTickets.isEmpty {
            newTicketNotifications = newlyDiscoveredTickets
            hasUnreadNewTickets = true
        }
        persistState()
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

    func persistState() {
        let lastSyncedAt: Date? = {
            if case let .synced(date) = syncStatus { return date }
            return nil
        }()
        persistence.save(
            AppSnapshot(
                tickets: tickets,
                repositories: repositories,
                workItems: workItems,
                knowledgeBaseURL: knowledgeBaseURL,
                defaultTestAssignee: defaultTestAssignee,
                syncIntervalHours: clampedAutoSyncIntervalHours,
                hasAuthenticatedSession: hasAuthenticatedSession,
                lastSyncedAt: lastSyncedAt
            )
        )
    }

    /// 启动时若曾登录或本地已有 Cookie，则先恢复 Cookie 再同步最新工单。
    func restoreSessionIfNeeded() async {
        await knowledgeBaseSession.prepareSession(using: persistence)
        guard hasAuthenticatedSession || persistence.hasPersistedCookies || !tickets.isEmpty else {
            syncStatus = .loginRequired
            return
        }
        knowledgeBaseSession.statusMessage = "正在后台更新工单"
        await knowledgeBaseSession.sync(using: self, background: true)
    }

    func runAutomaticSyncLoop() async {
        while !Task.isCancelled {
            let interval = clampedAutoSyncIntervalHours
            do {
                try await Task.sleep(nanoseconds: UInt64(interval) * 60 * 60 * 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard hasAuthenticatedSession || persistence.hasPersistedCookies || !tickets.isEmpty else { continue }
            await knowledgeBaseSession.sync(using: self, background: true)
        }
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
        knowledgeBaseURL = KnowledgeBaseQuery.migratedURL(snapshot.knowledgeBaseURL)
        defaultTestAssignee = snapshot.defaultTestAssignee
        autoSyncIntervalHours = min(8, max(1, snapshot.syncIntervalHours))
        hasAuthenticatedSession = snapshot.hasAuthenticatedSession
        syncStatus = snapshot.lastSyncedAt.map(SyncStatus.synced)
            ?? (hasAuthenticatedSession || !tickets.isEmpty ? .idle : .loginRequired)
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
