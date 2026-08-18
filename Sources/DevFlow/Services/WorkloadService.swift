import Foundation

@MainActor
final class WorkloadService {
    private let session: KnowledgeBaseSessionController
    /// 桌面端用持续并发队列，不必等一批全部结束；比插件的 8 路更高，HTTP/2 下能叠更多请求。
    private let detailConcurrency = 12

    init(session: KnowledgeBaseSessionController) {
        self.session = session
    }

    func scanCompletedWorkload(
        months: [String],
        knowledgeBaseURL: String,
        persistence: PersistenceStore,
        onProgress: @escaping (WorkloadScanProgress) -> Void
    ) async throws -> [WorkloadRow] {
        guard let activityURL = WorkloadSettlement.activityURL(fromKnowledgeBaseURL: knowledgeBaseURL) else {
            throw KnowledgeBaseError.parseFailed("工单查询地址中没有当前用户 ID（assigned_to_id），无法打开个人活动页")
        }
        onProgress(
            WorkloadScanProgress(
                phase: .preparing,
                title: "正在准备知识库会话",
                completed: 0,
                total: nil,
                hitCount: 0,
                failedCount: 0,
                skippedCount: 0,
                pageCount: 0,
                candidateCount: 0
            )
        )
        try await session.prepareForWorkloadScan(
            knowledgeBaseURL: knowledgeBaseURL,
            persistence: persistence
        )

        let lookbackStart = WorkloadSettlement.activityLookbackStart(months)
        var candidates: [WorkloadActivityCandidate] = []
        var completedSeen = Set<String>()
        var username = ""
        var pageURL: String? = activityURL.absoluteString
        var visited = Set<String>()

        while let current = pageURL {
            try Task.checkCancellation()
            if visited.contains(current) { break }
            visited.insert(current)
            onProgress(
                WorkloadScanProgress(
                    phase: .collecting,
                    title: "正在收集活动记录",
                    completed: 0,
                    total: nil,
                    hitCount: 0,
                    failedCount: 0,
                    skippedCount: 0,
                    pageCount: visited.count,
                    candidateCount: candidates.count
                )
            )

            let page = try await session.extractWorkloadActivityPage(url: current)
            if page.loginRequired { throw KnowledgeBaseError.loginRequired }
            if username.isEmpty { username = page.username }

            for item in page.candidates {
                if completedSeen.contains(item.issueID) { continue }
                guard WorkloadSettlement.shouldCollectCandidate(
                    date: item.date,
                    months: months,
                    statuses: item.statuses
                ) else { continue }
                if item.statuses.contains("已完成"),
                   WorkloadSettlement.isInSelectedMonths(item.date, months: months) {
                    completedSeen.insert(item.issueID)
                }
                candidates.append(item)
            }

            onProgress(
                WorkloadScanProgress(
                    phase: .collecting,
                    title: "正在收集活动记录",
                    completed: 0,
                    total: nil,
                    hitCount: 0,
                    failedCount: 0,
                    skippedCount: 0,
                    pageCount: visited.count,
                    candidateCount: candidates.count
                )
            )

            if !lookbackStart.isEmpty,
               !page.pageDates.isEmpty,
               page.pageDates.allSatisfy({ $0 < lookbackStart }) {
                break
            }
            if visited.count >= 200 { break }
            pageURL = page.prevURL.isEmpty ? nil : page.prevURL
        }

        if username.isEmpty {
            throw KnowledgeBaseError.parseFailed("未能识别当前用户，请确认已登录知识库")
        }

        let shortcut = WorkloadSettlement.shortcutRows(
            candidates: candidates,
            months: months,
            username: username
        )
        let fetchURLs = Array(
            Set(
                candidates
                    .filter { !$0.url.isEmpty && !shortcut.skipIssueIDs.contains($0.issueID) }
                    .map(\.url)
            )
        )

        var settled: [WorkloadRow] = []
        var failed = 0
        var completed = 0
        var seenURLs = Set<String>()
        let skippedCount = shortcut.skipIssueIDs.count

        func consume(_ extract: WorkloadIssueExtract) {
            guard seenURLs.insert(extract.url).inserted else { return }
            completed += 1
            guard extract.error == nil,
                  let issueID = extract.issueID, !issueID.isEmpty else {
                failed += 1
                reportFetching()
                return
            }
            settled.append(
                contentsOf: WorkloadSettlement.settle(
                    issueID: issueID,
                    title: extract.title ?? "#\(issueID)",
                    url: extract.url,
                    tracker: extract.tracker ?? "",
                    months: months,
                    username: username,
                    timeline: extract.timeline ?? []
                )
            )
            reportFetching()
        }

        func reportFetching() {
            let merged = WorkloadSettlement.merge(shortcut: shortcut.rows, settled: settled)
            if fetchURLs.isEmpty {
                onProgress(
                    WorkloadScanProgress(
                        phase: .finishing,
                        title: "正在结算完成工作量",
                        completed: 1,
                        total: 1,
                        hitCount: merged.count,
                        failedCount: 0,
                        skippedCount: skippedCount,
                        pageCount: visited.count,
                        candidateCount: candidates.count
                    )
                )
                return
            }
            onProgress(
                WorkloadScanProgress(
                    phase: .fetching,
                    title: "正在查询工单详情",
                    completed: completed,
                    total: fetchURLs.count,
                    hitCount: merged.count,
                    failedCount: failed,
                    skippedCount: skippedCount,
                    pageCount: visited.count,
                    candidateCount: candidates.count
                )
            )
        }

        reportFetching()

        if !fetchURLs.isEmpty {
            try Task.checkCancellation()
            let extracts = try await session.extractWorkloadIssueTimelines(
                urls: fetchURLs,
                concurrency: detailConcurrency,
                onItem: consume
            )
            for extract in extracts {
                consume(extract)
            }
        }

        let result = WorkloadSettlement.merge(shortcut: shortcut.rows, settled: settled)
        onProgress(
            WorkloadScanProgress(
                phase: .finishing,
                title: "完成工作量统计完成",
                completed: fetchURLs.isEmpty ? 1 : fetchURLs.count,
                total: fetchURLs.isEmpty ? 1 : fetchURLs.count,
                hitCount: result.count,
                failedCount: failed,
                skippedCount: skippedCount,
                pageCount: visited.count,
                candidateCount: candidates.count
            )
        )
        return result
    }
}

@MainActor
final class WorkloadScanStore: ObservableObject {
    @Published var selectedYear = Calendar.current.component(.year, from: Date())
    @Published var selectedMonths: Set<String> = WorkloadScanStore.defaultSelectedMonths()
    @Published var rows: [WorkloadRow] = []
    @Published var scannedMonths: [String] = []
    @Published var status = "选择月份后统计完成工作量"
    @Published var isScanning = false
    @Published var scanProgress: WorkloadScanProgress?

    private var scanTask: Task<Void, Never>?

    var currentMonthKey: String { Self.monthKey(from: Date()) }

    func monthKey(_ month: Int) -> String {
        "\(selectedYear)-\(String(format: "%02d", month))"
    }

    func selectAllMonths() {
        selectedMonths = Set((1...12).map(monthKey).filter { $0 <= currentMonthKey })
    }

    func stopScan() {
        scanTask?.cancel()
    }

    func startScan(using appState: AppState) {
        let months = selectedMonths.filter { $0 <= currentMonthKey }.sorted()
        guard !months.isEmpty else {
            status = "请选择至少一个已发生的月份"
            return
        }
        guard !isScanning else { return }
        isScanning = true
        rows = []
        scannedMonths = months
        status = "正在准备知识库会话…"
        scanProgress = WorkloadScanProgress(
            phase: .preparing,
            title: "正在准备知识库会话",
            completed: 0,
            total: nil,
            hitCount: 0,
            failedCount: 0,
            skippedCount: 0,
            pageCount: 0,
            candidateCount: 0
        )
        let service = WorkloadService(session: appState.knowledgeBaseSession)
        scanTask = Task {
            do {
                let result = try await service.scanCompletedWorkload(
                    months: months,
                    knowledgeBaseURL: appState.knowledgeBaseURL,
                    persistence: appState.persistence
                ) { progress in
                    self.scanProgress = progress
                }
                rows = result
                status = Self.completionStatus(resultCount: result.count, progress: scanProgress)
            } catch is CancellationError {
                status = "已停止"
            } catch {
                status = error.localizedDescription
                if let knowledgeError = error as? KnowledgeBaseError,
                   case .loginRequired = knowledgeError {
                    appState.showingKnowledgeBaseSession = true
                }
            }
            isScanning = false
            scanProgress = nil
            scanTask = nil
        }
    }

    private static func defaultSelectedMonths() -> Set<String> {
        [monthKey(from: Date())]
    }

    private static func monthKey(from date: Date) -> String {
        let year = Calendar.current.component(.year, from: date)
        let month = Calendar.current.component(.month, from: date)
        return "\(year)-\(String(format: "%02d", month))"
    }

    private static func completionStatus(resultCount: Int, progress: WorkloadScanProgress?) -> String {
        var text = "完成工作量统计完成：命中 \(resultCount) 条"
        guard let progress else { return text }
        if progress.skippedCount > 0 {
            text += "，短路径 \(progress.skippedCount) 个未拉详情"
        }
        if progress.failedCount > 0 {
            text += "，失败 \(progress.failedCount) 个"
        }
        return text
    }
}
