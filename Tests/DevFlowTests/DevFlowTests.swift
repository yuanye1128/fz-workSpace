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
        XCTAssertTrue(JobStage.awaitingPlanApproval.requiresUserApproval)
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
