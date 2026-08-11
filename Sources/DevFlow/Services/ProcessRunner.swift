import Foundation

struct ProcessResult: Sendable {
    var exitCode: Int32
    var standardOutput: String
    var standardError: String
}

enum ProcessRunnerError: LocalizedError {
    case commandNotFound(String)
    case launchFailed(String)
    case failed(command: String, code: Int32, message: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .commandNotFound(command): "未检测到命令：\(command)"
        case let .launchFailed(message): "无法启动进程：\(message)"
        case let .failed(command, code, message): "\(command) 执行失败（\(code)）：\(message)"
        case .cancelled: "任务已取消"
        }
    }
}

final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]

    static func commandExists(_ command: String) async -> Bool {
        resolveCommand(command) != nil
    }

    static func resolveCommand(_ command: String) -> String? {
        if command.contains("/"), FileManager.default.isExecutableFile(atPath: command) {
            return command
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchPaths = [
            "\(home)/.local/bin/\(command)",
            "\(home)/.cursor/bin/\(command)",
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/usr/bin/\(command)",
            "/bin/\(command)"
        ]
        return searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func run(
        id: UUID = UUID(),
        command: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        guard let executable = Self.resolveCommand(command) else {
            throw ProcessRunnerError.commandNotFound(command)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                let bufferLock = NSLock()
                var stdout = Data()
                var stderr = Data()
                var stdoutRemainder = ""
                var stderrRemainder = ""

                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                if let workingDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
                }
                var mergedEnvironment = ProcessInfo.processInfo.environment
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let extraPath = ["\(home)/.local/bin", "\(home)/.cursor/bin", "/opt/homebrew/bin", "/usr/local/bin"]
                mergedEnvironment["PATH"] = (extraPath + [mergedEnvironment["PATH"] ?? ""]).joined(separator: ":")
                environment.forEach { mergedEnvironment[$0.key] = $0.value }
                process.environment = mergedEnvironment

                func consume(_ data: Data, remainder: inout String) {
                    guard !data.isEmpty else { return }
                    let chunk = String(decoding: data, as: UTF8.self)
                    remainder += chunk
                    let pieces = remainder.components(separatedBy: .newlines)
                    remainder = pieces.last ?? ""
                    for line in pieces.dropLast() where !line.isEmpty {
                        onLine?(line)
                    }
                }

                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    bufferLock.lock()
                    stdout.append(data)
                    consume(data, remainder: &stdoutRemainder)
                    bufferLock.unlock()
                }
                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    bufferLock.lock()
                    stderr.append(data)
                    consume(data, remainder: &stderrRemainder)
                    bufferLock.unlock()
                }

                process.terminationHandler = { [weak self] terminated in
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    let remainingOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let remainingError = errorPipe.fileHandleForReading.readDataToEndOfFile()

                    bufferLock.lock()
                    stdout.append(remainingOutput)
                    stderr.append(remainingError)
                    consume(remainingOutput, remainder: &stdoutRemainder)
                    consume(remainingError, remainder: &stderrRemainder)
                    if !stdoutRemainder.isEmpty { onLine?(stdoutRemainder) }
                    if !stderrRemainder.isEmpty { onLine?(stderrRemainder) }
                    let outputText = String(decoding: stdout, as: UTF8.self)
                    let errorText = String(decoding: stderr, as: UTF8.self)
                    bufferLock.unlock()

                    self?.lock.lock()
                    self?.processes[id] = nil
                    self?.lock.unlock()

                    continuation.resume(returning: ProcessResult(exitCode: terminated.terminationStatus, standardOutput: outputText, standardError: errorText))
                }

                do {
                    lock.lock()
                    processes[id] = process
                    lock.unlock()
                    try process.run()
                } catch {
                    lock.lock()
                    processes[id] = nil
                    lock.unlock()
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            cancel(id: id)
        }
    }

    func cancel(id: UUID) {
        lock.lock()
        let process = processes[id]
        lock.unlock()
        if process?.isRunning == true {
            process?.interrupt()
        }
    }
}
