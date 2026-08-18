import Foundation

/// Versioned NDJSON contract between DevFlow and its bundled parser helper.
/// The helper receives source text only; it never receives a repository path to read itself.
enum WorkGraphParserProtocol {
    static let version = 1
}

enum WorkGraphParserOperation: String, Codable {
    case extract
}

struct WorkGraphParserRequest: Codable, Equatable {
    var protocolVersion: Int
    var requestID: String
    var operation: WorkGraphParserOperation
    var relativePath: String
    var language: WorkGraphLanguage
    var source: String
}

enum WorkGraphParserResponseKind: String, Codable {
    case extraction
    case error
}

struct WorkGraphParserExtractionPayload: Codable, Equatable {
    var nodes: [WorkGraphNodeDraft]
    var edges: [WorkGraphEdgeDraft]
    var references: [WorkGraphReferenceDraft]
    var documents: [WorkGraphDocumentRecord]
}

struct WorkGraphParserErrorPayload: Codable, Equatable {
    var code: String
    var message: String
}

struct WorkGraphParserResponse: Codable, Equatable {
    var protocolVersion: Int
    var requestID: String
    var kind: WorkGraphParserResponseKind
    var extraction: WorkGraphParserExtractionPayload?
    var diagnostics: [String]
    var error: WorkGraphParserErrorPayload?
}

protocol WorkGraphParserRuntime: WorkGraphLanguageExtractor {
    var protocolVersion: Int { get }
}

enum WorkGraphParserRuntimeError: LocalizedError, Equatable {
    case invalidHelperURL
    case helperNotExecutable(String)
    case unsupportedLanguage(WorkGraphLanguage)
    case invalidRelativePath(String)
    case sourceTooLarge(actual: Int, maximum: Int)
    case launchFailed(String)
    case timedOut(TimeInterval)
    case responseTooLarge(actual: Int, maximum: Int)
    case processFailed(code: Int32, stderr: String)
    case invalidResponse(String)
    case protocolMismatch(expected: Int, actual: Int)
    case requestMismatch
    case helperReported(code: String, message: String, diagnostics: [String])

    var errorDescription: String? {
        switch self {
        case .invalidHelperURL:
            return "WorkGraph 解析器必须是 App 随包提供的本地可执行文件。"
        case let .helperNotExecutable(path):
            return "WorkGraph 解析器不可执行：\(path)"
        case let .unsupportedLanguage(language):
            return "\(language.rawValue) 暂无经过验证的 WorkGraph 语义解析器。"
        case let .invalidRelativePath(path):
            return "WorkGraph 解析器只接受仓库内相对路径：\(path)"
        case let .sourceTooLarge(actual, maximum):
            return "源文件过大（\(actual) 字节，最大 \(maximum) 字节），未交给 WorkGraph 解析器。"
        case let .launchFailed(message):
            return "无法启动 WorkGraph 解析器：\(message)"
        case let .timedOut(seconds):
            return "WorkGraph 解析器在 \(Int(seconds)) 秒内未完成。"
        case let .responseTooLarge(actual, maximum):
            return "WorkGraph 解析器结果过大（\(actual) 字节，最大 \(maximum) 字节）。"
        case let .processFailed(code, stderr):
            return "WorkGraph 解析器执行失败（\(code)）：\(stderr)"
        case let .invalidResponse(message):
            return "WorkGraph 解析器返回无效结果：\(message)"
        case let .protocolMismatch(expected, actual):
            return "WorkGraph 解析器协议不兼容（需要 \(expected)，实际 \(actual)）。"
        case .requestMismatch:
            return "WorkGraph 解析器返回了不属于当前请求的结果。"
        case let .helperReported(code, message, _):
            return "WorkGraph 解析器错误（\(code)）：\(message)"
        }
    }
}

/// Runs one strictly bounded NDJSON request against a bundled parser helper.
/// No command lookup, shell invocation, Node lookup, or CodeGraph fallback is performed here.
final class WorkGraphParserProcessRuntime: WorkGraphParserRuntime {
    static let defaultMaximumSourceBytes = 2 * 1024 * 1024
    static let defaultMaximumResponseBytes = 16 * 1024 * 1024
    static let defaultMaximumBatchBytes = 8 * 1024 * 1024
    static let defaultMaximumBatchResponseBytes = 128 * 1024 * 1024
    static let defaultMaximumDiagnosticBytes = 128 * 1024
    static let defaultTimeout: TimeInterval = 30

    let helperExecutableURL: URL
    let helperArguments: [String]
    let protocolVersion: Int
    let supportedLanguages: Set<WorkGraphLanguage>

    private let timeout: TimeInterval
    private let maximumSourceBytes: Int
    private let maximumResponseBytes: Int
    private let maximumBatchBytes: Int
    private let maximumBatchResponseBytes: Int
    private let maximumDiagnosticBytes: Int
    private let requestIDProvider: () -> String

    init(
        helperExecutableURL: URL,
        helperArguments: [String] = [],
        protocolVersion: Int = WorkGraphParserProtocol.version,
        supportedLanguages: Set<WorkGraphLanguage> = Set(WorkGraphLanguage.allCases.filter(\.supportsSemanticExtraction)),
        timeout: TimeInterval = WorkGraphParserProcessRuntime.defaultTimeout,
        maximumSourceBytes: Int = WorkGraphParserProcessRuntime.defaultMaximumSourceBytes,
        maximumResponseBytes: Int = WorkGraphParserProcessRuntime.defaultMaximumResponseBytes,
        maximumBatchBytes: Int = WorkGraphParserProcessRuntime.defaultMaximumBatchBytes,
        maximumBatchResponseBytes: Int = WorkGraphParserProcessRuntime.defaultMaximumBatchResponseBytes,
        maximumDiagnosticBytes: Int = WorkGraphParserProcessRuntime.defaultMaximumDiagnosticBytes,
        requestIDProvider: @escaping () -> String = { UUID().uuidString }
    ) {
        self.helperExecutableURL = helperExecutableURL
        self.helperArguments = helperArguments
        self.protocolVersion = protocolVersion
        self.supportedLanguages = supportedLanguages.subtracting([.unknown])
        self.timeout = max(timeout, 1)
        self.maximumSourceBytes = max(maximumSourceBytes, 1)
        self.maximumResponseBytes = max(maximumResponseBytes, 1)
        self.maximumBatchBytes = max(maximumBatchBytes, maximumSourceBytes)
        self.maximumBatchResponseBytes = max(maximumBatchResponseBytes, maximumResponseBytes)
        self.maximumDiagnosticBytes = max(maximumDiagnosticBytes, 1)
        self.requestIDProvider = requestIDProvider
    }

    func extract(file: WorkGraphSourceFile) throws -> WorkGraphExtraction {
        guard isStrictRelativePath(file.record.path) else {
            throw WorkGraphParserRuntimeError.invalidRelativePath(file.record.path)
        }
        guard file.record.language != .unknown else {
            return unsupportedExtraction(for: file)
        }
        guard supportedLanguages.contains(file.record.language) else {
            throw WorkGraphParserRuntimeError.unsupportedLanguage(file.record.language)
        }

        let sourceByteCount = file.source.lengthOfBytes(using: .utf8)
        guard sourceByteCount <= maximumSourceBytes else {
            throw WorkGraphParserRuntimeError.sourceTooLarge(actual: sourceByteCount, maximum: maximumSourceBytes)
        }
        guard helperExecutableURL.isFileURL else {
            throw WorkGraphParserRuntimeError.invalidHelperURL
        }
        let executablePath = helperExecutableURL.standardizedFileURL.path
        guard executablePath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw WorkGraphParserRuntimeError.helperNotExecutable(executablePath)
        }

        let request = WorkGraphParserRequest(
            protocolVersion: protocolVersion,
            requestID: requestIDProvider(),
            operation: .extract,
            relativePath: file.record.path,
            language: file.record.language,
            source: file.source
        )
        let requestData = try encodeNDJSON([request])
        let output = try runHelper(requestData: requestData, maximumOutputBytes: maximumResponseBytes)
        if output.stdoutExceededLimit {
            throw WorkGraphParserRuntimeError.responseTooLarge(
                actual: output.stdoutByteCount,
                maximum: maximumResponseBytes
            )
        }

        let stderrDiagnostics = boundedDiagnostics(from: output.stderr)
        let response: WorkGraphParserResponse
        do {
            response = try decodeSingleResponse(from: output.stdout)
        } catch {
            if output.exitCode != 0 {
                throw WorkGraphParserRuntimeError.processFailed(code: output.exitCode, stderr: output.stderr)
            }
            throw error
        }
        guard response.protocolVersion == protocolVersion else {
            throw WorkGraphParserRuntimeError.protocolMismatch(expected: protocolVersion, actual: response.protocolVersion)
        }
        guard response.requestID == request.requestID else {
            throw WorkGraphParserRuntimeError.requestMismatch
        }

        switch response.kind {
        case .error:
            guard let error = response.error else {
                throw WorkGraphParserRuntimeError.invalidResponse("error 响应缺少错误对象")
            }
            guard response.extraction == nil else {
                throw WorkGraphParserRuntimeError.invalidResponse("error 响应不能同时包含 extraction")
            }
            throw WorkGraphParserRuntimeError.helperReported(
                code: error.code,
                message: error.message,
                diagnostics: boundedDiagnosticMessages(response.diagnostics + stderrDiagnostics)
            )

        case .extraction:
            guard response.error == nil, let payload = response.extraction else {
                throw WorkGraphParserRuntimeError.invalidResponse("extraction 响应缺少结果或同时包含错误")
            }
            guard output.exitCode == 0 else {
                throw WorkGraphParserRuntimeError.processFailed(code: output.exitCode, stderr: output.stderr)
            }
            let validation = try validate(payload: payload, for: file)

            var record = file.record
            record.diagnostics = boundedDiagnosticMessages(
                record.diagnostics + response.diagnostics + stderrDiagnostics + validation.diagnostics
            )
            return WorkGraphExtraction(
                file: record,
                nodes: validation.payload.nodes,
                edges: validation.payload.edges,
                references: validation.payload.references,
                documents: validation.payload.documents
            )
        }
    }

    /// Extracts a repository batch in language groups. A helper process receives
    /// several files of one language, which avoids both per-file startup cost and
    /// keeping every grammar resident in one JavaScript runtime.
    func extract(
        files: [WorkGraphSourceFile],
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> [WorkGraphExtraction] {
        guard !files.isEmpty else { return [] }

        struct Pending {
            var index: Int
            var file: WorkGraphSourceFile
            var request: WorkGraphParserRequest
        }

        var completed = Array<WorkGraphExtraction?>(repeating: nil, count: files.count)
        var pending: [Pending] = []
        var requestIDs = Set<String>()
        progress?(0, files.count)

        for (index, file) in files.enumerated() {
            guard isStrictRelativePath(file.record.path) else {
                throw WorkGraphParserRuntimeError.invalidRelativePath(file.record.path)
            }
            guard file.record.language != .unknown else {
                completed[index] = unsupportedExtraction(for: file)
                continue
            }
            guard supportedLanguages.contains(file.record.language) else {
                throw WorkGraphParserRuntimeError.unsupportedLanguage(file.record.language)
            }

            let byteCount = file.source.lengthOfBytes(using: .utf8)
            guard byteCount <= maximumSourceBytes else {
                throw WorkGraphParserRuntimeError.sourceTooLarge(actual: byteCount, maximum: maximumSourceBytes)
            }

            let requestID = requestIDProvider()
            guard requestIDs.insert(requestID).inserted else {
                throw WorkGraphParserRuntimeError.invalidResponse("解析器请求标识重复")
            }
            pending.append(
                Pending(
                    index: index,
                    file: file,
                    request: WorkGraphParserRequest(
                        protocolVersion: protocolVersion,
                        requestID: requestID,
                        operation: .extract,
                        relativePath: file.record.path,
                        language: file.record.language,
                        source: file.source
                    )
                )
            )
        }

        guard helperExecutableURL.isFileURL else {
            throw WorkGraphParserRuntimeError.invalidHelperURL
        }
        let executablePath = helperExecutableURL.standardizedFileURL.path
        guard executablePath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw WorkGraphParserRuntimeError.helperNotExecutable(executablePath)
        }

        for language in WorkGraphLanguage.allCases {
            let languagePending = pending
                .filter { $0.request.language == language }
                .sorted { $0.file.record.path < $1.file.record.path }
            var batches: [[Pending]] = []
            var currentBatch: [Pending] = []
            var currentBatchBytes = 0
            for item in languagePending {
                let itemBytes = item.request.source.lengthOfBytes(using: .utf8)
                if !currentBatch.isEmpty, currentBatchBytes + itemBytes > maximumBatchBytes {
                    batches.append(currentBatch)
                    currentBatch = []
                    currentBatchBytes = 0
                }
                currentBatch.append(item)
                currentBatchBytes += itemBytes
            }
            if !currentBatch.isEmpty { batches.append(currentBatch) }

            for batch in batches {
                let requestData = try encodeNDJSON(batch.map(\.request))
                let output = try runHelper(requestData: requestData, maximumOutputBytes: maximumBatchResponseBytes)
                if output.stdoutExceededLimit {
                    throw WorkGraphParserRuntimeError.responseTooLarge(
                        actual: output.stdoutByteCount,
                        maximum: maximumBatchResponseBytes
                    )
                }
                guard output.exitCode == 0 else {
                    throw WorkGraphParserRuntimeError.processFailed(code: output.exitCode, stderr: output.stderr)
                }

                let responses = try decodeResponses(from: output.stdout)
                let byRequestID = Dictionary(grouping: responses, by: \.requestID)
                let stderrDiagnostics = boundedDiagnostics(from: output.stderr)
                for item in batch {
                    guard let candidates = byRequestID[item.request.requestID], candidates.count == 1,
                          let response = candidates.first else {
                        throw WorkGraphParserRuntimeError.requestMismatch
                    }
                    completed[item.index] = try extraction(
                        from: response,
                        request: item.request,
                        file: item.file,
                        stderrDiagnostics: stderrDiagnostics
                    )
                }
                guard responses.count == batch.count else {
                    throw WorkGraphParserRuntimeError.invalidResponse("批量解析器响应数量不匹配")
                }
                progress?(completed.compactMap { $0 }.count, files.count)
            }
        }

        guard completed.allSatisfy({ $0 != nil }) else {
            throw WorkGraphParserRuntimeError.invalidResponse("批量解析器缺少结果")
        }
        return completed.compactMap { $0 }
    }

    private func extraction(
        from response: WorkGraphParserResponse,
        request: WorkGraphParserRequest,
        file: WorkGraphSourceFile,
        stderrDiagnostics: [String]
    ) throws -> WorkGraphExtraction {
        guard response.protocolVersion == protocolVersion else {
            throw WorkGraphParserRuntimeError.protocolMismatch(expected: protocolVersion, actual: response.protocolVersion)
        }
        guard response.requestID == request.requestID else {
            throw WorkGraphParserRuntimeError.requestMismatch
        }

        switch response.kind {
        case .error:
            guard let error = response.error, response.extraction == nil else {
                throw WorkGraphParserRuntimeError.invalidResponse("error 响应缺少错误对象或同时包含 extraction")
            }
            throw WorkGraphParserRuntimeError.helperReported(
                code: error.code,
                message: error.message,
                diagnostics: boundedDiagnosticMessages(response.diagnostics + stderrDiagnostics)
            )
        case .extraction:
            guard response.error == nil, let payload = response.extraction else {
                throw WorkGraphParserRuntimeError.invalidResponse("extraction 响应缺少结果或同时包含错误")
            }
            let validation = try validate(payload: payload, for: file)
            var record = file.record
            record.diagnostics = boundedDiagnosticMessages(
                record.diagnostics + response.diagnostics + stderrDiagnostics + validation.diagnostics
            )
            return WorkGraphExtraction(
                file: record,
                nodes: validation.payload.nodes,
                edges: validation.payload.edges,
                references: validation.payload.references,
                documents: validation.payload.documents
            )
        }
    }

    private func decodeResponses(from data: Data) throws -> [WorkGraphParserResponse] {
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else {
            throw WorkGraphParserRuntimeError.invalidResponse("响应为空")
        }
        do {
            return try lines.map { line in
                try JSONDecoder().decode(WorkGraphParserResponse.self, from: Data(line.utf8))
            }
        } catch {
            throw WorkGraphParserRuntimeError.invalidResponse(error.localizedDescription)
        }
    }

    private func unsupportedExtraction(for file: WorkGraphSourceFile) -> WorkGraphExtraction {
        var record = file.record
        let language = record.language == .arkTS ? "ArkTS" : "未知语言"
        record.diagnostics = boundedDiagnosticMessages(
            record.diagnostics + ["\(language) 暂无经过验证的 WorkGraph 语义解析器；未写入推测性的 AST 或调用关系。"]
        )
        return WorkGraphExtraction(file: record, nodes: [], edges: [], references: [], documents: [])
    }

    private func encodeNDJSON(_ requests: [WorkGraphParserRequest]) throws -> Data {
        let encoder = JSONEncoder()
        var result = Data()
        for request in requests {
            let data = try encoder.encode(request)
            guard var line = String(data: data, encoding: .utf8) else {
                throw WorkGraphParserRuntimeError.invalidResponse("无法编码请求")
            }
            line.append("\n")
            result.append(contentsOf: line.utf8)
        }
        return result
    }

    private func runHelper(requestData: Data, maximumOutputBytes: Int) throws -> WorkGraphParserProcessOutput {
        let process = Process()
        let input = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutCollector = WorkGraphParserDataCollector(limit: maximumOutputBytes)
        let stderrCollector = WorkGraphParserDataCollector(limit: maximumDiagnosticBytes)
        let readers = DispatchGroup()
        let termination = DispatchSemaphore(value: 0)

        process.executableURL = helperExecutableURL.standardizedFileURL
        process.arguments = helperArguments
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = [:]
        process.terminationHandler = { _ in termination.signal() }

        do {
            try process.run()
        } catch {
            throw WorkGraphParserRuntimeError.launchFailed(error.localizedDescription)
        }

        read(pipe: stdout, into: stdoutCollector, group: readers, process: process)
        read(pipe: stderr, into: stderrCollector, group: readers, process: process)
        input.fileHandleForWriting.write(requestData)
        try? input.fileHandleForWriting.close()

        if termination.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            _ = termination.wait(timeout: .now() + 1)
            readers.wait()
            throw WorkGraphParserRuntimeError.timedOut(timeout)
        }
        readers.wait()

        return WorkGraphParserProcessOutput(
            exitCode: process.terminationStatus,
            stdout: stdoutCollector.data,
            stderr: String(decoding: stderrCollector.data, as: UTF8.self),
            stdoutExceededLimit: stdoutCollector.exceededLimit,
            stdoutByteCount: stdoutCollector.byteCount
        )
    }

    private func read(
        pipe: Pipe,
        into collector: WorkGraphParserDataCollector,
        group: DispatchGroup,
        process: Process
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                guard !chunk.isEmpty else { return }
                if collector.append(chunk), process.isRunning {
                    process.terminate()
                }
            }
        }
    }

    private func decodeSingleResponse(from data: Data) throws -> WorkGraphParserResponse {
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard lines.count == 1 else {
            throw WorkGraphParserRuntimeError.invalidResponse("期望一条 NDJSON 响应，实际收到 \(lines.count) 条")
        }
        guard let line = lines.first else {
            throw WorkGraphParserRuntimeError.invalidResponse("响应为空")
        }
        do {
            return try JSONDecoder().decode(WorkGraphParserResponse.self, from: Data(line.utf8))
        } catch {
            throw WorkGraphParserRuntimeError.invalidResponse(error.localizedDescription)
        }
    }

    private func validate(
        payload: WorkGraphParserExtractionPayload,
        for file: WorkGraphSourceFile
    ) throws -> (payload: WorkGraphParserExtractionPayload, diagnostics: [String]) {
        guard payload.nodes.count <= 50_000,
              payload.edges.count <= 100_000,
              payload.references.count <= 100_000,
              payload.documents.count <= 10_000 else {
            throw WorkGraphParserRuntimeError.invalidResponse("解析结果超过单文件图谱上限")
        }

        let lineCount = max(file.source.split(separator: "\n", omittingEmptySubsequences: false).count, 1)
        var nodeIDs = Set<String>()
        for node in payload.nodes {
            guard node.filePath == file.record.path,
                  node.language == file.record.language,
                  nodeIDs.insert(node.id).inserted,
                  validIdentifier(node.id),
                  validText(node.name),
                  validText(node.qualifiedName),
                  validLocation(node.location, lineCount: lineCount),
                  node.signature.map(validText) ?? true,
                  node.visibility.map(validText) ?? true,
                  node.returnType.map(validText) ?? true,
                  node.decorators.allSatisfy(validText),
                  node.parentID.map(validIdentifier) ?? true else {
                throw WorkGraphParserRuntimeError.invalidResponse("节点包含无效标识、路径、语言或位置")
            }
        }
        guard payload.nodes.allSatisfy({ node in
            node.parentID.map(nodeIDs.contains) ?? true
        }) else {
            throw WorkGraphParserRuntimeError.invalidResponse("节点引用了当前结果中不存在的父节点")
        }

        for edge in payload.edges {
            guard nodeIDs.contains(edge.sourceID),
                  nodeIDs.contains(edge.targetID),
                  edge.confidence.isFinite,
                  (0 ... 1).contains(edge.confidence),
                  edge.location.map({ validLocation($0, lineCount: lineCount) }) ?? true,
                  edge.metadataJSON.map(validJSON) ?? true else {
                throw WorkGraphParserRuntimeError.invalidResponse("边引用了未知节点或包含无效元数据")
            }
        }

        var validReferences: [WorkGraphReferenceDraft] = []
        var invalidReferenceCount = 0
        validReferences.reserveCapacity(payload.references.count)
        for reference in payload.references {
            guard nodeIDs.contains(reference.fromNodeID),
                  reference.filePath == file.record.path,
                  reference.language == file.record.language,
                  validText(reference.rawName),
                  validIdentifier(reference.fingerprint),
                  validLocation(reference.location, lineCount: lineCount),
                  reference.candidateNames.allSatisfy(validText) else {
                invalidReferenceCount += 1
                continue
            }
            validReferences.append(reference)
        }

        for document in payload.documents {
            guard document.path == file.record.path,
                  document.terms.count <= 10_000,
                  document.terms.allSatisfy(validText) else {
                throw WorkGraphParserRuntimeError.invalidResponse("文档索引不属于当前文件或包含无效词条")
            }
        }

        var diagnostics: [String] = []
        if invalidReferenceCount > 0 {
            diagnostics.append("解析器返回 \(invalidReferenceCount) 条无效引用，已忽略；节点、边和文档仍按严格校验处理。")
        }
        return (
            payload: WorkGraphParserExtractionPayload(
                nodes: payload.nodes,
                edges: payload.edges,
                references: validReferences,
                documents: payload.documents
            ),
            diagnostics: diagnostics
        )
    }

    private func validLocation(_ location: WorkGraphSourceLocation, lineCount: Int) -> Bool {
        location.startLine >= 1 &&
            location.endLine >= location.startLine &&
            location.endLine <= lineCount &&
            location.startColumn >= 0 &&
            location.endColumn >= location.startColumn
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.lengthOfBytes(using: .utf8) <= 4_096 && !value.contains("\0")
    }

    private func validText(_ value: String) -> Bool {
        value.lengthOfBytes(using: .utf8) <= 16_384 && !value.contains("\0")
    }

    private func validJSON(_ value: String) -> Bool {
        guard validText(value), let data = value.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private func isStrictRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"), !path.contains("\0") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private func boundedDiagnostics(from stderr: String) -> [String] {
        boundedDiagnosticMessages(stderr.split(whereSeparator: \.isNewline).map(String.init))
    }

    private func boundedDiagnosticMessages(_ diagnostics: [String]) -> [String] {
        var remaining = maximumDiagnosticBytes
        var accepted: [String] = []
        var seen = Set<String>()
        for diagnostic in diagnostics {
            let trimmed = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            let bytes = trimmed.lengthOfBytes(using: .utf8)
            guard bytes <= remaining else { break }
            accepted.append(trimmed)
            remaining -= bytes
        }
        return accepted
    }
}

/// Useful for extractor tests and callers that inject a validated in-process parser.
struct WorkGraphInMemoryParserRuntime: WorkGraphParserRuntime {
    let protocolVersion: Int
    let supportedLanguages: Set<WorkGraphLanguage>
    private let handler: (WorkGraphSourceFile) throws -> WorkGraphExtraction

    init(
        protocolVersion: Int = WorkGraphParserProtocol.version,
        supportedLanguages: Set<WorkGraphLanguage>,
        handler: @escaping (WorkGraphSourceFile) throws -> WorkGraphExtraction
    ) {
        self.protocolVersion = protocolVersion
        self.supportedLanguages = supportedLanguages.subtracting([.unknown])
        self.handler = handler
    }

    func extract(file: WorkGraphSourceFile) throws -> WorkGraphExtraction {
        guard file.record.language != .unknown else {
            var record = file.record
            record.diagnostics += ["未知语言暂无经过验证的 WorkGraph 语义解析器；未写入推测性的 AST 或调用关系。"]
            return WorkGraphExtraction(file: record, nodes: [], edges: [], references: [], documents: [])
        }
        guard supportedLanguages.contains(file.record.language) else {
            throw WorkGraphParserRuntimeError.unsupportedLanguage(file.record.language)
        }
        return try handler(file)
    }
}

private struct WorkGraphParserProcessOutput {
    var exitCode: Int32
    var stdout: Data
    var stderr: String
    var stdoutExceededLimit: Bool
    var stdoutByteCount: Int
}

private final class WorkGraphParserDataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private(set) var data = Data()
    private(set) var exceededLimit = false
    private(set) var byteCount = 0

    init(limit: Int) {
        self.limit = limit
    }

    /// Returns true only when this append first crosses the configured limit.
    func append(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        byteCount += chunk.count
        guard !exceededLimit else { return false }
        let remaining = limit - data.count
        if chunk.count > remaining {
            if remaining > 0 { data.append(chunk.prefix(remaining)) }
            exceededLimit = true
            return true
        }
        data.append(chunk)
        return false
    }
}
