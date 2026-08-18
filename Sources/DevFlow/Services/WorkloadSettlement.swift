import Foundation

struct WorkloadStatusChange: Equatable, Sendable, Decodable {
    var operatorName: String
    var changedAt: String
    var status: String

    enum CodingKeys: String, CodingKey {
        case operatorName = "operator"
        case changedAt
        case status
    }
}

struct WorkloadActivityCandidate: Equatable, Sendable, Decodable {
    var issueID: String
    var url: String
    var date: String
    var statuses: [String]
    var title: String
    var tracker: String
    var operatorName: String
    var orderIndex: Int
}

struct WorkloadRow: Identifiable, Equatable, Sendable {
    var issueID: String
    var monthKey: String
    var title: String
    var url: String
    var tracker: String
    var matchedStatuses: String
    var operatorName: String
    var settledAt: String
    var contributionChangedAt: String

    var id: String { "\(issueID)|\(WorkloadSettlement.normalizedUserName(operatorName))|\(monthKey)" }
    var issueURL: URL? { URL(string: url) }
}

struct WorkloadScanProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case collecting
        case fetching
        case finishing
    }

    var phase: Phase
    var title: String
    var completed: Int
    var total: Int?
    var hitCount: Int
    var failedCount: Int
    var skippedCount: Int
    var pageCount: Int
    var candidateCount: Int

    var fractionCompleted: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    var percent: Int? {
        guard let fractionCompleted else { return nil }
        return Int((fractionCompleted * 100).rounded())
    }

    var counterText: String {
        if let total, let percent {
            return "\(completed)/\(total) · \(percent)%"
        }
        if phase == .collecting, pageCount > 0 {
            return "第 \(pageCount) 页"
        }
        return ""
    }

    var detailText: String {
        switch phase {
        case .preparing:
            return "正在连接知识库"
        case .collecting:
            return candidateCount > 0 ? "已收集 \(candidateCount) 个候选" : "正在读取个人活动页"
        case .fetching, .finishing:
            var parts = ["已命中 \(hitCount) 条"]
            if skippedCount > 0 { parts.append("短路径 \(skippedCount)") }
            if failedCount > 0 { parts.append("失败 \(failedCount)") }
            return parts.joined(separator: "  ·  ")
        }
    }
}

enum WorkloadMonthOverMonth: Equatable, Sendable {
    case baseline
    case unchangedZero
    case newlyAppeared
    case delta(Double)

    var label: String {
        switch self {
        case .baseline:
            return "—"
        case .unchangedZero:
            return "0%"
        case .newlyAppeared:
            return "新增"
        case let .delta(ratio):
            let percent = ratio * 100
            let sign = percent >= 0 ? "+" : ""
            return "\(sign)\(String(format: "%.1f", percent))%"
        }
    }

    var isIncrease: Bool {
        switch self {
        case .newlyAppeared:
            return true
        case let .delta(ratio):
            return ratio > 0
        default:
            return false
        }
    }

    var isDecrease: Bool {
        if case let .delta(ratio) = self { return ratio < 0 }
        return false
    }
}

struct WorkloadMonthStat: Identifiable, Equatable, Sendable {
    var monthKey: String
    var count: Int
    var sharePercent: Double
    var mom: WorkloadMonthOverMonth

    var id: String { monthKey }

    func chartLabel(multiYear: Bool) -> String {
        let month = Int(monthKey.dropFirst(5).prefix(2)) ?? 0
        if multiYear {
            let year = monthKey.prefix(4).suffix(2)
            return "\(year)年\(month)月"
        }
        return "\(month) 月"
    }
}

struct WorkloadMonthlyStats: Equatable, Sendable {
    var series: [WorkloadMonthStat]
    var total: Int

    var maxCount: Int { max(1, series.map(\.count).max() ?? 1) }
    var usesVerticalLayout: Bool { series.count > 6 }
    var isMultiYear: Bool { Set(series.map { String($0.monthKey.prefix(4)) }).count > 1 }

    static func build(months: [String], rows: [WorkloadRow]) -> WorkloadMonthlyStats {
        let months = months.sorted()
        var counts: [String: Int] = [:]
        for month in months { counts[month] = 0 }
        for row in rows where counts[row.monthKey] != nil {
            counts[row.monthKey, default: 0] += 1
        }
        let total = months.reduce(0) { $0 + (counts[$1] ?? 0) }
        let series = months.enumerated().map { index, month -> WorkloadMonthStat in
            let count = counts[month] ?? 0
            let share = total > 0 ? Double(count) / Double(total) * 100 : 0
            let mom: WorkloadMonthOverMonth
            if index == 0 {
                mom = .baseline
            } else {
                let previous = counts[months[index - 1]] ?? 0
                if previous == 0 {
                    mom = count > 0 ? .newlyAppeared : .unchangedZero
                } else {
                    mom = .delta(Double(count - previous) / Double(previous))
                }
            }
            return WorkloadMonthStat(monthKey: month, count: count, sharePercent: share, mom: mom)
        }
        return WorkloadMonthlyStats(series: series, total: total)
    }
}

enum WorkloadSettlement {
    static let targetStatuses = ["待测试", "已完成"]

    static func userID(fromKnowledgeBaseURL rawURL: String) -> String? {
        guard let components = URLComponents(string: rawURL) else { return nil }
        let value = components.queryItems?.first(where: { $0.name == "assigned_to_id" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty, value != "me", value.allSatisfy(\.isNumber) else { return nil }
        return value
    }

    static func activityURL(fromKnowledgeBaseURL rawURL: String) -> URL? {
        guard let userID = userID(fromKnowledgeBaseURL: rawURL),
              let base = URL(string: rawURL) else { return nil }
        var components = URLComponents()
        components.scheme = base.scheme
        components.host = base.host
        components.port = base.port
        components.path = "/activity"
        components.queryItems = [URLQueryItem(name: "user_id", value: userID)]
        return components.url
    }

    static func earliestMonthFirstDay(_ months: [String]) -> String {
        guard let earliest = months.sorted().first else { return "" }
        return "\(earliest)-01"
    }

    static func activityLookbackStart(_ months: [String]) -> String {
        guard let earliest = months.sorted().first, earliest.count >= 7 else { return "" }
        let year = Int(earliest.prefix(4)) ?? 0
        let month = Int(earliest.dropFirst(5).prefix(2)) ?? 1
        let total = year * 12 + (month - 1) - 1
        let lookYear = total / 12
        let lookMonth = (total % 12) + 1
        return "\(lookYear)-\(String(format: "%02d", lookMonth))-01"
    }

    static func isInSelectedMonths(_ date: String, months: [String]) -> Bool {
        guard !date.isEmpty, !months.isEmpty else { return false }
        return months.contains { date.hasPrefix($0) }
    }

    static func shouldCollectCandidate(date: String, months: [String], statuses: [String]) -> Bool {
        guard !date.isEmpty, !statuses.isEmpty else { return false }
        if isInSelectedMonths(date, months: months) {
            return statuses.contains(where: { targetStatuses.contains($0) })
        }
        let lookbackStart = activityLookbackStart(months)
        let monthStart = earliestMonthFirstDay(months)
        guard !lookbackStart.isEmpty, !monthStart.isEmpty else { return false }
        guard date >= lookbackStart, date < monthStart else { return false }
        return statuses.contains("待测试")
    }

    static func shortcutRows(
        candidates: [WorkloadActivityCandidate],
        months: [String],
        username: String
    ) -> (rows: [WorkloadRow], skipIssueIDs: Set<String>) {
        var rows: [WorkloadRow] = []
        var skipIssueIDs = Set<String>()
        var rowKeys = Set<String>()

        for item in candidates {
            guard !item.issueID.isEmpty, !item.date.isEmpty else { continue }
            guard item.statuses.contains("已完成") else { continue }
            guard isInSelectedMonths(item.date, months: months) else { continue }
            skipIssueIDs.insert(item.issueID)

            let operatorName = item.operatorName.isEmpty ? username : item.operatorName
            guard sameUser(operatorName, username) else { continue }

            let monthKey = String(item.date.prefix(7))
            let rowKey = "\(item.issueID)|\(normalizedUserName(operatorName))|\(monthKey)"
            guard !rowKeys.contains(rowKey) else { continue }
            rowKeys.insert(rowKey)
            rows.append(
                WorkloadRow(
                    issueID: item.issueID,
                    monthKey: monthKey,
                    title: item.title.isEmpty ? "#\(item.issueID)" : item.title,
                    url: item.url,
                    tracker: item.tracker,
                    matchedStatuses: "已完成",
                    operatorName: operatorName,
                    settledAt: item.date,
                    contributionChangedAt: item.date
                )
            )
        }
        return (rows, skipIssueIDs)
    }

    static func settle(
        issueID: String,
        title: String,
        url: String,
        tracker: String,
        months: [String],
        username: String,
        timeline: [WorkloadStatusChange]
    ) -> [WorkloadRow] {
        let monthSet = Set(months)
        var rows: [WorkloadRow] = []
        var rowKeys = Set<String>()
        var cycleStart = ""
        let completions = timeline.filter { $0.status == "已完成" }

        for completion in completions {
            let monthKey = String(completion.changedAt.prefix(7))
            var contributors: [String: (operatorName: String, changedAt: String, completedBySelf: Bool)] = [:]

            for change in timeline where change.status == "待测试" {
                if !cycleStart.isEmpty, change.changedAt < cycleStart { continue }
                if change.changedAt > completion.changedAt { continue }
                contributors[normalizedUserName(change.operatorName)] = (
                    change.operatorName,
                    change.changedAt,
                    false
                )
            }
            contributors[normalizedUserName(completion.operatorName)] = (
                completion.operatorName,
                completion.changedAt,
                true
            )

            if monthSet.contains(monthKey) {
                for contributor in contributors.values {
                    guard sameUser(contributor.operatorName, username) else { continue }
                    let rowKey = "\(issueID)|\(normalizedUserName(contributor.operatorName))|\(monthKey)"
                    guard !rowKeys.contains(rowKey) else { continue }
                    rowKeys.insert(rowKey)
                    rows.append(
                        WorkloadRow(
                            issueID: issueID,
                            monthKey: monthKey,
                            title: title.isEmpty ? "#\(issueID)" : title,
                            url: url,
                            tracker: tracker,
                            matchedStatuses: contributor.completedBySelf ? "已完成" : "待测试 → 已完成",
                            operatorName: contributor.operatorName,
                            settledAt: completion.changedAt,
                            contributionChangedAt: contributor.changedAt
                        )
                    )
                }
            }
            cycleStart = completion.changedAt
        }
        return rows
    }

    static func merge(shortcut: [WorkloadRow], settled: [WorkloadRow]) -> [WorkloadRow] {
        var seen = Set<String>()
        var rows: [WorkloadRow] = []
        for row in shortcut + settled {
            if seen.contains(row.id) { continue }
            seen.insert(row.id)
            rows.append(row)
        }
        return rows.sorted {
            if $0.settledAt != $1.settledAt { return $0.settledAt > $1.settledAt }
            return $0.issueID > $1.issueID
        }
    }

    static func normalizedUserName(_ value: String) -> String {
        value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func sameUser(_ actual: String, _ expected: String) -> Bool {
        normalizedUserName(actual) == normalizedUserName(expected)
    }
}

struct WorkloadActivityPageExtract: Decodable {
    var loginRequired: Bool
    var username: String
    var candidates: [WorkloadActivityCandidate]
    var pageDates: [String]
    var prevURL: String
}

struct WorkloadIssueExtract: Decodable {
    var url: String
    var issueID: String?
    var title: String?
    var tracker: String?
    var timeline: [WorkloadStatusChange]?
    var error: String?
}
