import Foundation

/// Hard bounds for repository graph requests. They keep one query from
/// expanding an entire repository into a caller's result or prompt.
struct WorkGraphQueryLimits: Equatable {
    static let maximumDepth = 8
    static let maximumResults = 64

    var maxDepth: Int
    var maxResults: Int

    init(maxDepth: Int = 3, maxResults: Int = 20) {
        self.maxDepth = min(max(1, maxDepth), Self.maximumDepth)
        self.maxResults = min(max(1, maxResults), Self.maximumResults)
    }
}

/// Repository-relative path conventions shared by index generation and graph
/// consumers. They deliberately recognize only common test roots and explicit
/// test-file suffixes; no source path is inferred from a fuzzy match.
enum WorkGraphRepositoryPath {
    private static let testDirectoryNames: Set<String> = ["__tests__", "test", "tests"]
    private static let explicitTestFileSuffixes = [
        "_test.dart", "_test.swift", "_test.kt", "_test.java", "_test.ets"
    ]

    static func normalizedRelativePath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.contains("\\") else {
            return nil
        }

        var components: [String] = []
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                return nil
            default:
                components.append(String(component))
            }
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }

    static func isTestSourcePath(_ rawPath: String) -> Bool {
        guard let path = normalizedRelativePath(rawPath) else { return false }
        let components = path.split(separator: "/").map { $0.lowercased() }
        guard let fileName = components.last else { return false }
        if components.dropLast().contains(where: { testDirectoryNames.contains($0) }) {
            return true
        }
        let fileNameString = String(fileName)
        return explicitTestFileSuffixes.contains(where: { fileNameString.hasSuffix($0) })
            || fileNameString.contains(".test.")
            || fileNameString.contains(".spec.")
    }

    static func testRoot(for rawPath: String) -> String? {
        guard let path = normalizedRelativePath(rawPath) else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return nil }
        for index in components.indices.dropLast() where testDirectoryNames.contains(components[index].lowercased()) {
            return components[0...index].joined(separator: "/")
        }
        return nil
    }
}

/// A candidate-definition lookup. It deliberately returns candidates instead
/// of selecting one by a fuzzy name match.
struct WorkGraphDefinitionRequest: Equatable {
    static let maximumResults = 32

    var query: String
    var limit: Int

    init(query: String, limit: Int = 12) {
        self.query = query
        self.limit = min(max(1, limit), Self.maximumResults)
    }
}

/// Bounded source inspection for one exact graph node or one indexed file.
/// Source is returned only when the indexed file still matches the filesystem.
struct WorkGraphNodeInspectionRequest: Equatable {
    enum Target: Equatable {
        case path(String)
        case symbol(WorkGraphSymbolSelector)
    }

    static let maximumLines = 400
    static let maximumCharacters = 16_000

    var target: Target
    var startLine: Int?
    var maximumLines: Int
    var maximumCharacters: Int

    init(
        target: Target,
        startLine: Int? = nil,
        maximumLines: Int = 160,
        maximumCharacters: Int = 8_000
    ) {
        self.target = target
        self.startLine = startLine.map { max(1, $0) }
        self.maximumLines = min(max(1, maximumLines), Self.maximumLines)
        self.maximumCharacters = min(max(512, maximumCharacters), Self.maximumCharacters)
    }
}

/// A compact, source-bearing answer for a natural-language or symbol-oriented
/// question. It is intentionally smaller than a repository dump.
struct WorkGraphExploreRequest: Equatable {
    static let maximumFiles = 6
    static let maximumLinesPerFile = 220
    static let maximumCharacters = 16_000

    var query: String
    var maximumFiles: Int
    var maximumLinesPerFile: Int
    var maximumCharacters: Int

    init(
        query: String,
        maximumFiles: Int = 4,
        maximumLinesPerFile: Int = 120,
        maximumCharacters: Int = 12_000
    ) {
        self.query = query
        self.maximumFiles = min(max(1, maximumFiles), Self.maximumFiles)
        self.maximumLinesPerFile = min(max(1, maximumLinesPerFile), Self.maximumLinesPerFile)
        self.maximumCharacters = min(max(1_024, maximumCharacters), Self.maximumCharacters)
    }
}

struct WorkGraphFileListRequest: Equatable {
    static let maximumResults = 128

    var pathPrefix: String?
    var maximumResults: Int

    init(pathPrefix: String? = nil, maximumResults: Int = 48) {
        self.pathPrefix = pathPrefix
        self.maximumResults = min(max(1, maximumResults), Self.maximumResults)
    }
}

enum WorkGraphInspectionState: String, Codable, Equatable {
    case current
    case updateRecommended = "update_recommended"
    case notGenerated = "not_generated"
}

struct WorkGraphStatusInspectionResult: Codable, Equatable {
    var state: WorkGraphInspectionState
    var isQueryable: Bool
    var generatedAt: Date?
    var sourceFileCount: Int?
    var indexedSymbolCount: Int?
    var indexedEdgeCount: Int?
    var stalePaths: [String]
}

struct WorkGraphFileInspectionResult: Codable, Equatable {
    var file: WorkGraphFileRecord
    var isCurrent: Bool
}

struct WorkGraphNodeInspectionResult: Codable, Equatable {
    var node: WorkGraphNode?
    var file: WorkGraphFileRecord
    var isCurrent: Bool
    var sourceStartLine: Int?
    var source: String?
}

struct WorkGraphExploreFileResult: Codable, Equatable {
    var node: WorkGraphNode?
    var file: WorkGraphFileRecord
    var isCurrent: Bool
    var sourceStartLine: Int?
    var source: String?
}

struct WorkGraphExploreResult: Codable, Equatable {
    var files: [WorkGraphExploreFileResult]
}

enum WorkGraphInspectionError: LocalizedError, Equatable {
    case emptyExploreQuery
    case invalidRepositoryRelativePath
    case indexedFileNotFound
    case sourceReadFailed

    var errorDescription: String? {
        switch self {
        case .emptyExploreQuery:
            return "探索查询不能为空。"
        case .invalidRepositoryRelativePath:
            return "源码路径必须是仓库内的相对路径。"
        case .indexedFileNotFound:
            return "指定文件不在当前 WorkGraph 索引中。"
        case .sourceReadFailed:
            return "无法读取当前源码文件。"
        }
    }
}

/// Structural traversal can begin only from an exact persisted ID or a unique
/// qualified name. Bare names are intentionally not supported.
enum WorkGraphSymbolSelector: Equatable {
    case id(String)
    case qualifiedName(String)
}

/// Shared controls for callers, callees, trace, and impact requests.
struct WorkGraphRelationshipOptions: Equatable {
    var limits: WorkGraphQueryLimits
    var edgeKinds: Set<WorkGraphEdgeKind>
    var minimumConfidence: Double

    init(
        limits: WorkGraphQueryLimits = .init(),
        edgeKinds: Set<WorkGraphEdgeKind> = [.calls, .bridgeInvokes],
        minimumConfidence: Double = 0.85
    ) {
        self.limits = limits
        self.edgeKinds = edgeKinds.isEmpty ? [.calls, .bridgeInvokes] : edgeKinds
        let requestedConfidence = minimumConfidence.isFinite ? minimumConfidence : 0.85
        self.minimumConfidence = min(max(0, requestedConfidence), 1)
    }
}

struct WorkGraphTraversalRequest: Equatable {
    var symbol: WorkGraphSymbolSelector
    var options: WorkGraphRelationshipOptions

    init(
        symbol: WorkGraphSymbolSelector,
        options: WorkGraphRelationshipOptions = .init()
    ) {
        self.symbol = symbol
        self.options = options
    }
}

struct WorkGraphTraceRequest: Equatable {
    var source: WorkGraphSymbolSelector
    var target: WorkGraphSymbolSelector
    var options: WorkGraphRelationshipOptions

    init(
        source: WorkGraphSymbolSelector,
        target: WorkGraphSymbolSelector,
        options: WorkGraphRelationshipOptions = .init()
    ) {
        self.source = source
        self.target = target
        self.options = options
    }
}

/// Finds repository test sources that have a verified reverse dependency on an
/// exact repository-relative source file. The source path is intentionally the
/// selector: callers never need to guess a symbol name or overload.
struct WorkGraphAffectedTestsRequest: Equatable {
    var sourcePath: String
    var limits: WorkGraphQueryLimits

    init(
        sourcePath: String,
        limits: WorkGraphQueryLimits = .init()
    ) {
        self.sourcePath = sourcePath
        self.limits = limits
    }
}

/// Stable, repository-scoped request surface for structural WorkGraph reads.
enum WorkGraphQueryRequest: Equatable {
    case definitions(WorkGraphDefinitionRequest)
    case callers(WorkGraphTraversalRequest)
    case callees(WorkGraphTraversalRequest)
    case trace(WorkGraphTraceRequest)
    case impact(WorkGraphTraversalRequest)
    case affectedTests(WorkGraphAffectedTestsRequest)
}

struct WorkGraphDefinitionResult: Equatable {
    var matches: [WorkGraphSymbolMatch]
}

struct WorkGraphTraversalResult: Equatable {
    var root: WorkGraphNode
    var traversal: WorkGraphTraversal
}

struct WorkGraphTraceResult: Equatable {
    var source: WorkGraphNode
    var target: WorkGraphNode
    var path: WorkGraphPath?
}

struct WorkGraphAffectedTestsResult: Equatable {
    var sourcePath: String
    var testPaths: [String]
}

enum WorkGraphQueryResult: Equatable {
    case definitions(WorkGraphDefinitionResult)
    case callers(WorkGraphTraversalResult)
    case callees(WorkGraphTraversalResult)
    case trace(WorkGraphTraceResult)
    case impact(WorkGraphTraversalResult)
    case affectedTests(WorkGraphAffectedTestsResult)
}

enum WorkGraphQueryError: LocalizedError, Equatable {
    case navigationNotGenerated
    case navigationNotCurrent
    case indexUnavailable
    case incompatibleIndex
    case emptyDefinitionQuery
    case invalidRepositoryRelativePath
    case emptySymbolSelector
    case symbolNotFound
    case ambiguousSymbol([WorkGraphNode])
    case queryFailed

    var errorDescription: String? {
        switch self {
        case .navigationNotGenerated:
            return "当前仓库尚未生成 WorkGraph 导航。"
        case .navigationNotCurrent:
            return "当前仓库的 WorkGraph 导航需要重新生成后才能查询。"
        case .indexUnavailable:
            return "当前仓库缺少可查询的 WorkGraph 数据库。"
        case .incompatibleIndex:
            return "当前仓库的 WorkGraph 数据库版本无效或不兼容。"
        case .emptyDefinitionQuery:
            return "符号查询不能为空。"
        case .invalidRepositoryRelativePath:
            return "源码路径必须是仓库内的相对路径。"
        case .emptySymbolSelector:
            return "符号选择不能为空。"
        case .symbolNotFound:
            return "未找到指定的精确符号。"
        case .ambiguousSymbol:
            return "指定的 qualified name 对应多个符号，请改用精确 node ID。"
        case .queryFailed:
            return "WorkGraph 查询失败。"
        }
    }
}

/// Facade over the generated SQLite graph for one or more project repositories.
/// Querying may refresh the disposable `.workgraph` cache when source metadata
/// has changed; it never modifies repository source files or user content.
final class WorkGraphQueryService {
    private static let maximumExactSelectorCandidates = 9
    private static let affectedTestsEdgeKinds: Set<WorkGraphEdgeKind> = [.calls, .imports, .bridgeInvokes]
    private static let affectedTestsMinimumConfidence = 0.85
    private static let affectedTestsTraversalMultiplier = 8
    private static let maximumAffectedTestsTraversalNodes = 512

    private let navigationService: ProjectNavigationService
    private let fileManager: FileManager
    private let syncCoordinator: WorkGraphAutoSyncCoordinator

    init(
        navigationService: ProjectNavigationService = .init(),
        fileManager: FileManager = .default,
        syncCoordinator: WorkGraphAutoSyncCoordinator? = nil
    ) {
        self.navigationService = navigationService
        self.fileManager = fileManager
        self.syncCoordinator = syncCoordinator ?? WorkGraphAutoSyncCoordinator(
            navigationService: navigationService
        )
    }

    func execute(
        repositoryPath: String,
        request: WorkGraphQueryRequest
    ) throws -> WorkGraphQueryResult {
        let store = try queryableStore(for: repositoryPath)
        do {
            switch request {
            case let .definitions(definitionRequest):
                let query = definitionRequest.query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { throw WorkGraphQueryError.emptyDefinitionQuery }
                return .definitions(
                    WorkGraphDefinitionResult(
                        matches: try store.searchSymbols(query: query, limit: definitionRequest.limit)
                    )
                )

            case let .callers(traversalRequest):
                let root = try resolve(traversalRequest.symbol, in: store)
                return .callers(
                    WorkGraphTraversalResult(
                        root: root,
                        traversal: try store.callers(
                            of: root.id,
                            edgeKinds: traversalRequest.options.edgeKinds,
                            minimumConfidence: traversalRequest.options.minimumConfidence,
                            maxDepth: traversalRequest.options.limits.maxDepth,
                            limit: traversalRequest.options.limits.maxResults
                        )
                    )
                )

            case let .callees(traversalRequest):
                let root = try resolve(traversalRequest.symbol, in: store)
                return .callees(
                    WorkGraphTraversalResult(
                        root: root,
                        traversal: try store.callees(
                            of: root.id,
                            edgeKinds: traversalRequest.options.edgeKinds,
                            minimumConfidence: traversalRequest.options.minimumConfidence,
                            maxDepth: traversalRequest.options.limits.maxDepth,
                            limit: traversalRequest.options.limits.maxResults
                        )
                    )
                )

            case let .trace(traceRequest):
                let source = try resolve(traceRequest.source, in: store)
                let target = try resolve(traceRequest.target, in: store)
                let limits = traceRequest.options.limits
                return .trace(
                    WorkGraphTraceResult(
                        source: source,
                        target: target,
                        path: try store.trace(
                            from: source.id,
                            to: target.id,
                            edgeKinds: traceRequest.options.edgeKinds,
                            minimumConfidence: traceRequest.options.minimumConfidence,
                            maxDepth: limits.maxDepth,
                            maxNodes: min(limits.maxResults + 1, WorkGraphQueryLimits.maximumResults + 1)
                        )
                    )
                )

            case let .impact(traversalRequest):
                let root = try resolve(traversalRequest.symbol, in: store)
                return .impact(
                    WorkGraphTraversalResult(
                        root: root,
                        traversal: try store.impact(
                            of: root.id,
                            edgeKinds: traversalRequest.options.edgeKinds,
                            minimumConfidence: traversalRequest.options.minimumConfidence,
                            maxDepth: traversalRequest.options.limits.maxDepth,
                            maxNodes: traversalRequest.options.limits.maxResults
                        )
                    )
                )

            case let .affectedTests(affectedTestsRequest):
                guard let sourcePath = WorkGraphRepositoryPath.normalizedRelativePath(
                    affectedTestsRequest.sourcePath
                ) else {
                    throw WorkGraphQueryError.invalidRepositoryRelativePath
                }
                let limits = affectedTestsRequest.limits
                let maximumTraversalNodes = min(
                    Self.maximumAffectedTestsTraversalNodes,
                    max(limits.maxResults, limits.maxResults * Self.affectedTestsTraversalMultiplier)
                )
                return .affectedTests(
                    WorkGraphAffectedTestsResult(
                        sourcePath: sourcePath,
                        testPaths: try store.affectedTestPaths(
                            forSourcePath: sourcePath,
                            edgeKinds: Self.affectedTestsEdgeKinds,
                            minimumConfidence: Self.affectedTestsMinimumConfidence,
                            maxDepth: limits.maxDepth,
                            maxResults: limits.maxResults,
                            maximumTraversedNodes: maximumTraversalNodes,
                            isTestPath: WorkGraphRepositoryPath.isTestSourcePath
                        )
                    )
                )
            }
        } catch let error as WorkGraphQueryError {
            throw error
        } catch {
            throw WorkGraphQueryError.queryFailed
        }
    }

    private func queryableStore(for repositoryPath: String) throws -> WorkGraphStore {
        do {
            _ = try syncCoordinator.ensureCurrent(repositoryPath: repositoryPath)
        } catch {
            throw WorkGraphQueryError.navigationNotCurrent
        }
        switch navigationService.status(for: repositoryPath) {
        case .notGenerated:
            throw WorkGraphQueryError.navigationNotGenerated
        case .updateRecommended:
            throw WorkGraphQueryError.navigationNotCurrent
        case .current:
            break
        }

        let databaseURL = URL(
            fileURLWithPath: ProjectNavigationService.workgraphPath(for: repositoryPath),
            isDirectory: true
        ).appendingPathComponent(WorkGraphStore.fileName)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: databaseURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw WorkGraphQueryError.indexUnavailable
        }

        let store = WorkGraphStore(databaseURL: databaseURL, accessMode: .readOnly)
        do {
            guard try store.hasCompatibleIndex() else {
                throw WorkGraphQueryError.incompatibleIndex
            }
        } catch let error as WorkGraphQueryError {
            throw error
        } catch {
            throw WorkGraphQueryError.incompatibleIndex
        }
        return store
    }

    private func resolve(
        _ selector: WorkGraphSymbolSelector,
        in store: WorkGraphStore
    ) throws -> WorkGraphNode {
        switch selector {
        case let .id(rawID):
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw WorkGraphQueryError.emptySymbolSelector }
            guard let node = try store.node(withID: id) else {
                throw WorkGraphQueryError.symbolNotFound
            }
            return node

        case let .qualifiedName(rawQualifiedName):
            let qualifiedName = rawQualifiedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !qualifiedName.isEmpty else { throw WorkGraphQueryError.emptySymbolSelector }
            let matches = try store.nodes(
                qualifiedName: qualifiedName,
                limit: Self.maximumExactSelectorCandidates
            )
            guard !matches.isEmpty else { throw WorkGraphQueryError.symbolNotFound }
            guard matches.count == 1, let match = matches.first else {
                throw WorkGraphQueryError.ambiguousSymbol(matches)
            }
            return match
        }
    }
}

/// Source-bearing reads are intentionally separate from structural traversal.
/// The graph remains the selector; current repository files remain the only
/// source of code bodies returned to an Agent.
final class WorkGraphInspectionService {
    private static let maximumDefinitionCandidates = 48

    private let navigationService: ProjectNavigationService
    private let fileManager: FileManager
    private let syncCoordinator: WorkGraphAutoSyncCoordinator

    init(
        navigationService: ProjectNavigationService = .init(),
        fileManager: FileManager = .default,
        syncCoordinator: WorkGraphAutoSyncCoordinator? = nil
    ) {
        self.navigationService = navigationService
        self.fileManager = fileManager
        self.syncCoordinator = syncCoordinator ?? WorkGraphAutoSyncCoordinator(
            navigationService: navigationService
        )
    }

    func status(repositoryPath: String) -> WorkGraphStatusInspectionResult {
        // Reconcile an existing cache before reporting its state. A missing
        // cache remains an explicit UI action; only silent catch-up is automatic.
        _ = try? syncCoordinator.ensureCurrent(repositoryPath: repositoryPath)
        let navigationStatus = navigationService.status(for: repositoryPath)
        switch navigationStatus {
        case .notGenerated:
            return WorkGraphStatusInspectionResult(
                state: .notGenerated,
                isQueryable: false,
                generatedAt: nil,
                sourceFileCount: nil,
                indexedSymbolCount: nil,
                indexedEdgeCount: nil,
                stalePaths: []
            )
        case let .updateRecommended(generatedAt, _, metrics):
            return WorkGraphStatusInspectionResult(
                state: .updateRecommended,
                isQueryable: false,
                generatedAt: generatedAt,
                sourceFileCount: metrics.sourceFileCount,
                indexedSymbolCount: metrics.indexedSymbolCount,
                indexedEdgeCount: metrics.indexedEdgeCount,
                stalePaths: []
            )
        case let .current(generatedAt, _, metrics):
            let session = try? queryableSession(for: repositoryPath)
            return WorkGraphStatusInspectionResult(
                state: .current,
                isQueryable: session != nil,
                generatedAt: generatedAt,
                sourceFileCount: metrics.sourceFileCount,
                indexedSymbolCount: metrics.indexedSymbolCount,
                indexedEdgeCount: metrics.indexedEdgeCount,
                stalePaths: session.map { stalePaths(in: $0) } ?? []
            )
        }
    }

    func files(
        repositoryPath: String,
        request: WorkGraphFileListRequest = .init()
    ) throws -> [WorkGraphFileInspectionResult] {
        let session = try queryableSession(for: repositoryPath)
        let prefix = try normalizedPrefix(request.pathPrefix)
        return session.recordsByPath.values
            .filter { record in
                prefix.map { record.path == $0 || record.path.hasPrefix($0 + "/") } ?? true
            }
            .sorted { $0.path < $1.path }
            .prefix(request.maximumResults)
            .map { record in
                WorkGraphFileInspectionResult(
                    file: record,
                    isCurrent: isCurrent(record, in: session.repositoryURL)
                )
            }
    }

    func node(
        repositoryPath: String,
        request: WorkGraphNodeInspectionRequest
    ) throws -> WorkGraphNodeInspectionResult {
        let session = try queryableSession(for: repositoryPath)
        let node: WorkGraphNode?
        let record: WorkGraphFileRecord
        let defaultStartLine: Int

        switch request.target {
        case let .path(rawPath):
            guard let path = WorkGraphRepositoryPath.normalizedRelativePath(rawPath),
                  let matchedRecord = session.recordsByPath[path] else {
                throw WorkGraphInspectionError.indexedFileNotFound
            }
            node = nil
            record = matchedRecord
            defaultStartLine = 1
        case let .symbol(selector):
            let matchedNode = try resolve(selector, in: session.store)
            guard let matchedRecord = session.recordsByPath[matchedNode.path] else {
                throw WorkGraphInspectionError.indexedFileNotFound
            }
            node = matchedNode
            record = matchedRecord
            defaultStartLine = matchedNode.location.startLine
        }

        let window = try sourceWindow(
            record: record,
            repositoryURL: session.repositoryURL,
            startLine: request.startLine ?? defaultStartLine,
            maximumLines: request.maximumLines,
            maximumCharacters: request.maximumCharacters
        )
        return WorkGraphNodeInspectionResult(
            node: node,
            file: record,
            isCurrent: window.isCurrent,
            sourceStartLine: window.startLine,
            source: window.source
        )
    }

    func explore(
        repositoryPath: String,
        request: WorkGraphExploreRequest
    ) throws -> WorkGraphExploreResult {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw WorkGraphInspectionError.emptyExploreQuery }

        let session = try queryableSession(for: repositoryPath)
        let matches = try session.store.searchSymbols(
            query: query,
            limit: min(Self.maximumDefinitionCandidates, request.maximumFiles * 8)
        )
        var preferredPaths: [String] = []
        var nodesByPath: [String: WorkGraphNode] = [:]

        for match in matches {
            if !preferredPaths.contains(match.path) {
                preferredPaths.append(match.path)
            }
            if nodesByPath[match.path] == nil,
               let node = try? session.store.node(withID: match.id) {
                nodesByPath[match.path] = node
            }
        }

        if let evidence = navigationService.evidence(for: repositoryPath, query: query) {
            for candidate in evidence.candidates where !preferredPaths.contains(candidate.path) {
                preferredPaths.append(candidate.path)
                if let symbol = candidate.symbol,
                   let matched = try? session.store.searchSymbols(query: symbol, limit: 8),
                   let exact = matched.first(where: { $0.path == candidate.path && $0.name == symbol }),
                   let node = try? session.store.node(withID: exact.id) {
                    nodesByPath[candidate.path] = node
                }
            }
        }

        if preferredPaths.isEmpty {
            let pathNeedle = query.lowercased()
            preferredPaths = session.recordsByPath.keys
                .filter { $0.lowercased().contains(pathNeedle) }
                .sorted()
        }

        let includesTests = query.lowercased().contains("test") || query.contains("测试")
        let selectedPaths = preferredPaths.filter {
            includesTests || !WorkGraphRepositoryPath.isTestSourcePath($0)
        }

        var remainingCharacters = request.maximumCharacters
        var files: [WorkGraphExploreFileResult] = []
        for path in selectedPaths where files.count < request.maximumFiles {
            guard let record = session.recordsByPath[path] else { continue }
            let node = nodesByPath[path]
            let maximumCharacters = min(
                max(0, remainingCharacters),
                max(512, request.maximumCharacters / request.maximumFiles)
            )
            let window: SourceWindow
            if maximumCharacters > 0 {
                window = try sourceWindow(
                    record: record,
                    repositoryURL: session.repositoryURL,
                    startLine: node?.location.startLine ?? 1,
                    maximumLines: request.maximumLinesPerFile,
                    maximumCharacters: maximumCharacters
                )
            } else {
                window = SourceWindow(isCurrent: isCurrent(record, in: session.repositoryURL), startLine: nil, source: nil)
            }
            remainingCharacters -= window.source?.count ?? 0
            files.append(
                WorkGraphExploreFileResult(
                    node: node,
                    file: record,
                    isCurrent: window.isCurrent,
                    sourceStartLine: window.startLine,
                    source: window.source
                )
            )
        }
        return WorkGraphExploreResult(files: files)
    }

    private func queryableSession(for repositoryPath: String) throws -> Session {
        do {
            _ = try syncCoordinator.ensureCurrent(repositoryPath: repositoryPath)
        } catch {
            throw WorkGraphQueryError.navigationNotCurrent
        }
        switch navigationService.status(for: repositoryPath) {
        case .notGenerated:
            throw WorkGraphQueryError.navigationNotGenerated
        case .updateRecommended:
            throw WorkGraphQueryError.navigationNotCurrent
        case .current:
            break
        }

        let repositoryURL = URL(fileURLWithPath: repositoryPath, isDirectory: true)
            .standardizedFileURL
        let databaseURL = URL(
            fileURLWithPath: ProjectNavigationService.workgraphPath(for: repositoryURL.path),
            isDirectory: true
        ).appendingPathComponent(WorkGraphStore.fileName)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: databaseURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw WorkGraphQueryError.indexUnavailable
        }

        let store = WorkGraphStore(databaseURL: databaseURL, accessMode: .readOnly)
        do {
            guard try store.hasCompatibleIndex() else {
                throw WorkGraphQueryError.incompatibleIndex
            }
            let records = try store.indexedFiles()
            return Session(
                repositoryURL: repositoryURL,
                store: store,
                recordsByPath: Dictionary(uniqueKeysWithValues: records.map { ($0.path, $0) })
            )
        } catch let error as WorkGraphQueryError {
            throw error
        } catch {
            throw WorkGraphQueryError.incompatibleIndex
        }
    }

    private func resolve(
        _ selector: WorkGraphSymbolSelector,
        in store: WorkGraphStore
    ) throws -> WorkGraphNode {
        switch selector {
        case let .id(rawID):
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw WorkGraphQueryError.emptySymbolSelector }
            guard let node = try store.node(withID: id) else {
                throw WorkGraphQueryError.symbolNotFound
            }
            return node
        case let .qualifiedName(rawQualifiedName):
            let qualifiedName = rawQualifiedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !qualifiedName.isEmpty else { throw WorkGraphQueryError.emptySymbolSelector }
            let matches = try store.nodes(qualifiedName: qualifiedName, limit: 9)
            guard !matches.isEmpty else { throw WorkGraphQueryError.symbolNotFound }
            guard matches.count == 1, let node = matches.first else {
                throw WorkGraphQueryError.ambiguousSymbol(matches)
            }
            return node
        }
    }

    private func normalizedPrefix(_ rawPrefix: String?) throws -> String? {
        guard let rawPrefix else { return nil }
        let trimmed = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withoutTrailingSlashes = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let normalized = WorkGraphRepositoryPath.normalizedRelativePath(withoutTrailingSlashes) else {
            throw WorkGraphInspectionError.invalidRepositoryRelativePath
        }
        return normalized
    }

    private func stalePaths(in session: Session) -> [String] {
        session.recordsByPath.values
            .filter { !isCurrent($0, in: session.repositoryURL) }
            .map(\.path)
            .sorted()
    }

    private func isCurrent(_ record: WorkGraphFileRecord, in repositoryURL: URL) -> Bool {
        let fileURL = repositoryURL.appendingPathComponent(record.path)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let values = try? fileURL.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.fileSize == record.byteCount,
              let indexedAt = record.modifiedAt,
              let currentModifiedAt = values.contentModificationDate else {
            return false
        }
        let indexedMilliseconds = Int64(indexedAt.timeIntervalSince1970 * 1_000)
        let currentMilliseconds = Int64(currentModifiedAt.timeIntervalSince1970 * 1_000)
        return indexedMilliseconds == currentMilliseconds
    }

    private func sourceWindow(
        record: WorkGraphFileRecord,
        repositoryURL: URL,
        startLine: Int,
        maximumLines: Int,
        maximumCharacters: Int
    ) throws -> SourceWindow {
        guard isCurrent(record, in: repositoryURL) else {
            return SourceWindow(isCurrent: false, startLine: nil, source: nil)
        }
        let fileURL = repositoryURL.appendingPathComponent(record.path)
        guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw WorkGraphInspectionError.sourceReadFailed
        }
        let lines = source.components(separatedBy: .newlines)
        let effectiveStart = min(max(1, startLine), max(1, lines.count))
        let endIndex = min(lines.count, effectiveStart - 1 + maximumLines)
        let selected = lines[(effectiveStart - 1)..<endIndex]
        var rendered = selected.enumerated().map { offset, line in
            "\(effectiveStart + offset)\t\(line)"
        }.joined(separator: "\n")
        if rendered.count > maximumCharacters {
            let suffix = "\n[truncated]"
            rendered = String(rendered.prefix(max(0, maximumCharacters - suffix.count))) + suffix
        }
        return SourceWindow(isCurrent: true, startLine: effectiveStart, source: rendered)
    }

    private struct Session {
        var repositoryURL: URL
        var store: WorkGraphStore
        var recordsByPath: [String: WorkGraphFileRecord]
    }

    private struct SourceWindow {
        var isCurrent: Bool
        var startLine: Int?
        var source: String?
    }
}
