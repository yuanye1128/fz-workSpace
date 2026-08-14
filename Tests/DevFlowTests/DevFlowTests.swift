import Foundation
import XCTest
@testable import DevFlow

final class DevFlowTests: XCTestCase {
    @MainActor
    func testTicketSearchAndProjectFiltering() {
        let state = AppState()
        state.tickets = SampleData.tickets
        state.projects = SampleData.projects
        state.searchText = "18423"
        XCTAssertEqual(state.filteredTickets.map(\.id), [18423])

        state.searchText = ""
        state.select(project: SampleData.projects.first(where: { $0.id == "ops" })!)
        XCTAssertEqual(state.filteredTickets.count, SampleData.tickets.filter { $0.projectID == "ops" }.count)
    }

    @MainActor
    func testCachedTicketsDoNotForceLogin() {
        let state = AppState()
        state.tickets = SampleData.tickets
        state.projects = SampleData.projects
        state.hasAuthenticatedSession = false
        XCTAssertFalse(state.needsLogin)

        state.tickets = []
        XCTAssertTrue(state.needsLogin || state.isTestModeEnabled)
        state.isTestModeEnabled = false
        state.hasAuthenticatedSession = false
        state.tickets = []
        XCTAssertTrue(state.needsLogin)
    }

    @MainActor
    func testNewTicketNotificationFlow() {
        let state = AppState()
        state.registerNewTickets([SampleData.tickets[0], SampleData.tickets[1]])

        XCTAssertTrue(state.hasUnreadNewTickets)
        XCTAssertEqual(state.newTicketNotifications.count, 2)

        state.presentNewTicketNotifications()

        XCTAssertFalse(state.hasUnreadNewTickets)
        XCTAssertTrue(state.showingNewTicketsPopover)
    }

    @MainActor
    func testTicketSyncRetainsCachedTicketWithActiveWorkItem() {
        let state = AppState()
        let activeTicket = SampleData.tickets[0]
        let staleTicket = SampleData.tickets[1]
        let syncedTicket = SampleData.tickets[4]
        state.tickets = [activeTicket, staleTicket]
        state.planningSessions = []
        state.workItems = [
            WorkItem(
                ticketID: activeTicket.id,
                provider: .codex,
                repositoryPath: "/tmp/repository",
                branch: "main",
                helperContext: "",
                stage: .runningAI,
                logs: []
            )
        ]

        let merged = state.mergedTicketsPreservingActiveWork([syncedTicket])
        state.tickets = merged
        state.destination = .processing

        XCTAssertEqual(Set(merged.map(\.id)), Set([syncedTicket.id, activeTicket.id]))
        XCTAssertEqual(state.filteredTickets.map(\.id), [activeTicket.id])
        XCTAssertFalse(merged.contains(where: { $0.id == staleTicket.id }))
    }

    @MainActor
    func testCompletedDestinationShowsWorkItemEvenIfTicketLeftAssignedList() {
        let state = AppState()
        let delivered = SampleData.tickets[0]
        let other = SampleData.tickets[4]
        state.tickets = []
        state.workItems = [
            WorkItem(
                ticketID: delivered.id,
                provider: .cursor,
                repositoryPath: "/tmp/repository",
                branch: "main",
                helperContext: "",
                stage: .completed,
                logs: [],
                report: AIReport(
                    summary: "修复了详情跳转",
                    reasoning: "",
                    changedFiles: [],
                    tests: [],
                    risks: [],
                    diff: "",
                    rawOutput: ""
                )
            )
        ]
        state.destination = .completed

        XCTAssertEqual(state.destinationCount(.completed), 1)
        XCTAssertEqual(state.filteredTickets.map(\.id), [delivered.id])
        XCTAssertEqual(state.filteredTickets.first?.title, "修复了详情跳转")

        state.tickets = [delivered]
        state.tickets[0].status = .testing
        let merged = state.mergedTicketsPreservingActiveWork([other])
        XCTAssertEqual(Set(merged.map(\.id)), Set([other.id, delivered.id]))

        state.tickets = merged
        state.filters.status = .completed
        XCTAssertEqual(state.filteredTickets.map(\.id), [delivered.id])
    }

    @MainActor
    func testAssignedTestingTicketsAppearInCompletedUntilTransferred() {
        let state = AppState()
        var ticket = SampleData.tickets[0]
        ticket.status = .testing
        state.tickets = [ticket]
        state.workItems = []
        state.destination = .completed
        state.filters = TicketFilters()
        state.searchText = ""

        XCTAssertEqual(state.filteredTickets.map(\.id), [ticket.id])
        XCTAssertEqual(state.destinationCount(.completed), 1)

        state.tickets = []
        XCTAssertTrue(state.filteredTickets.isEmpty)
        XCTAssertEqual(state.destinationCount(.completed), 0)
    }

    func testJobStageDecodesLegacyMergingName() throws {
        let data = Data("\"合并回目标分支\"".utf8)
        let stage = try JSONDecoder().decode(JobStage.self, from: data)
        XCTAssertEqual(stage, .merging)
    }

    @MainActor
    func testLocalTestTicketSurvivesSyncWithoutActiveWork() {
        let state = AppState()
        state.isTestModeEnabled = true
        state.planningSessions = []
        let existingIDs = Set(state.tickets.map(\.id))
        let created = state.createLocalTestTicket(
            title: "假 Bug：空指针",
            description: "用于本地联调",
            priority: .high
        )
        XCTAssertNotNil(created)
        XCTAssertEqual(created?.kind, .bug)
        XCTAssertTrue(created?.isLocalTest == true)
        XCTAssertNil(created?.sourceURL)
        XCTAssertGreaterThanOrEqual(created?.id ?? 0, AppState.localTestTicketIDBase)
        XCTAssertFalse(state.needsLogin)

        let synced = SampleData.tickets[4]
        let merged = state.mergedTicketsPreservingActiveWork([synced])
        XCTAssertTrue(merged.contains(where: { $0.id == created!.id && $0.isLocalTest }))
        XCTAssertTrue(merged.contains(where: { $0.id == synced.id }))
        XCTAssertTrue(Set(merged.map(\.id)).isSuperset(of: [synced.id, created!.id]))
        XCTAssertTrue(merged.filter(\.isLocalTest).map(\.id).allSatisfy { existingIDs.contains($0) || $0 == created!.id })
    }

    @MainActor
    func testLocalTestTicketCanSelectRequirementKind() {
        let state = AppState()
        state.isTestModeEnabled = true
        let created = state.createLocalTestTicket(
            title: "假需求：批量禁用",
            description: "用于验证需求拆解",
            priority: .high,
            kind: .feature
        )
        XCTAssertEqual(created?.kind, .feature)
        XCTAssertTrue(created?.isLocalTest == true)
        XCTAssertEqual(created?.kind.executionMode, .requirementPlanning)
    }

    @MainActor
    func testDeleteLocalTestTicketBlockedWhenActive() {
        let state = AppState()
        state.isTestModeEnabled = true
        let created = state.createLocalTestTicket(title: "不可删进行中", description: "x", priority: .normal)!
        state.workItems = [
            WorkItem(
                ticketID: created.id,
                provider: .cursor,
                repositoryPath: "/tmp/repository",
                branch: "main",
                helperContext: "",
                stage: .runningAI,
                logs: []
            )
        ]
        state.deleteLocalTestTicket(id: created.id)
        XCTAssertTrue(state.tickets.contains(where: { $0.id == created.id }))

        state.workItems = []
        state.deleteLocalTestTicket(id: created.id)
        XCTAssertFalse(state.tickets.contains(where: { $0.id == created.id }))
    }

    func testTicketDecodesWithoutLocalTestFlag() throws {
        let json = """
        {
          "id": 42,
          "projectID": "ops",
          "projectName": "运营后台",
          "kind": "Bug",
          "priority": "普通",
          "status": "新建",
          "title": "旧工单",
          "description": "desc",
          "targetVersion": "v1",
          "updatedAt": "2024-01-01T00:00:00Z",
          "assignee": "tester"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ticket = try decoder.decode(Ticket.self, from: json)
        XCTAssertFalse(ticket.isLocalTest)
    }

    @MainActor
    func testSuggestedCommitMessagePrefersTicketTitleOverFileCentricSummary() {
        let ticket = Ticket(
            id: 9_000_002,
            projectID: "ops",
            projectName: "运营后台",
            kind: .bug,
            priority: .high,
            status: .new,
            title: "统计上报提交失败导致数据丢失",
            description: "在特定条件下 statistics transform 提交失败",
            targetVersion: "test",
            updatedAt: Date(),
            assignee: "本地测试",
            sourceURL: nil,
            isLocalTest: true
        )
        let message = ticket.suggestedCommitMessage(
            summary: "在 `plugins/core/lib/statistics/statistics_transform.dart` 的 `_submitUseD` 增加空值保护"
        )
        XCTAssertEqual(message, "fix: #9000002 统计上报提交失败导致数据丢失")
        XCTAssertFalse(message.contains("statistics_transform"))
    }

    func testKnowledgeBaseQueryRemovesSinglePageAndMigratesLegacyDefault() {
        let paged = "https://kb.fzyun.net/issues?assigned_to_id=424&page=3&set_filter=1&sort=priority%3Adesc%2Cupdated_on%3Adesc"
        let allPages = KnowledgeBaseQuery.allPagesURL(paged)
        XCTAssertFalse(allPages.contains("page="))
        XCTAssertTrue(allPages.contains("assigned_to_id=424"))
        XCTAssertTrue(allPages.contains("set_filter=1"))

        let legacy = "https://kb.fzyun.net/issues?assigned_to_id=424&page=1&set_filter=1&sort=fixed_version%2Cpriority%3Adesc%2Cupdated_on%3Adesc"
        XCTAssertEqual(KnowledgeBaseQuery.migratedURL(legacy), KnowledgeBaseQuery.allAssignedIssuesURL)
    }

    func testTicketKindsIncludeAllExpectedTypes() {
        XCTAssertEqual(
            TicketKind.allCases.map(\.rawValue),
            ["Bug", "需求", "建议", "支持", "任务"]
        )
        XCTAssertEqual(TicketKind.feature.executionMode, .requirementPlanning)
        XCTAssertEqual(TicketKind.task.executionMode, .externalAgent)
        XCTAssertEqual(TicketKind.bug.executionMode, .inAppPipeline)
        XCTAssertEqual(TicketKind.feature.boardActionTitle, "去处理")
        XCTAssertEqual(TicketKind.bug.boardActionTitle, "去解决")
        XCTAssertFalse(TicketKind.feature.prefersExternalAgentClient)
        XCTAssertTrue(TicketKind.task.prefersExternalAgentClient)
    }

    @MainActor
    func testRequirementPlanningCardShowsPendingConfirmationWhenAwaitingUser() {
        var session = RequirementPlanSession(
            ticketID: 18425,
            intensity: .medium,
            provider: .cursor,
            repositoryPath: "/tmp/repo",
            branch: "main",
            helperContext: "",
            phase: .compiling
        )
        XCTAssertFalse(session.awaitsUserConfirmation)

        session.phase = .questioning
        XCTAssertTrue(session.awaitsUserConfirmation)
        session.phase = .ready
        XCTAssertTrue(session.awaitsUserConfirmation)
        session.phase = .failed
        XCTAssertFalse(session.awaitsUserConfirmation)

        let state = AppState()
        let ticket = SampleData.tickets.first { $0.id == 18425 }!
        state.tickets = [ticket]
        XCTAssertEqual(state.boardStatusTitle(for: ticket), "新建")
        XCTAssertEqual(state.boardActionTitle(for: ticket), "去处理")

        session.phase = .compiling
        state.planningSessions = [session]
        XCTAssertEqual(state.boardStatusTitle(for: ticket), "新建")
        XCTAssertEqual(state.boardActionTitle(for: ticket), "去处理")

        var processingTicket = ticket
        processingTicket.status = .processing
        state.tickets = [processingTicket]
        XCTAssertEqual(state.boardStatusTitle(for: processingTicket), "处理中")

        session.phase = .questioning
        state.planningSessions = [session]
        XCTAssertEqual(state.boardStatusTitle(for: processingTicket), "待确认")
        XCTAssertEqual(state.boardActionTitle(for: processingTicket), "去确认")

        session.phase = .ready
        state.planningSessions = [session]
        XCTAssertEqual(state.boardStatusTitle(for: processingTicket), "待确认")
        XCTAssertEqual(state.boardActionTitle(for: processingTicket), "去确认")
    }

    func testRequirementPlanningIntensityQuestionRanges() {
        XCTAssertEqual(RequirementPlanningIntensity.low.questionRange, 3...5)
        XCTAssertEqual(RequirementPlanningIntensity.medium.questionRange, 5...8)
        XCTAssertEqual(RequirementPlanningIntensity.high.questionRange, 10...10)
        XCTAssertEqual(RequirementPlanningIntensity.medium.clampedQuestionTotal(3), 5)
        XCTAssertEqual(RequirementPlanningIntensity.medium.clampedQuestionTotal(9), 8)
        XCTAssertEqual(RequirementPlanningIntensity.high.clampedQuestionTotal(7), 10)
    }

    func testLegacySnapshotDefaultsAutoSyncInterval() throws {
        let json = """
        {
          "tickets": [],
          "repositories": [],
          "workItems": [],
          "knowledgeBaseURL": "https://kb.example.com/issues",
          "defaultTestAssignee": "alice",
          "hasAuthenticatedSession": true
        }
        """
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(AppSnapshot.self, from: data)

        XCTAssertEqual(snapshot.syncIntervalHours, 2)
        XCTAssertEqual(snapshot.aiProviderOrder, [.cursor, .codex, .claude])
        XCTAssertTrue(snapshot.planningSessions.isEmpty)
    }

    func testAIProviderDefaultOrderPutsCursorFirst() {
        XCTAssertEqual(Array(AIProvider.allCases), [.cursor, .codex, .claude])
    }

    func testAIProviderNormalizedOrderKeepsCustomOrderAndAppendsMissing() {
        XCTAssertEqual(
            AIProvider.normalizedOrder([.claude, .claude, .codex]),
            [.claude, .codex, .cursor]
        )
        XCTAssertEqual(AIProvider.normalizedOrder([]), [.cursor, .codex, .claude])
    }

    func testSnapshotDecodesCustomAIProviderOrder() throws {
        let json = """
        {
          "tickets": [],
          "repositories": [],
          "workItems": [],
          "knowledgeBaseURL": "https://kb.example.com/issues",
          "defaultTestAssignee": "alice",
          "hasAuthenticatedSession": true,
          "aiProviderOrder": ["Claude Code", "Cursor", "unknown"]
        }
        """
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(AppSnapshot.self, from: data)

        XCTAssertEqual(snapshot.aiProviderOrder, [.claude, .cursor, .codex])
    }

    @MainActor
    func testMovingAIProviderUpdatesOrderedList() {
        let state = AppState()
        state.aiProviderOrder = [.cursor, .codex, .claude]
        state.moveAIProvider(.claude, to: .cursor)
        XCTAssertEqual(state.orderedAIProviders, [.claude, .cursor, .codex])
        state.moveAIProvider(.codex, to: .claude)
        XCTAssertEqual(state.orderedAIProviders, [.codex, .claude, .cursor])
        state.moveAIProvider(.codex, to: .codex)
        XCTAssertEqual(state.orderedAIProviders, [.codex, .claude, .cursor])
    }

    func testPromptContainsSafetyGateAndIssueContext() {
        let ticket = SampleData.tickets[3]
        let prompt = PromptBuilder.build(ticket: ticket, helperContext: "检查 lib/user/profile")
        XCTAssertTrue(prompt.contains(ticket.issueNumber))
        XCTAssertTrue(prompt.contains("不要执行 git commit、git pull、git push"))
        XCTAssertTrue(prompt.contains("DEVFLOW_SUMMARY:"))
        XCTAssertTrue(prompt.contains("检查 lib/user/profile"))
    }

    func testAnalysisPromptIsReadOnlyAndRequestsAModificationPlan() {
        let prompt = PromptBuilder.buildAnalysis(ticket: SampleData.tickets[3], helperContext: "检查 lib/user/profile")
        XCTAssertTrue(prompt.contains("绝对不要修改、创建或删除任何文件"))
        XCTAssertTrue(prompt.contains("DEVFLOW_ROOT_CAUSE:"))
        XCTAssertTrue(prompt.contains("DEVFLOW_PLAN:"))
        XCTAssertTrue(prompt.contains("非交互流水线"))
        XCTAssertTrue(JobStage.awaitingPlanApproval.requiresUserApproval)
    }

    func testProtocolMarkerGateRejectsProgressOnlyOutput() {
        let progress = "先按工单定位相关代码\n继续核对帖子详情跳转门槛"
        XCTAssertFalse(PromptBuilder.hasRequiredProtocolMarkers(progress, phase: .analysis))
        XCTAssertFalse(PromptBuilder.hasRequiredProtocolMarkers(progress, phase: .modification))

        let analysis = """
        DEVFLOW_ROOT_CAUSE:
        瀑布流正文未绑定点击回调
        DEVFLOW_PLAN:
        1. 在 CirclePostGridPage 绑定 onTapContent
        DEVFLOW_RISKS:
        - 需回归标题与封面点击
        """
        XCTAssertTrue(PromptBuilder.hasRequiredProtocolMarkers(analysis, phase: .analysis))
        XCTAssertEqual(
            PromptBuilder.extractProtocolBlock(from: "前言\n\(analysis)", phase: .analysis)?.hasPrefix("DEVFLOW_ROOT_CAUSE:"),
            true
        )

        let modification = """
        DEVFLOW_SUMMARY:
        绑定了正文点击跳转
        DEVFLOW_REASONING:
        空 GestureDetector 吞掉了点击
        DEVFLOW_TESTS:
        - 未执行自动化，建议手工点封面标题正文
        DEVFLOW_RISKS:
        - 未发现明显额外风险
        """
        XCTAssertTrue(PromptBuilder.hasRequiredProtocolMarkers(modification, phase: .modification))
    }

    func testProtocolMarkerGateRejectsPromptTemplateEcho() {
        let promptEcho = PromptBuilder.buildAnalysis(ticket: SampleData.tickets[3], helperContext: "")
        XCTAssertFalse(PromptBuilder.hasRequiredProtocolMarkers(promptEcho, phase: .analysis))

        let rawLogEcho = """
        DEVFLOW_ROOT_CAUSE:
        <根因>
        DEVFLOW_PLAN:
        1. <修改步骤>
        DEVFLOW_RISKS:
        - <风险>
        {"type":"thinking","subtype":"delta","text":"x","session_id":"abc"}
        """
        XCTAssertFalse(PromptBuilder.hasRequiredProtocolMarkers(rawLogEcho, phase: .analysis))
        XCTAssertTrue(PromptBuilder.isProtocolTemplateEcho(rawLogEcho))
    }

    func testWrapCursorPlanAsAnalysisProtocolPassesGate() {
        let markdown = """
        # 修复点击无法跳转

        ## 根因
        正文区域 GestureDetector 吞掉点击。

        ## 修改步骤
        1. 绑定 onTapContent
        2. 修正 onTapTitle
        """
        let wrapped = PromptBuilder.wrapCursorPlanAsAnalysisProtocol(markdown)
        XCTAssertTrue(PromptBuilder.hasRequiredProtocolMarkers(wrapped, phase: .analysis))
        XCTAssertTrue(wrapped.contains("绑定 onTapContent"))
    }

    func testReportParserKeepsChangedFilesAndSections() {
        let report = PromptBuilder.parseReport(
            finalMessage: """
            DEVFLOW_SUMMARY:
            优化用户详情查询。
            DEVFLOW_REASONING:
            减少关联查询并补充索引。
            DEVFLOW_TESTS:
            - swift test 通过
            DEVFLOW_RISKS:
            - 需要关注高并发场景
            """,
            rawOutput: "raw",
            changedFiles: ["Sources/UserProfile.swift"],
            diff: "+ query"
        )
        XCTAssertEqual(report.summary, "优化用户详情查询。")
        XCTAssertEqual(report.reasoning, "减少关联查询并补充索引。")
        XCTAssertEqual(report.changedFiles, ["Sources/UserProfile.swift"])
        XCTAssertEqual(report.tests, ["swift test 通过"])
        XCTAssertEqual(report.risks, ["需要关注高并发场景"])
    }

    func testLegacyWorkItemDecodesWithoutExecutionRecord() throws {
        let item = WorkItem(
            ticketID: 42,
            provider: .codex,
            repositoryPath: "/tmp/repository",
            branch: "main",
            helperContext: "",
            stage: .analyzing,
            logs: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(item)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(object?["execution"])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkItem.self, from: data)
        XCTAssertNil(decoded.execution)
    }

    func testExecutionRecordPersistsWithWorkItem() throws {
        let runID = UUID()
        let execution = AIExecutionRecord(
            runID: runID,
            phase: .modification,
            runDirectory: "/tmp/\(runID.uuidString)",
            workerPID: 123,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOutputOffset: 48,
            state: .recovered
        )
        let item = WorkItem(
            ticketID: 42,
            provider: .codex,
            repositoryPath: "/tmp/repository",
            branch: "main",
            helperContext: "",
            stage: .runningAI,
            logs: [],
            execution: execution
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(WorkItem.self, from: data)
        XCTAssertEqual(decoded.execution, execution)
    }

    func testDurableExecutionDetectsResultFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("devflow-result-\(UUID().uuidString)")
        let runID = UUID()
        let runDirectory = root.appendingPathComponent(runID.uuidString)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = DurableExecutionFiles(runDirectory: runDirectory)
        try files.writeJSON(
            DurableExecutionResultFile(runID: runID, exitCode: 0, endedAt: Date(), launchError: nil),
            to: files.resultURL
        )
        let execution = AIExecutionRecord(
            runID: runID,
            phase: .analysis,
            runDirectory: runDirectory.path,
            workerPID: 999_999,
            startedAt: Date(),
            lastOutputOffset: 0,
            state: .running
        )
        XCTAssertEqual(DurableProcessRunner().inspect(execution: execution), .completed)
    }

    func testDurableWorkerWritesOutputHeartbeatAndResult() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("devflow-worker-\(UUID().uuidString)")
        let runID = UUID()
        let runDirectory = root.appendingPathComponent(runID.uuidString)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = DurableExecutionFiles(runDirectory: runDirectory)
        try files.writeJSON(
            DurableWorkerConfiguration(
                runID: runID,
                executable: "/bin/sh",
                arguments: ["-c", "printf 'worker-line\\n'"],
                workingDirectory: runDirectory.path,
                environment: [:]
            ),
            to: files.configurationURL
        )

        XCTAssertEqual(DurableExecutionWorker.run(configurationPath: files.configurationURL.path), 0)
        XCTAssertEqual(try String(contentsOf: files.standardOutputURL, encoding: .utf8), "worker-line\n")
        XCTAssertEqual(files.readJSON(DurableExecutionHeartbeat.self, from: files.heartbeatURL)?.runID, runID)
        XCTAssertEqual(files.readJSON(DurableExecutionResultFile.self, from: files.resultURL)?.exitCode, 0)
    }

    func testHeartbeatFreshnessClassification() {
        let now = Date()
        XCTAssertEqual(
            DurableProcessRunner.classify(
                resultExists: false,
                workerIsAlive: true,
                heartbeatDate: now.addingTimeInterval(-2),
                startedAt: now.addingTimeInterval(-30),
                now: now
            ),
            .running
        )
        XCTAssertEqual(
            DurableProcessRunner.classify(
                resultExists: false,
                workerIsAlive: true,
                heartbeatDate: now.addingTimeInterval(-20),
                startedAt: now.addingTimeInterval(-30),
                now: now
            ),
            .interrupted
        )
        XCTAssertEqual(
            DurableProcessRunner.classify(
                resultExists: false,
                workerIsAlive: false,
                heartbeatDate: now,
                startedAt: now,
                now: now
            ),
            .interrupted
        )
    }

    func testDurableLogReadsContinueFromByteOffsetWithoutDuplication() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("devflow-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try "first\nsecond\n".write(to: file, atomically: true, encoding: .utf8)
        let first = try DurableProcessRunner.readLines(at: file, from: 0, includePartial: false)
        XCTAssertEqual(first.lines, ["first", "second"])

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("third\n".utf8))
        try handle.close()
        let resumed = try DurableProcessRunner.readLines(at: file, from: first.nextOffset, includePartial: false)
        XCTAssertEqual(resumed.lines, ["third"])
    }

    func testGitServiceBlocksDirtyWorkspaceAndDetectsPullConflict() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("devflow-git-\(UUID().uuidString)")
        let remote = root.appendingPathComponent("remote.git")
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "--bare", remote.path], at: root.path)
        try runGit(["clone", remote.path, first.path], at: root.path)
        try configureGit(at: first.path)
        try "base\n".write(to: first.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "value.txt"], at: first.path)
        try runGit(["commit", "-m", "base"], at: first.path)
        try runGit(["branch", "-M", "main"], at: first.path)
        try runGit(["push", "-u", "origin", "main"], at: first.path)
        try runGit(["symbolic-ref", "HEAD", "refs/heads/main"], at: remote.path)

        try runGit(["clone", "--branch", "main", remote.path, second.path], at: root.path)
        try configureGit(at: second.path)

        let service = GitService()
        try "dirty\n".write(to: first.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)
        let dirty = await service.validateRepository(path: first.path)
        XCTAssertTrue(dirty.isGitRepository)
        XCTAssertFalse(dirty.isClean)

        try runGit(["restore", "."], at: first.path)
        try "from-first\n".write(to: first.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
        try runGit(["commit", "-am", "first change"], at: first.path)

        try "from-second\n".write(to: second.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
        try runGit(["commit", "-am", "second change"], at: second.path)
        try runGit(["push", "origin", "main"], at: first.path)

        let pull = try await service.pullLatest(remote: "origin", branch: "main", at: second.path)
        XCTAssertFalse(pull.conflicts.isEmpty)
        XCTAssertTrue(pull.conflicts.contains("value.txt"))
        XCTAssertNotEqual(try runGit(["status", "--porcelain"], at: second.path), "")
    }

    func testWorktreeKeepsMainCheckoutAndMergeReportsConflicts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("devflow-wt-\(UUID().uuidString)")
        let remote = root.appendingPathComponent("remote.git")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "--bare", remote.path], at: root.path)
        try runGit(["clone", remote.path, repo.path], at: root.path)
        try configureGit(at: repo.path)
        try "base\n".write(to: repo.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "value.txt"], at: repo.path)
        try runGit(["commit", "-m", "base"], at: repo.path)
        try runGit(["branch", "-M", "main"], at: repo.path)
        try runGit(["push", "-u", "origin", "main"], at: repo.path)
        try runGit(["checkout", "-b", "feature"], at: repo.path)
        try "feature-only\n".write(to: repo.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "feature.txt"], at: repo.path)
        try runGit(["commit", "-m", "feature work"], at: repo.path)

        let service = GitService()
        let mainBefore = try await service.currentBranch(at: repo.path)
        XCTAssertEqual(mainBefore, "feature")

        let taskWT = root.appendingPathComponent("task-wt").path
        try await service.createTaskWorktree(
            repositoryPath: repo.path,
            targetBranch: "main",
            taskBranch: "devflow/task-1",
            worktreePath: taskWT
        )
        let branchAfterTaskWT = try await service.currentBranch(at: repo.path)
        let taskBranchName = try await service.currentBranch(at: taskWT)
        XCTAssertEqual(branchAfterTaskWT, "feature")
        XCTAssertEqual(taskBranchName, "devflow/task-1")

        try "task-change\n".write(to: URL(fileURLWithPath: taskWT).appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
        let hash = try await service.commit(message: "fix: #1 task", at: taskWT)
        XCTAssertFalse(hash.isEmpty)

        let mergeWT = root.appendingPathComponent("merge-wt").path
        try await service.createMergeWorktree(
            repositoryPath: repo.path,
            targetBranch: "main",
            mergeBranch: "devflow/merge-1",
            worktreePath: mergeWT
        )
        let branchAfterMergeWT = try await service.currentBranch(at: repo.path)
        XCTAssertEqual(branchAfterMergeWT, "feature")

        let merge = try await service.squashMergeBranch(
            "devflow/task-1",
            intoCheckoutAt: mergeWT,
            message: "fix: #1 task-change"
        )
        XCTAssertTrue(merge.success)
        XCTAssertNotNil(merge.mergedCommitHash)
        let log = try runGit(["log", "-1", "--pretty=%s"], at: mergeWT)
        XCTAssertEqual(log, "fix: #1 task-change")
        XCTAssertFalse(log.lowercased().contains("merge"))

        try await service.pushHEAD(toRemoteBranch: "main", remote: "origin", at: mergeWT)
        let branchAfterPush = try await service.currentBranch(at: repo.path)
        XCTAssertEqual(branchAfterPush, "feature")

        // conflict case
        let taskWT2 = root.appendingPathComponent("task-wt-2").path
        try await service.createTaskWorktree(
            repositoryPath: repo.path,
            targetBranch: "main",
            taskBranch: "devflow/task-2",
            worktreePath: taskWT2
        )
        try "from-task-2\n".write(to: URL(fileURLWithPath: taskWT2).appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
        _ = try await service.commit(message: "task2", at: taskWT2)

        let other = root.appendingPathComponent("other")
        try runGit(["clone", "--branch", "main", remote.path, other.path], at: root.path)
        try configureGit(at: other.path)
        try "from-remote\n".write(to: other.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
        try runGit(["commit", "-am", "remote change"], at: other.path)
        try runGit(["push", "origin", "main"], at: other.path)

        // refresh local main ref without checking it out
        try runGit(["fetch", "origin"], at: repo.path)
        try runGit(["update-ref", "refs/heads/main", "refs/remotes/origin/main"], at: repo.path)

        let mergeWT2 = root.appendingPathComponent("merge-wt-2").path
        try await service.createMergeWorktree(
            repositoryPath: repo.path,
            targetBranch: "main",
            mergeBranch: "devflow/merge-2",
            worktreePath: mergeWT2
        )
        let conflicted = try await service.squashMergeBranch(
            "devflow/task-2",
            intoCheckoutAt: mergeWT2,
            message: "fix: #2 conflict"
        )
        XCTAssertFalse(conflicted.success)
        XCTAssertEqual(conflicted.conflicts.contains("value.txt"), true)
        let branchFinal = try await service.currentBranch(at: repo.path)
        XCTAssertEqual(branchFinal, "feature")
    }

    func testRequirementPlanningPromptAsksOneQuestionAndKeepsAssumptions() {
        let ticket = SampleData.tickets.first { $0.kind == .feature }!
        let prompt = PromptBuilder.buildRequirementPlanning(
            ticket: ticket,
            helperContext: "只做后台接口",
            intensity: .medium,
            askedCount: 0,
            questionTotal: nil,
            messages: [],
            finishNow: false
        )
        XCTAssertTrue(prompt.contains("每次回复只能做一件事"))
        XCTAssertTrue(prompt.contains("不要再确认"))
        XCTAssertTrue(prompt.contains("DEVFLOW_PLANNING_QUESTION:"))
        XCTAssertTrue(prompt.contains("DEVFLOW_PLAN_DOCUMENT:"))
        XCTAssertTrue(prompt.contains("验收清单"))
        XCTAssertTrue(prompt.contains("明确不做"))
        XCTAssertTrue(prompt.contains("题数不固定"))
        XCTAssertTrue(prompt.contains("必须继续问"))
        XCTAssertTrue(prompt.contains("合并成一个问题"))
        XCTAssertTrue(prompt.contains("资深工程师交给普通开发"))
        XCTAssertTrue(prompt.contains("改动范围"))
        XCTAssertTrue(prompt.contains("分步实现"))
        XCTAssertTrue(prompt.contains("只做后台接口"))
        XCTAssertFalse(PromptBuilder.hasRequiredProtocolMarkers(prompt, phase: .planning))
    }

    func testRequirementPlanningTurnParserAcceptsSingleQuestionAndDocument() {
        let question = """
        DEVFLOW_PLANNING_QUESTION:
        批量禁用是否需要二次确认？
        DEVFLOW_QUESTION_INDEX: 1
        DEVFLOW_QUESTION_TOTAL: 6
        """
        XCTAssertEqual(
            PromptBuilder.parseRequirementPlanningTurn(question),
            .question(text: "批量禁用是否需要二次确认？", index: 1, total: 6)
        )

        let combined = """
        DEVFLOW_PLANNING_QUESTION:
        是否需要二次确认？权限失败怎么提示？
        DEVFLOW_QUESTION_INDEX: 2
        """
        XCTAssertEqual(
            PromptBuilder.parseRequirementPlanningTurn(combined),
            .question(text: "是否需要二次确认？权限失败怎么提示？", index: 2, total: nil)
        )

        let document = """
        DEVFLOW_PLAN_DOCUMENT:
        # 需求描述
        支持按条件批量禁用用户。
        ## 验收清单
        ### 核心流程
        - [ ] 能按筛选结果批量禁用
        ### 异常情况
        - [ ] 无权限时提示失败
        ### 空状态
        - [ ] 无匹配用户时禁用按钮不可用
        ### 加载状态
        - [ ] 提交中显示进度
        ### 不同设备适配
        - [ ] 窄屏操作区不遮挡
        ## 假设
        - 仅管理员可操作
        ## 本次范围
        - 列表批量禁用
        ## 明确不做
        - 不做跨项目同步
        ## 开发计划
        ### 改动范围
        - 复用现有用户列表筛选；新增批量禁用接口
        ### 分步实现
        1. 增加批量禁用接口
           - 做法：在 UserController 增加批量接口，校验管理员权限，按 id 列表更新禁用状态
           - 涉及：UserController、UserService
           - 验证：无权限返回 403；空列表拒绝
        2. 列表入口
           - 做法：筛选结果页增加批量禁用，二次确认后调用接口并刷新
           - 涉及：UserListPage
           - 验证：未选中时按钮不可用
        ### 注意点
        - 先接口后前端；不要改单用户禁用逻辑
        """
        XCTAssertTrue(PromptBuilder.hasRequiredProtocolMarkers(document, phase: .planning))
        if case let .document(parsed) = PromptBuilder.parseRequirementPlanningTurn(document) {
            XCTAssertTrue(parsed.contains("支持按条件批量禁用用户"))
            XCTAssertTrue(parsed.contains("明确不做"))
            XCTAssertTrue(parsed.contains("不同设备适配"))
            XCTAssertTrue(parsed.contains("分步实现"))
            XCTAssertTrue(parsed.contains("UserController"))
        } else {
            XCTFail("expected planning document")
        }

        let thinPlan = """
        DEVFLOW_PLAN_DOCUMENT:
        # 需求描述
        支持按条件批量禁用用户。
        ## 验收清单
        ### 核心流程
        - [ ] 能按筛选结果批量禁用
        ### 异常情况
        - [ ] 无权限时提示失败
        ### 空状态
        - [ ] 无匹配用户时禁用按钮不可用
        ### 加载状态
        - [ ] 提交中显示进度
        ### 不同设备适配
        - [ ] 窄屏操作区不遮挡
        ## 假设
        - 仅管理员可操作
        ## 本次范围
        - 列表批量禁用
        ## 明确不做
        - 不做跨项目同步
        ## 开发计划
        1. 增加批量接口与列表入口
        """
        XCTAssertNil(PromptBuilder.parseRequirementPlanningTurn(thinPlan))
    }

    func testExternalAgentTaskFilePrefersDevelopmentDocument() {
        let ticket = SampleData.tickets.first { $0.kind == .feature }!
        let markdown = ExternalAgentLauncher.taskFileMarkdown(
            for: .init(
                ticket: ticket,
                repositoryPath: "/tmp/repo",
                branch: "main",
                helperContext: "忽略我",
                provider: .cursor,
                developmentDocument: "# 需求描述\n按计划实现批量禁用。"
            )
        )
        XCTAssertTrue(markdown.contains("请按下方开发计划直接实施"))
        XCTAssertTrue(markdown.contains("按计划实现批量禁用"))
        XCTAssertFalse(markdown.contains("忽略我"))
    }

    func testInterruptedPlanningSessionBecomesRetryable() {
        var empty = RequirementPlanSession(
            ticketID: 18425,
            intensity: .medium,
            provider: .cursor,
            repositoryPath: "/tmp/repo",
            branch: "main",
            helperContext: "",
            phase: .compiling
        )
        empty.recoverIfInterrupted()
        XCTAssertEqual(empty.phase, .failed)
        XCTAssertEqual(empty.errorMessage, "上次拆解在退出时中断，请重试。")

        var withMessages = empty
        withMessages.phase = .compiling
        withMessages.messages = [PlanningMessage(role: .assistant, content: "范围是否包含移动端？")]
        withMessages.recoverIfInterrupted()
        XCTAssertEqual(withMessages.phase, .questioning)
    }

    private func configureGit(at path: String) throws {
        try runGit(["config", "user.email", "devflow@example.com"], at: path)
        try runGit(["config", "user.name", "DevFlow Tests"], at: path)
    }

    @discardableResult
    private func runGit(_ arguments: [String], at path: String) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "DevFlowTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
