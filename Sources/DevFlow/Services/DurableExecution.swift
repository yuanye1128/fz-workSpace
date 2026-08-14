import Darwin
import Foundation

struct DurableWorkerConfiguration: Codable, Sendable {
    var runID: UUID
    var executable: String
    var arguments: [String]
    var workingDirectory: String
    var environment: [String: String]
}

struct DurableExecutionManifest: Codable, Sendable {
    var runID: UUID
    var workerPID: Int32
    var cliPID: Int32
    var startedAt: Date
}

struct DurableExecutionHeartbeat: Codable, Sendable {
    var runID: UUID
    var workerPID: Int32
    var updatedAt: Date
}

struct DurableExecutionResultFile: Codable, Sendable {
    var runID: UUID
    var exitCode: Int32
    var endedAt: Date
    var launchError: String?
}

struct DurableProcessResult: Sendable {
    var exitCode: Int32
    var standardOutput: String
    var standardError: String
    var launchError: String?
}

struct DurableLogRead: Equatable, Sendable {
    var lines: [String]
    var lineOffsets: [Int64]
    var nextOffset: Int64
}

enum DurableExecutionStatus: Equatable, Sendable {
    case running
    case completed
    case interrupted
}

enum DurableExecutionError: LocalizedError {
    case unavailableExecutable
    case invalidRunDirectory
    case interrupted

    var errorDescription: String? {
        switch self {
        case .unavailableExecutable: "无法定位 fz-workSpace 后台执行程序"
        case .invalidRunDirectory: "AI 任务执行目录无效"
        case .interrupted: "AI 后台进程已停止，且没有生成完整结果"
        }
    }
}

struct DurableExecutionFiles: Sendable {
    let runDirectory: URL

    var configurationURL: URL { runDirectory.appendingPathComponent("configuration.json") }
    var manifestURL: URL { runDirectory.appendingPathComponent("manifest.json") }
    var heartbeatURL: URL { runDirectory.appendingPathComponent("heartbeat.json") }
    var resultURL: URL { runDirectory.appendingPathComponent("result.json") }
    var standardOutputURL: URL { runDirectory.appendingPathComponent("stdout.log") }
    var standardErrorURL: URL { runDirectory.appendingPathComponent("stderr.log") }

    static func create(runID: UUID, fileManager: FileManager = .default) throws -> DurableExecutionFiles {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let jobs = support
            .appendingPathComponent("DevFlow", isDirectory: true)
            .appendingPathComponent("Jobs", isDirectory: true)
        try fileManager.createDirectory(
            at: jobs,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let directory = jobs.appendingPathComponent(runID.uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return DurableExecutionFiles(runDirectory: directory)
    }

    func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    func prepareLogFile(at url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}

enum DurableExecutionWorker {
    static let argument = "--devflow-worker"

    static func configurationPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    @discardableResult
    static func run(configurationPath: String) -> Int32 {
        let configurationURL = URL(fileURLWithPath: configurationPath)
        let files = DurableExecutionFiles(runDirectory: configurationURL.deletingLastPathComponent())
        guard let configuration = files.readJSON(DurableWorkerConfiguration.self, from: configurationURL),
              files.runDirectory.lastPathComponent == configuration.runID.uuidString else {
            return 2
        }

        let workerPID = getpid()
        let outputHandle: FileHandle
        let errorHandle: FileHandle
        do {
            outputHandle = try files.prepareLogFile(at: files.standardOutputURL)
            errorHandle = try files.prepareLogFile(at: files.standardErrorURL)
        } catch {
            return 3
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executable)
        process.arguments = configuration.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.workingDirectory, isDirectory: true)
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        var environment = ProcessInfo.processInfo.environment
        configuration.environment.forEach { environment[$0.key] = $0.value }
        process.environment = environment

        do {
            try process.run()
            try files.writeJSON(
                DurableExecutionManifest(
                    runID: configuration.runID,
                    workerPID: workerPID,
                    cliPID: process.processIdentifier,
                    startedAt: Date()
                ),
                to: files.manifestURL
            )
            while process.isRunning {
                try? files.writeJSON(
                    DurableExecutionHeartbeat(
                        runID: configuration.runID,
                        workerPID: workerPID,
                        updatedAt: Date()
                    ),
                    to: files.heartbeatURL
                )
                Thread.sleep(forTimeInterval: 2)
            }
            process.waitUntilExit()
            try? outputHandle.close()
            try? errorHandle.close()
            try files.writeJSON(
                DurableExecutionResultFile(
                    runID: configuration.runID,
                    exitCode: process.terminationStatus,
                    endedAt: Date(),
                    launchError: nil
                ),
                to: files.resultURL
            )
            return process.terminationStatus
        } catch {
            try? outputHandle.close()
            try? errorHandle.close()
            try? files.writeJSON(
                DurableExecutionResultFile(
                    runID: configuration.runID,
                    exitCode: -1,
                    endedAt: Date(),
                    launchError: error.localizedDescription
                ),
                to: files.resultURL
            )
            return 1
        }
    }
}

final class DurableProcessRunner: @unchecked Sendable {
    static let heartbeatFreshness: TimeInterval = 8
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func start(
        phase: AIExecutionPhase,
        command: String,
        arguments: [String],
        workingDirectory: String,
        environment: [String: String] = [:]
    ) throws -> AIExecutionRecord {
        guard let executable = ProcessRunner.resolveCommand(command) else {
            throw ProcessRunnerError.commandNotFound(command)
        }
        guard let appExecutable = Bundle.main.executableURL else {
            throw DurableExecutionError.unavailableExecutable
        }

        let runID = UUID()
        let files = try DurableExecutionFiles.create(runID: runID, fileManager: fileManager)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPath = ["\(home)/.local/bin", "\(home)/.cursor/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        var workerEnvironment = environment
        workerEnvironment["PATH"] = (extraPath + [ProcessInfo.processInfo.environment["PATH"] ?? ""]).joined(separator: ":")
        try files.writeJSON(
            DurableWorkerConfiguration(
                runID: runID,
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: workerEnvironment
            ),
            to: files.configurationURL
        )

        let worker = Process()
        worker.executableURL = appExecutable
        worker.arguments = [DurableExecutionWorker.argument, files.configurationURL.path]
        worker.standardOutput = FileHandle.nullDevice
        worker.standardError = FileHandle.nullDevice
        do {
            try worker.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        return AIExecutionRecord(
            runID: runID,
            phase: phase,
            runDirectory: files.runDirectory.path,
            workerPID: worker.processIdentifier,
            startedAt: Date(),
            lastOutputOffset: 0,
            state: .launching
        )
    }

    func monitor(
        execution: AIExecutionRecord,
        onLine: @escaping @Sendable (String, Int64) async -> Void
    ) async throws -> DurableProcessResult {
        let files = try validatedFiles(for: execution)
        var offset = execution.lastOutputOffset
        var interruptedSince: Date?

        while true {
            try Task.checkCancellation()
            let resultFile = validResult(in: files, execution: execution)
            let read = try Self.readLines(
                at: files.standardOutputURL,
                from: offset,
                includePartial: resultFile != nil
            )
            for (line, lineOffset) in zip(read.lines, read.lineOffsets) {
                await onLine(line, lineOffset)
            }
            offset = read.nextOffset

            if let resultFile {
                return DurableProcessResult(
                    exitCode: resultFile.exitCode,
                    standardOutput: (try? String(contentsOf: files.standardOutputURL, encoding: .utf8)) ?? "",
                    standardError: (try? String(contentsOf: files.standardErrorURL, encoding: .utf8)) ?? "",
                    launchError: resultFile.launchError
                )
            }

            if inspect(execution: execution) == .interrupted {
                if let interruptedSince, Date().timeIntervalSince(interruptedSince) >= 2 {
                    throw DurableExecutionError.interrupted
                }
                if interruptedSince == nil { interruptedSince = Date() }
            } else {
                interruptedSince = nil
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func inspect(execution: AIExecutionRecord, now: Date = Date()) -> DurableExecutionStatus {
        guard let files = try? validatedFiles(for: execution) else { return .interrupted }
        if validResult(in: files, execution: execution) != nil { return .completed }
        let heartbeat = files.readJSON(DurableExecutionHeartbeat.self, from: files.heartbeatURL)
        let validHeartbeat = heartbeat.flatMap { value -> Date? in
            guard value.runID == execution.runID, value.workerPID == execution.workerPID else { return nil }
            return value.updatedAt
        }
        return Self.classify(
            resultExists: false,
            workerIsAlive: Self.isProcessAlive(execution.workerPID),
            heartbeatDate: validHeartbeat,
            startedAt: execution.startedAt,
            now: now
        )
    }

    func cancel(execution: AIExecutionRecord) {
        guard let files = try? validatedFiles(for: execution),
              let manifest = files.readJSON(DurableExecutionManifest.self, from: files.manifestURL),
              let heartbeat = files.readJSON(DurableExecutionHeartbeat.self, from: files.heartbeatURL),
              manifest.runID == execution.runID,
              heartbeat.runID == execution.runID,
              manifest.workerPID == execution.workerPID,
              heartbeat.workerPID == execution.workerPID,
              Date().timeIntervalSince(heartbeat.updatedAt) <= Self.heartbeatFreshness else {
            return
        }
        if Self.isProcessAlive(manifest.cliPID) { _ = kill(manifest.cliPID, SIGTERM) }
        if Self.isProcessAlive(manifest.workerPID) { _ = kill(manifest.workerPID, SIGTERM) }
    }

    static func classify(
        resultExists: Bool,
        workerIsAlive: Bool,
        heartbeatDate: Date?,
        startedAt: Date,
        now: Date,
        freshness: TimeInterval = heartbeatFreshness
    ) -> DurableExecutionStatus {
        if resultExists { return .completed }
        guard workerIsAlive else { return .interrupted }
        if let heartbeatDate {
            return now.timeIntervalSince(heartbeatDate) <= freshness ? .running : .interrupted
        }
        return now.timeIntervalSince(startedAt) <= freshness ? .running : .interrupted
    }

    static func readLines(at url: URL, from offset: Int64, includePartial: Bool) throws -> DurableLogRead {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DurableLogRead(lines: [], lineOffsets: [], nextOffset: max(0, offset))
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let startOffset = offset > size ? 0 : max(0, offset)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(startOffset))
        let data = try handle.readToEnd() ?? Data()
        guard !data.isEmpty else { return DurableLogRead(lines: [], lineOffsets: [], nextOffset: startOffset) }

        var lines: [String] = []
        var lineOffsets: [Int64] = []
        var lineStart = data.startIndex
        var consumed = 0
        for index in data.indices where data[index] == 0x0A {
            var lineData = data[lineStart..<index]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            consumed = data.distance(from: data.startIndex, to: data.index(after: index))
            if !lineData.isEmpty {
                lines.append(String(decoding: lineData, as: UTF8.self))
                lineOffsets.append(startOffset + Int64(consumed))
            }
            lineStart = data.index(after: index)
        }
        if includePartial, lineStart < data.endIndex {
            let remainder = data[lineStart..<data.endIndex]
            consumed = data.count
            if !remainder.isEmpty {
                lines.append(String(decoding: remainder, as: UTF8.self))
                lineOffsets.append(startOffset + Int64(consumed))
            }
        }
        return DurableLogRead(lines: lines, lineOffsets: lineOffsets, nextOffset: startOffset + Int64(consumed))
    }

    private func validatedFiles(for execution: AIExecutionRecord) throws -> DurableExecutionFiles {
        let directory = URL(fileURLWithPath: execution.runDirectory, isDirectory: true)
        guard directory.lastPathComponent == execution.runID.uuidString else {
            throw DurableExecutionError.invalidRunDirectory
        }
        return DurableExecutionFiles(runDirectory: directory)
    }

    private func validResult(
        in files: DurableExecutionFiles,
        execution: AIExecutionRecord
    ) -> DurableExecutionResultFile? {
        guard let result = files.readJSON(DurableExecutionResultFile.self, from: files.resultURL),
              result.runID == execution.runID else { return nil }
        return result
    }

    private static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

enum JobHistoryRecovery {
    static func recoverWorkItems(forTicketIDs ticketIDs: Set<Int>) -> [WorkItem] {
        guard !ticketIDs.isEmpty else { return [] }
        let jobsRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevFlow", isDirectory: true)
            .appendingPathComponent("Jobs", isDirectory: true)
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: jobsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var latest: [Int: (date: Date, item: WorkItem)] = [:]
        for directory in directories {
            guard let recovered = recoverWorkItem(from: directory),
                  ticketIDs.contains(recovered.ticketID) else { continue }
            let date = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date >= (latest[recovered.ticketID]?.date ?? .distantPast) {
                latest[recovered.ticketID] = (date, recovered)
            }
        }
        return latest.values.map(\.item)
    }

    private static func recoverWorkItem(from directory: URL) -> WorkItem? {
        let files = DurableExecutionFiles(runDirectory: directory)
        guard let configuration = files.readJSON(DurableWorkerConfiguration.self, from: files.configurationURL) else {
            return nil
        }
        let blob = configuration.arguments.joined(separator: "\n")
        guard let ticketID = ticketID(in: blob) else { return nil }
        let plan = extractedPlan(from: blob)
        let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return WorkItem(
            ticketID: ticketID,
            provider: provider(from: configuration.executable),
            repositoryPath: configuration.workingDirectory,
            branch: "",
            helperContext: "",
            stage: .completed,
            logs: [JobLogEntry(timestamp: modified, message: "已从本地执行记录恢复任务历史")],
            analysisPlan: plan,
            updatedAt: modified
        )
    }

    private static func ticketID(in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"工单编号：#(\d+)"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let idRange = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[idRange])
    }

    private static func extractedPlan(from text: String) -> String? {
        guard let start = text.range(of: "DEVFLOW_PLAN:") else { return nil }
        let rest = text[start.lowerBound...]
        if let end = rest.range(of: "\nDEVFLOW_RISKS:") {
            let plan = rest[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return plan.isEmpty ? nil : String(plan)
        }
        let plan = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return plan.isEmpty ? nil : plan
    }

    private static func provider(from executable: String) -> AIProvider {
        let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        if name.contains("cursor") { return .cursor }
        if name.contains("claude") { return .claude }
        return .codex
    }
}
