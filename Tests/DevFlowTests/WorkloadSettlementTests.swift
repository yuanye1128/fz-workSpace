import XCTest
@testable import DevFlow

final class WorkloadSettlementTests: XCTestCase {
    func testActivityURLUsesAssignedUserID() {
        let url = "https://kb.fzyun.net/issues?assigned_to_id=424&set_filter=1"
        XCTAssertEqual(WorkloadSettlement.userID(fromKnowledgeBaseURL: url), "424")
        XCTAssertEqual(
            WorkloadSettlement.activityURL(fromKnowledgeBaseURL: url)?.absoluteString,
            "https://kb.fzyun.net/activity?user_id=424"
        )
        XCTAssertNil(WorkloadSettlement.userID(fromKnowledgeBaseURL: "https://kb.fzyun.net/issues?set_filter=1"))
        XCTAssertNil(WorkloadSettlement.userID(fromKnowledgeBaseURL: "https://kb.fzyun.net/issues?assigned_to_id=me"))
    }

    func testLookbackCollectsPreviousMonthTestingOnly() {
        XCTAssertEqual(WorkloadSettlement.activityLookbackStart(["2026-07"]), "2026-06-01")
        XCTAssertEqual(WorkloadSettlement.activityLookbackStart(["2026-01"]), "2025-12-01")
        XCTAssertTrue(
            WorkloadSettlement.shouldCollectCandidate(date: "2026-07-20", months: ["2026-07"], statuses: ["已完成"])
        )
        XCTAssertFalse(
            WorkloadSettlement.shouldCollectCandidate(date: "2026-07-20", months: ["2026-07"], statuses: [])
        )
        XCTAssertTrue(
            WorkloadSettlement.shouldCollectCandidate(date: "2026-06-15", months: ["2026-07"], statuses: ["待测试"])
        )
        XCTAssertFalse(
            WorkloadSettlement.shouldCollectCandidate(date: "2026-06-15", months: ["2026-07"], statuses: ["已完成"])
        )
        XCTAssertFalse(
            WorkloadSettlement.shouldCollectCandidate(date: "2026-05-31", months: ["2026-07"], statuses: ["待测试"])
        )
    }

    func testSettleCreditsTestingContributorInCompletionMonth() {
        let rows = WorkloadSettlement.settle(
            issueID: "1001",
            title: "批量禁用",
            url: "https://kb.fzyun.net/issues/1001",
            tracker: "需求",
            months: ["2026-07"],
            username: "A",
            timeline: [
                WorkloadStatusChange(operatorName: "A", changedAt: "2026-06-10", status: "待测试"),
                WorkloadStatusChange(operatorName: "B", changedAt: "2026-07-05", status: "已完成")
            ]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].monthKey, "2026-07")
        XCTAssertEqual(rows[0].operatorName, "A")
        XCTAssertEqual(rows[0].matchedStatuses, "待测试 → 已完成")
        XCTAssertEqual(rows[0].settledAt, "2026-07-05")
    }

    func testCompletedActivityShortcutSkipsIssueDetails() {
        let candidates = [
            WorkloadActivityCandidate(
                issueID: "2001",
                url: "https://kb.fzyun.net/issues/2001",
                date: "2026-07-08",
                statuses: ["已完成"],
                title: "done",
                tracker: "缺陷",
                operatorName: "A",
                orderIndex: 0
            ),
            WorkloadActivityCandidate(
                issueID: "2002",
                url: "https://kb.fzyun.net/issues/2002",
                date: "2026-07-09",
                statuses: ["待测试"],
                title: "testing",
                tracker: "",
                operatorName: "A",
                orderIndex: 1
            ),
            WorkloadActivityCandidate(
                issueID: "2003",
                url: "https://kb.fzyun.net/issues/2003",
                date: "2026-06-20",
                statuses: ["已完成"],
                title: "old",
                tracker: "",
                operatorName: "A",
                orderIndex: 2
            )
        ]
        let shortcut = WorkloadSettlement.shortcutRows(candidates: candidates, months: ["2026-07"], username: "A")
        XCTAssertEqual(shortcut.rows.map(\.issueID), ["2001"])
        XCTAssertEqual(shortcut.skipIssueIDs, ["2001"])
    }

    func testMergeDedupesShortcutAndSettledRows() {
        let shortcut = WorkloadRow(
            issueID: "9",
            monthKey: "2026-07",
            title: "a",
            url: "https://kb.fzyun.net/issues/9",
            tracker: "",
            matchedStatuses: "已完成",
            operatorName: "A",
            settledAt: "2026-07-08",
            contributionChangedAt: "2026-07-08"
        )
        let settled = WorkloadRow(
            issueID: "9",
            monthKey: "2026-07",
            title: "a",
            url: "https://kb.fzyun.net/issues/9",
            tracker: "",
            matchedStatuses: "待测试 → 已完成",
            operatorName: "A",
            settledAt: "2026-07-08",
            contributionChangedAt: "2026-06-01"
        )
        let merged = WorkloadSettlement.merge(shortcut: [shortcut], settled: [settled])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].matchedStatuses, "已完成")
    }

    func testScanProgressReportsDeterminateFraction() {
        let progress = WorkloadScanProgress(
            phase: .fetching,
            title: "正在查询工单详情",
            completed: 24,
            total: 80,
            hitCount: 11,
            failedCount: 1,
            skippedCount: 6,
            pageCount: 3,
            candidateCount: 40
        )
        XCTAssertEqual(progress.fractionCompleted ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(progress.percent, 30)
        XCTAssertEqual(progress.counterText, "24/80 · 30%")
        XCTAssertEqual(progress.detailText, "已命中 11 条  ·  短路径 6  ·  失败 1")
    }

    func testScanProgressCollectingIsIndeterminate() {
        let progress = WorkloadScanProgress(
            phase: .collecting,
            title: "正在收集活动记录",
            completed: 0,
            total: nil,
            hitCount: 0,
            failedCount: 0,
            skippedCount: 0,
            pageCount: 4,
            candidateCount: 38
        )
        XCTAssertNil(progress.fractionCompleted)
        XCTAssertEqual(progress.counterText, "第 4 页")
        XCTAssertEqual(progress.detailText, "已收集 38 个候选")
    }

    func testMonthlyStatsComputesMomAcrossSelectedMonths() {
        let rows = [
            monthRow("3", "2026-03"),
            monthRow("4", "2026-03"),
            monthRow("5", "2026-03"),
            monthRow("ignored", "2026-04")
        ]
        let stats = WorkloadMonthlyStats.build(months: ["2026-03", "2026-01", "2026-02"], rows: rows)
        XCTAssertEqual(stats.total, 3)
        XCTAssertEqual(stats.series.map(\.monthKey), ["2026-01", "2026-02", "2026-03"])
        XCTAssertEqual(stats.series.map(\.count), [0, 0, 3])
        XCTAssertEqual(stats.series[0].mom, .baseline)
        XCTAssertEqual(stats.series[0].mom.label, "—")
        XCTAssertEqual(stats.series[1].mom, .unchangedZero)
        XCTAssertEqual(stats.series[1].mom.label, "0%")
        XCTAssertEqual(stats.series[2].mom, .newlyAppeared)
        XCTAssertEqual(stats.series[2].mom.label, "新增")
    }

    func testMonthlyStatsMomIncreaseAndDecreasePercent() {
        let rows = (1...10).map { monthRow(String($0), "2026-06") }
            + (1...15).map { monthRow("b\($0)", "2026-07") }
            + (1...5).map { monthRow("c\($0)", "2026-08") }
        let stats = WorkloadMonthlyStats.build(months: ["2026-06", "2026-07", "2026-08"], rows: rows)
        XCTAssertEqual(stats.series[1].mom.label, "+50.0%")
        XCTAssertTrue(stats.series[1].mom.isIncrease)
        XCTAssertEqual(stats.series[2].mom.label, "-66.7%")
        XCTAssertTrue(stats.series[2].mom.isDecrease)
        XCTAssertFalse(stats.usesVerticalLayout)
    }

    func testMonthlyStatsUsesVerticalLayoutWhenMoreThanSixMonths() {
        let months = (1...8).map { String(format: "2026-%02d", $0) }
        let rows = months.enumerated().map { monthRow(String($0.offset), $0.element) }
        let stats = WorkloadMonthlyStats.build(months: months, rows: rows)
        XCTAssertTrue(stats.usesVerticalLayout)
        XCTAssertEqual(stats.series[1].mom.label, "+0.0%")
    }

    private func monthRow(_ id: String, _ month: String) -> WorkloadRow {
        WorkloadRow(
            issueID: id,
            monthKey: month,
            title: id,
            url: "https://kb.fzyun.net/issues/\(id)",
            tracker: "",
            matchedStatuses: "已完成",
            operatorName: "A",
            settledAt: "\(month)-08",
            contributionChangedAt: "\(month)-08"
        )
    }
}
