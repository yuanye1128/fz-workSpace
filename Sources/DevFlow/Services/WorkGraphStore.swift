import Foundation
import SQLite3

struct WorkGraphEvidenceCandidate {
    var path: String
    var line: Int
    var symbol: String?
    var matchedTerms: [String]
    var score: Int
}

enum WorkGraphStoreError: LocalizedError {
    case database(String)
    case incompatibleSchema(Int)

    var errorDescription: String? {
        switch self {
        case let .database(message):
            return "WorkGraph 数据库操作失败：\(message)"
        case let .incompatibleSchema(version):
            return "WorkGraph 数据库版本 \(version) 高于当前 App 支持的版本。"
        }
    }
}

/// SQLite persistence for syntax facts. Cross-file resolution only writes after the full snapshot is visible.
final class WorkGraphStore {
    static let fileName = "workgraph.db"
    fileprivate static let schemaVersion = 3

    /// Read-only access is used by repository query consumers. It must never
    /// create a database, migrate a schema, or write logical index records.
    enum AccessMode {
        case readWrite
        case readOnly
    }

    private let databaseURL: URL
    private let accessMode: AccessMode

    init(databaseURL: URL, accessMode: AccessMode = .readWrite) {
        self.databaseURL = databaseURL
        self.accessMode = accessMode
    }

    func replace(
        index: WorkGraphIndexSnapshot,
        resolutions: [WorkGraphReferenceResolution] = []
    ) throws {
        let database = try WorkGraphDatabaseConnection(url: databaseURL, accessMode: accessMode)
        do {
            try database.execute("BEGIN IMMEDIATE")
            try database.clearIndex()
            try database.replaceMetadata(generatedAt: Date())
            try database.insert(files: index.files)
            try database.insert(nodes: index.nodes)
            try database.insert(edges: index.edges)
            try database.insert(references: index.references)
            try database.apply(resolutions: resolutions)
            try database.insert(documents: index.documents)
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    /// Returns only syntax facts from a complete, compatible cache. Resolver
    /// edges are intentionally excluded because they must be recalculated after
    /// a repository-wide snapshot is assembled.
    func cachedSyntaxSnapshot() throws -> WorkGraphIndexSnapshot? {
        let database = try WorkGraphDatabaseConnection(url: databaseURL, accessMode: accessMode)
        return try database.cachedSyntaxSnapshot()
    }

    func evidence(for terms: [String], limit: Int) throws -> [WorkGraphEvidenceCandidate] {
        guard !terms.isEmpty, limit > 0 else { return [] }
        let database = try WorkGraphDatabaseConnection(url: databaseURL, accessMode: accessMode)
        return try database.searchEvidence(terms: terms, limit: limit)
    }

    func searchSymbols(query: String, limit: Int) throws -> [WorkGraphSymbolMatch] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, limit > 0 else { return [] }
        let database = try WorkGraphDatabaseConnection(url: databaseURL, accessMode: accessMode)
        return try database.searchSymbols(query: query, limit: limit)
    }

    /// Looks up one persisted node by its opaque, exact ID.
    func node(withID nodeID: String) throws -> WorkGraphNode? {
        guard !nodeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let database = try WorkGraphDatabaseConnection(url: databaseURL, accessMode: accessMode)
        return try database.node(withID: nodeID)
    }

    /// Looks up symbols by an exact qualified name. Callers must still reject
    /// more than one result rather than guessing which overload was intended.
    func nodes(qualifiedName: String, limit: Int) throws -> [WorkGraphNode] {
        guard !qualifiedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              limit > 0 else {
            return []
        }
        let database = try WorkGraphDatabaseConnection(url: databaseURL, accessMode: accessMode)
        return try database.nodes(qualifiedName: qualifiedName, maximumResults: limit)
    }

    /// Checks the immutable pieces required for a queryable generated index.
    /// The caller's access mode is preserved, so a read-only store validates
    /// without performing migrations or journal changes.
    func hasCompatibleIndex() throws -> Bool {
        let database = try WorkGraphDatabaseConnection(url: databaseURL, accessMode: accessMode)
        return try database.hasCompatibleIndex()
    }

    /// Returns indexed file metadata without loading nodes, edges, or documents.
    /// Callers can use it to reject evidence from files changed after indexing.
    func indexedFiles() throws -> [WorkGraphFileRecord] {
        let database = try WorkGraphDatabaseConnection(url: databaseURL, accessMode: accessMode)
        return try database.indexedFiles()
    }

    /// Finds resolved nodes with edges directed toward `nodeID`.
    ///
    /// The query only accepts an exact persisted node ID. By default it follows
    /// high-confidence call edges; callers can opt into another explicit edge set.
    func callers(
        of nodeID: String,
        edgeKinds: Set<WorkGraphEdgeKind> = [.calls],
        minimumConfidence: Double = 0.85,
        maxDepth: Int = 1,
        limit: Int = 20
    ) throws -> WorkGraphTraversal {
        let database = try WorkGraphDatabaseConnection(url: databaseURL, accessMode: accessMode)
        return try database.traverse(
            from: nodeID,
            direction: .incoming,
            edgeKinds: edgeKinds,
            minimumConfidence: minimumConfidence,
            maxDepth: maxDepth,
            maximumResults: limit
        )
    }

    /// Finds resolved nodes with edges directed away from `nodeID`.
    ///
    /// The query only accepts an exact persisted node ID. By default it follows
    /// high-confidence call edges; callers can opt into another explicit edge set.
    func callees(
        of nodeID: String,
        edgeKinds: Set<WorkGraphEdgeKind> = [.calls],
        minimumConfidence: Double = 0.85,
        maxDepth: Int = 1,
        limit: Int = 20
    ) throws -> WorkGraphTraversal {
        let database = try WorkGraphDatabaseConnection(url: databaseURL, accessMode: accessMode)
        return try database.traverse(
            from: nodeID,
            direction: .outgoing,
            edgeKinds: edgeKinds,
            minimumConfidence: minimumConfidence,
            maxDepth: maxDepth,
            maximumResults: limit
        )
    }

    /// Returns a shortest, bounded route through resolved edges, or `nil` when
    /// no route satisfies the declared confidence and edge-kind constraints.
    func trace(
        from sourceID: String,
        to targetID: String,
        edgeKinds: Set<WorkGraphEdgeKind> = [.calls],
        minimumConfidence: Double = 0.85,
        maxDepth: Int = 8,
        maxNodes: Int = 64
    ) throws -> WorkGraphPath? {
        let database = try WorkGraphDatabaseConnection(url: databaseURL, accessMode: accessMode)
        return try database.trace(
            from: sourceID,
            to: targetID,
            edgeKinds: edgeKinds,
            minimumConfidence: minimumConfidence,
            maxDepth: maxDepth,
            maxNodes: maxNodes
        )
    }

    /// Traverses reverse dependency edges to find high-confidence code that may
    /// be affected by changing `nodeID`.
    func impact(
        of nodeID: String,
        edgeKinds: Set<WorkGraphEdgeKind> = [.calls],
        minimumConfidence: Double = 0.85,
        maxDepth: Int = 3,
        maxNodes: Int = 64
    ) throws -> WorkGraphTraversal {
        let database = try WorkGraphDatabaseConnection(url: databaseURL, accessMode: accessMode)
        return try database.traverse(
            from: nodeID,
            direction: .incoming,
            edgeKinds: edgeKinds,
            minimumConfidence: minimumConfidence,
            maxDepth: maxDepth,
            maximumResults: maxNodes
        )
    }

    /// Returns test-source paths with a verified reverse dependency on any
    /// indexed node in one exact source file. The caller supplies the test-path
    /// convention so this persistence layer remains independent of repository
    /// layout policy.
    func affectedTestPaths(
        forSourcePath sourcePath: String,
        edgeKinds: Set<WorkGraphEdgeKind>,
        minimumConfidence: Double,
        maxDepth: Int,
        maxResults: Int,
        maximumTraversedNodes: Int,
        isTestPath: (String) -> Bool
    ) throws -> [String] {
        let database = try WorkGraphDatabaseConnection(url: databaseURL, accessMode: accessMode)
        return try database.affectedTestPaths(
            forSourcePath: sourcePath,
            edgeKinds: edgeKinds,
            minimumConfidence: minimumConfidence,
            maxDepth: maxDepth,
            maxResults: maxResults,
            maximumTraversedNodes: maximumTraversedNodes,
            isTestPath: isTestPath
        )
    }
}

private final class WorkGraphDatabaseConnection {
    private var handle: OpaquePointer?

    enum GraphEdgeDirection: Equatable {
        case incoming
        case outgoing
    }

    init(url: URL, accessMode: WorkGraphStore.AccessMode) throws {
        var opened: OpaquePointer?
        let openFlags: Int32
        switch accessMode {
        case .readWrite:
            openFlags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        case .readOnly:
            openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        }
        let result = sqlite3_open_v2(
            url.path,
            &opened,
            openFlags,
            nil
        )
        guard result == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw WorkGraphStoreError.database("无法打开 \(url.path)")
        }
        handle = opened
        if accessMode == .readWrite {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
            try migrate()
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? databaseMessage
            sqlite3_free(errorPointer)
            throw WorkGraphStoreError.database(message)
        }
    }

    func clearIndex() throws {
        try execute("DELETE FROM edges")
        try execute("DELETE FROM reference_occurrences")
        try execute("DELETE FROM nodes_fts")
        try execute("DELETE FROM nodes")
        try execute("DELETE FROM documents")
        try execute("DELETE FROM files")
    }

    func cachedSyntaxSnapshot() throws -> WorkGraphIndexSnapshot? {
        guard try metadataValue(for: "schema_version") == String(WorkGraphStore.schemaVersion),
              try metadataValue(for: "generated_at") != nil else {
            return nil
        }

        let files = try cachedFiles()
        let nodes = try cachedNodes()
        let edges = try cachedASTEdges()
        let references = try cachedReferences()
        let documents = try cachedDocuments()
        try validateCachedSnapshot(
            files: files,
            nodes: nodes,
            edges: edges,
            references: references,
            documents: documents
        )
        return WorkGraphIndexSnapshot(
            files: files,
            nodes: nodes,
            edges: edges,
            references: references,
            documents: documents
        )
    }

    func replaceMetadata(generatedAt: Date) throws {
        let statement = try prepare(
            "INSERT INTO metadata(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        )
        defer { sqlite3_finalize(statement) }
        try bind("generated_at", at: 1, to: statement)
        try bind(generatedAt.ISO8601Format(), at: 2, to: statement)
        try stepDone(statement)

        try reset(statement)
        try bind("schema_version", at: 1, to: statement)
        try bind(String(WorkGraphStore.schemaVersion), at: 2, to: statement)
        try stepDone(statement)
    }

    private func metadataValue(for key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM metadata WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        guard try nextRow(statement) else { return nil }
        return columnText(statement, at: 0)
    }

    private func cachedFiles() throws -> [WorkGraphFileRecord] {
        let statement = try prepare(
            """
            SELECT path, content_hash, language, size, modified_at, generated, errors_json
            FROM files
            ORDER BY path
            """
        )
        defer { sqlite3_finalize(statement) }
        let decoder = JSONDecoder()
        var files: [WorkGraphFileRecord] = []
        while try nextRow(statement) {
            guard let path = columnText(statement, at: 0),
                  let contentHash = columnText(statement, at: 1),
                  let languageRaw = columnText(statement, at: 2),
                  let language = WorkGraphLanguage(rawValue: languageRaw),
                  let diagnosticsJSON = columnText(statement, at: 6),
                  let diagnostics = try? decoder.decode([String].self, from: Data(diagnosticsJSON.utf8)) else {
                throw WorkGraphStoreError.database("WorkGraph 缓存文件记录无效")
            }
            let modifiedAt = columnOptionalInt64(statement, at: 4).map {
                Date(timeIntervalSince1970: Double($0) / 1_000)
            }
            files.append(
                WorkGraphFileRecord(
                    path: path,
                    contentHash: contentHash,
                    language: language,
                    byteCount: Int(sqlite3_column_int64(statement, 3)),
                    modifiedAt: modifiedAt,
                    isGenerated: sqlite3_column_int64(statement, 5) != 0,
                    diagnostics: diagnostics
                )
            )
        }
        return files
    }

    private func cachedNodes() throws -> [WorkGraphNodeDraft] {
        let statement = try prepare(
            """
            SELECT id, parent_id, kind, name, qualified_name, file_path, language,
                   start_line, end_line, start_column, end_column,
                   signature, visibility, is_exported, is_async, is_static, is_abstract,
                   decorators_json, return_type
            FROM nodes
            ORDER BY id
            """
        )
        defer { sqlite3_finalize(statement) }
        let decoder = JSONDecoder()
        var nodes: [WorkGraphNodeDraft] = []
        while try nextRow(statement) {
            guard let id = columnText(statement, at: 0),
                  let kindRaw = columnText(statement, at: 2),
                  let kind = WorkGraphNodeKind(rawValue: kindRaw),
                  let name = columnText(statement, at: 3),
                  let qualifiedName = columnText(statement, at: 4),
                  let filePath = columnText(statement, at: 5),
                  let languageRaw = columnText(statement, at: 6),
                  let language = WorkGraphLanguage(rawValue: languageRaw),
                  let decoratorsJSON = columnText(statement, at: 17),
                  let decorators = try? decoder.decode([String].self, from: Data(decoratorsJSON.utf8)) else {
                throw WorkGraphStoreError.database("WorkGraph 缓存符号记录无效")
            }
            nodes.append(
                WorkGraphNodeDraft(
                    id: id,
                    parentID: columnText(statement, at: 1),
                    kind: kind,
                    name: name,
                    qualifiedName: qualifiedName,
                    filePath: filePath,
                    language: language,
                    location: WorkGraphSourceLocation(
                        startLine: Int(sqlite3_column_int64(statement, 7)),
                        endLine: Int(sqlite3_column_int64(statement, 8)),
                        startColumn: Int(sqlite3_column_int64(statement, 9)),
                        endColumn: Int(sqlite3_column_int64(statement, 10))
                    ),
                    signature: columnText(statement, at: 11),
                    visibility: columnText(statement, at: 12),
                    isExported: sqlite3_column_int64(statement, 13) != 0,
                    isAsync: sqlite3_column_int64(statement, 14) != 0,
                    isStatic: sqlite3_column_int64(statement, 15) != 0,
                    isAbstract: sqlite3_column_int64(statement, 16) != 0,
                    returnType: columnText(statement, at: 18),
                    decorators: decorators
                )
            )
        }
        return nodes
    }

    private func cachedASTEdges() throws -> [WorkGraphEdgeDraft] {
        let statement = try prepare(
            """
            SELECT source_node_id, target_node_id, kind, line, column, confidence, provenance, metadata_json
            FROM edges
            WHERE provenance = 'ast'
            ORDER BY source_node_id, target_node_id, kind, line, column
            """
        )
        defer { sqlite3_finalize(statement) }
        var edges: [WorkGraphEdgeDraft] = []
        while try nextRow(statement) {
            guard let sourceID = columnText(statement, at: 0),
                  let targetID = columnText(statement, at: 1),
                  let kindRaw = columnText(statement, at: 2),
                  let kind = WorkGraphEdgeKind(rawValue: kindRaw),
                  let provenanceRaw = columnText(statement, at: 6),
                  let provenance = WorkGraphEdgeProvenance(rawValue: provenanceRaw) else {
                throw WorkGraphStoreError.database("WorkGraph 缓存关系记录无效")
            }
            let line = columnOptionalInt(statement, at: 3)
            let column = columnOptionalInt(statement, at: 4)
            guard (line == nil) == (column == nil) else {
                throw WorkGraphStoreError.database("WorkGraph 缓存关系位置无效")
            }
            let location = line.map {
                WorkGraphSourceLocation(
                    startLine: $0,
                    endLine: $0,
                    startColumn: column ?? 0,
                    endColumn: column ?? 0
                )
            }
            edges.append(
                WorkGraphEdgeDraft(
                    sourceID: sourceID,
                    targetID: targetID,
                    kind: kind,
                    location: location,
                    metadataJSON: columnText(statement, at: 7),
                    confidence: sqlite3_column_double(statement, 5),
                    provenance: provenance
                )
            )
        }
        return edges
    }

    private func cachedReferences() throws -> [WorkGraphReferenceDraft] {
        let statement = try prepare(
            """
            SELECT from_node_id, raw_name, relation_kind, line, column,
                   candidate_names_json, file_path, language, fingerprint
            FROM reference_occurrences
            ORDER BY fingerprint
            """
        )
        defer { sqlite3_finalize(statement) }
        let decoder = JSONDecoder()
        var references: [WorkGraphReferenceDraft] = []
        while try nextRow(statement) {
            guard let fromNodeID = columnText(statement, at: 0),
                  let rawName = columnText(statement, at: 1),
                  let kindRaw = columnText(statement, at: 2),
                  let kind = WorkGraphEdgeKind(rawValue: kindRaw),
                  let candidateNamesJSON = columnText(statement, at: 5),
                  let candidateNames = try? decoder.decode([String].self, from: Data(candidateNamesJSON.utf8)),
                  let filePath = columnText(statement, at: 6),
                  let languageRaw = columnText(statement, at: 7),
                  let language = WorkGraphLanguage(rawValue: languageRaw),
                  let fingerprint = columnText(statement, at: 8) else {
                throw WorkGraphStoreError.database("WorkGraph 缓存引用记录无效")
            }
            references.append(
                WorkGraphReferenceDraft(
                    fromNodeID: fromNodeID,
                    rawName: rawName,
                    kind: kind,
                    location: WorkGraphSourceLocation(
                        startLine: Int(sqlite3_column_int64(statement, 3)),
                        endLine: Int(sqlite3_column_int64(statement, 3)),
                        startColumn: Int(sqlite3_column_int64(statement, 4)),
                        endColumn: Int(sqlite3_column_int64(statement, 4))
                    ),
                    candidateNames: candidateNames,
                    filePath: filePath,
                    language: language,
                    fingerprint: fingerprint
                )
            )
        }
        return references
    }

    private func cachedDocuments() throws -> [WorkGraphDocumentRecord] {
        let statement = try prepare("SELECT path, terms_json FROM documents ORDER BY path")
        defer { sqlite3_finalize(statement) }
        let decoder = JSONDecoder()
        var documents: [WorkGraphDocumentRecord] = []
        while try nextRow(statement) {
            guard let path = columnText(statement, at: 0),
                  let termsJSON = columnText(statement, at: 1),
                  let terms = try? decoder.decode([String].self, from: Data(termsJSON.utf8)) else {
                throw WorkGraphStoreError.database("WorkGraph 缓存文档记录无效")
            }
            documents.append(WorkGraphDocumentRecord(path: path, terms: terms))
        }
        return documents
    }

    private func validateCachedSnapshot(
        files: [WorkGraphFileRecord],
        nodes: [WorkGraphNodeDraft],
        edges: [WorkGraphEdgeDraft],
        references: [WorkGraphReferenceDraft],
        documents: [WorkGraphDocumentRecord]
    ) throws {
        let filePaths = Set(files.map(\.path))
        let nodeIDs = Set(nodes.map(\.id))
        let nodeFilePaths = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.filePath) })
        guard filePaths.count == files.count,
              nodeIDs.count == nodes.count,
              nodes.allSatisfy({ filePaths.contains($0.filePath) }),
              nodes.allSatisfy({ $0.parentID == nil || nodeIDs.contains($0.parentID!) }),
              edges.allSatisfy({ nodeIDs.contains($0.sourceID) && nodeIDs.contains($0.targetID) }),
              references.allSatisfy({
                  filePaths.contains($0.filePath) && nodeFilePaths[$0.fromNodeID] == $0.filePath
              }),
              documents.allSatisfy({ filePaths.contains($0.path) }) else {
            throw WorkGraphStoreError.database("WorkGraph 缓存一致性校验失败")
        }
    }

    func insert(files: [WorkGraphFileRecord]) throws {
        let statement = try prepare(
            """
            INSERT INTO files(path, content_hash, language, size, modified_at, indexed_at, node_count, errors_json, generated)
            VALUES(?, ?, ?, ?, ?, ?, 0, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        let encoder = JSONEncoder()
        let indexedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        for file in files {
            try reset(statement)
            try bind(file.path, at: 1, to: statement)
            try bind(file.contentHash, at: 2, to: statement)
            try bind(file.language.rawValue, at: 3, to: statement)
            try bind(Int64(file.byteCount), at: 4, to: statement)
            try bind(file.modifiedAt.map { Int64($0.timeIntervalSince1970 * 1_000) }, at: 5, to: statement)
            try bind(indexedAt, at: 6, to: statement)
            try bind(String(decoding: try encoder.encode(file.diagnostics), as: UTF8.self), at: 7, to: statement)
            try bind(file.isGenerated ? Int64(1) : Int64(0), at: 8, to: statement)
            try stepDone(statement)
        }
    }

    func insert(nodes: [WorkGraphNodeDraft]) throws {
        let statement = try prepare(
            """
            INSERT INTO nodes(
                id, parent_id, kind, name, qualified_name, file_path, language,
                start_line, end_line, start_column, end_column,
                signature, visibility, is_exported, is_async, is_static, is_abstract,
                decorators_json, return_type, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        let encoder = JSONEncoder()
        let updatedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        for node in nodes {
            try reset(statement)
            try bind(node.id, at: 1, to: statement)
            try bind(node.parentID, at: 2, to: statement)
            try bind(node.kind.rawValue, at: 3, to: statement)
            try bind(node.name, at: 4, to: statement)
            try bind(node.qualifiedName, at: 5, to: statement)
            try bind(node.filePath, at: 6, to: statement)
            try bind(node.language.rawValue, at: 7, to: statement)
            try bind(Int64(node.location.startLine), at: 8, to: statement)
            try bind(Int64(node.location.endLine), at: 9, to: statement)
            try bind(Int64(node.location.startColumn), at: 10, to: statement)
            try bind(Int64(node.location.endColumn), at: 11, to: statement)
            try bind(node.signature, at: 12, to: statement)
            try bind(node.visibility, at: 13, to: statement)
            try bind(node.isExported ? Int64(1) : Int64(0), at: 14, to: statement)
            try bind(node.isAsync ? Int64(1) : Int64(0), at: 15, to: statement)
            try bind(node.isStatic ? Int64(1) : Int64(0), at: 16, to: statement)
            try bind(node.isAbstract ? Int64(1) : Int64(0), at: 17, to: statement)
            try bind(String(decoding: try encoder.encode(node.decorators), as: UTF8.self), at: 18, to: statement)
            try bind(node.returnType, at: 19, to: statement)
            try bind(updatedAt, at: 20, to: statement)
            try stepDone(statement)
        }

        let ftsStatement = try prepare(
            "INSERT INTO nodes_fts(id, name, qualified_name, signature) VALUES(?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(ftsStatement) }
        for node in nodes {
            try reset(ftsStatement)
            try bind(node.id, at: 1, to: ftsStatement)
            try bind(node.name, at: 2, to: ftsStatement)
            try bind(node.qualifiedName, at: 3, to: ftsStatement)
            try bind(node.signature, at: 4, to: ftsStatement)
            try stepDone(ftsStatement)
        }

        let countStatement = try prepare("UPDATE files SET node_count = node_count + 1 WHERE path = ?")
        defer { sqlite3_finalize(countStatement) }
        for node in nodes where node.kind != .file {
            try reset(countStatement)
            try bind(node.filePath, at: 1, to: countStatement)
            try stepDone(countStatement)
        }
    }

    func insert(edges: [WorkGraphEdgeDraft]) throws {
        let statement = try prepare(
            """
            INSERT OR IGNORE INTO edges(
                source_node_id, target_node_id, kind, line, column,
                confidence, provenance, metadata_json
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        for edge in edges {
            try reset(statement)
            try bind(edge.sourceID, at: 1, to: statement)
            try bind(edge.targetID, at: 2, to: statement)
            try bind(edge.kind.rawValue, at: 3, to: statement)
            try bind(edge.location.map { Int64($0.startLine) }, at: 4, to: statement)
            try bind(edge.location.map { Int64($0.startColumn) }, at: 5, to: statement)
            try bind(edge.confidence, at: 6, to: statement)
            try bind(edge.provenance.rawValue, at: 7, to: statement)
            try bind(edge.metadataJSON, at: 8, to: statement)
            try stepDone(statement)
        }
    }

    func insert(references: [WorkGraphReferenceDraft]) throws {
        let statement = try prepare(
            """
            INSERT INTO reference_occurrences(
                from_node_id, raw_name, relation_kind, line, column,
                candidate_names_json, file_path, language, status,
                resolved_target_id, confidence, resolver, name_tail, fingerprint
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, 'pending', NULL, NULL, NULL, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        let encoder = JSONEncoder()
        for reference in references {
            try reset(statement)
            try bind(reference.fromNodeID, at: 1, to: statement)
            try bind(reference.rawName, at: 2, to: statement)
            try bind(reference.kind.rawValue, at: 3, to: statement)
            try bind(Int64(reference.location.startLine), at: 4, to: statement)
            try bind(Int64(reference.location.startColumn), at: 5, to: statement)
            try bind(String(decoding: try encoder.encode(reference.candidateNames), as: UTF8.self), at: 6, to: statement)
            try bind(reference.filePath, at: 7, to: statement)
            try bind(reference.language.rawValue, at: 8, to: statement)
            try bind(reference.rawName.split(separator: ".").last.map(String.init) ?? reference.rawName, at: 9, to: statement)
            try bind(reference.fingerprint, at: 10, to: statement)
            try stepDone(statement)
        }
    }

    func apply(resolutions: [WorkGraphReferenceResolution]) throws {
        guard !resolutions.isEmpty else { return }
        let statement = try prepare(
            """
            UPDATE reference_occurrences
            SET status = ?, resolved_target_id = ?, confidence = ?, resolver = ?
            WHERE fingerprint = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        for resolution in resolutions {
            try reset(statement)
            try bind(resolution.status.rawValue, at: 1, to: statement)
            try bind(resolution.targetID, at: 2, to: statement)
            try bind(resolution.confidence, at: 3, to: statement)
            try bind(resolution.resolver, at: 4, to: statement)
            try bind(resolution.fingerprint, at: 5, to: statement)
            try stepDone(statement)
            guard sqlite3_changes(handle) == 1 else {
                throw WorkGraphStoreError.database("引用解析结果未对应到已写入的引用")
            }
        }
    }

    func insert(documents: [WorkGraphDocumentRecord]) throws {
        let statement = try prepare("INSERT INTO documents(path, terms_json) VALUES(?, ?)")
        defer { sqlite3_finalize(statement) }
        let encoder = JSONEncoder()
        for document in documents {
            try reset(statement)
            try bind(document.path, at: 1, to: statement)
            try bind(String(decoding: try encoder.encode(document.terms), as: UTF8.self), at: 2, to: statement)
            try stepDone(statement)
        }
    }

    func searchEvidence(terms: [String], limit: Int) throws -> [WorkGraphEvidenceCandidate] {
        let candidatesPerQuery = min(max(limit * 16, limit), 128)
        let whereClause = Array(repeating: "terms_json LIKE ?", count: terms.count).joined(separator: " OR ")
        let statement = try prepare(
            "SELECT path, terms_json FROM documents WHERE \(whereClause) ORDER BY path LIMIT ?"
        )
        defer { sqlite3_finalize(statement) }
        for (offset, term) in terms.enumerated() {
            try bind("%\(term)%", at: Int32(offset + 1), to: statement)
        }
        try bind(Int64(candidatesPerQuery), at: Int32(terms.count + 1), to: statement)

        let decoder = JSONDecoder()
        var candidates: [WorkGraphEvidenceCandidate] = []
        while try nextRow(statement) {
            guard let path = columnText(statement, at: 0),
                  let termsJSON = columnText(statement, at: 1),
                  let documentTerms = try? decoder.decode([String].self, from: Data(termsJSON.utf8)) else {
                continue
            }

            var score = 0
            var matches: [String] = []
            for term in terms {
                if documentTerms.contains(term) {
                    score += 3
                    matches.append(term)
                } else if term.count >= 3, documentTerms.contains(where: { $0.contains(term) }) {
                    score += 1
                    matches.append(term)
                }
            }

            let symbols = try symbols(at: path)
            let matchingSymbols = symbols.filter { symbol in
                let name = symbol.name.lowercased()
                return terms.contains { term in
                    term.count >= 3 && (name.contains(term) || term.contains(name))
                }
            }
            if !matchingSymbols.isEmpty {
                score += matchingSymbols.count * 4
                matches.append(contentsOf: matchingSymbols.map(\.name))
            }
            guard score > 0 else { continue }

            let primary = matchingSymbols.first ?? symbols.first
            candidates.append(
                WorkGraphEvidenceCandidate(
                    path: path,
                    line: primary?.location.startLine ?? 1,
                    symbol: primary?.name,
                    matchedTerms: Array(Set(matches)).sorted().prefix(3).map { $0 },
                    score: score
                )
            )
        }

        return candidates.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.path < rhs.path : lhs.score > rhs.score
        }.prefix(limit).map { $0 }
    }

    func searchSymbols(query: String, limit: Int) throws -> [WorkGraphSymbolMatch] {
        let queryTerms = query
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !queryTerms.isEmpty else { return [] }
        let ftsQuery = queryTerms.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " AND ")
        let statement = try prepare(
            """
            SELECT n.id, n.name, n.qualified_name, n.kind, n.file_path, n.language,
                   n.start_line, n.end_line, n.start_column, n.end_column
            FROM nodes_fts f
            JOIN nodes n ON n.id = f.id
            WHERE nodes_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(ftsQuery, at: 1, to: statement)
        try bind(Int64(limit), at: 2, to: statement)
        var matches: [WorkGraphSymbolMatch] = []
        while try nextRow(statement) {
            guard let id = columnText(statement, at: 0),
                  let name = columnText(statement, at: 1),
                  let qualifiedName = columnText(statement, at: 2),
                  let kindRaw = columnText(statement, at: 3),
                  let path = columnText(statement, at: 4),
                  let languageRaw = columnText(statement, at: 5) else { continue }
            matches.append(
                WorkGraphSymbolMatch(
                    id: id,
                    name: name,
                    qualifiedName: qualifiedName,
                    kind: WorkGraphNodeKind(rawValue: kindRaw) ?? .unknown,
                    path: path,
                    location: WorkGraphSourceLocation(
                        startLine: Int(sqlite3_column_int64(statement, 6)),
                        endLine: Int(sqlite3_column_int64(statement, 7)),
                        startColumn: Int(sqlite3_column_int64(statement, 8)),
                        endColumn: Int(sqlite3_column_int64(statement, 9))
                    ),
                    language: WorkGraphLanguage(rawValue: languageRaw) ?? .unknown
                )
            )
        }
        return matches
    }

    func traverse(
        from nodeID: String,
        direction: GraphEdgeDirection,
        edgeKinds: Set<WorkGraphEdgeKind>,
        minimumConfidence: Double,
        maxDepth: Int,
        maximumResults: Int
    ) throws -> WorkGraphTraversal {
        guard maxDepth > 0,
              maximumResults > 0,
              minimumConfidence.isFinite,
              !edgeKinds.isEmpty,
              try node(withID: nodeID) != nil else {
            return WorkGraphTraversal(nodes: [], edges: [])
        }

        var queue: [(id: String, depth: Int)] = [(id: nodeID, depth: 0)]
        var queueIndex = 0
        var seenNodeIDs: Set<String> = [nodeID]
        var discoveredNodeIDs: [String] = []
        var discoveredEdges: [WorkGraphEdge] = []

        while queueIndex < queue.count, discoveredNodeIDs.count < maximumResults {
            let current = queue[queueIndex]
            queueIndex += 1
            guard current.depth < maxDepth else { continue }

            let adjacentEdges = try edges(
                adjacentTo: current.id,
                direction: direction,
                edgeKinds: edgeKinds,
                minimumConfidence: minimumConfidence
            )
            for edge in adjacentEdges where discoveredNodeIDs.count < maximumResults {
                let nextNodeID = direction == .incoming ? edge.sourceID : edge.targetID
                guard seenNodeIDs.insert(nextNodeID).inserted else { continue }

                discoveredNodeIDs.append(nextNodeID)
                discoveredEdges.append(edge)
                queue.append((id: nextNodeID, depth: current.depth + 1))
            }
        }

        let nodesByID = try nodes(withIDs: discoveredNodeIDs)
        return WorkGraphTraversal(
            nodes: discoveredNodeIDs.compactMap { nodesByID[$0] },
            edges: discoveredEdges
        )
    }

    /// Bounded breadth-first reverse traversal from every file and symbol node
    /// belonging to `sourcePath`. It retains only paths designated as tests by
    /// the caller, but may pass through production or test helper nodes to find
    /// an indirect verified dependency.
    func affectedTestPaths(
        forSourcePath sourcePath: String,
        edgeKinds: Set<WorkGraphEdgeKind>,
        minimumConfidence: Double,
        maxDepth: Int,
        maxResults: Int,
        maximumTraversedNodes: Int,
        isTestPath: (String) -> Bool
    ) throws -> [String] {
        guard !sourcePath.isEmpty,
              maxDepth > 0,
              maxResults > 0,
              maximumTraversedNodes > 0,
              minimumConfidence.isFinite,
              !edgeKinds.isEmpty else {
            return []
        }

        let seeds = try nodes(inFilePath: sourcePath)
        guard !seeds.isEmpty else { return [] }

        var frontier = seeds.map(\.id).sorted()
        var seenNodeIDs = Set(frontier)
        var traversedNodeCount = 0
        var matchedPaths = Set<String>()
        var orderedMatchedPaths: [String] = []

        for _ in 0..<maxDepth {
            guard !frontier.isEmpty,
                  traversedNodeCount < maximumTraversedNodes,
                  orderedMatchedPaths.count < maxResults else {
                break
            }

            var nextNodeIDs: [String] = []
            for nodeID in frontier {
                let adjacentEdges = try edges(
                    adjacentTo: nodeID,
                    direction: .incoming,
                    edgeKinds: edgeKinds,
                    minimumConfidence: minimumConfidence
                )
                for edge in adjacentEdges where traversedNodeCount + nextNodeIDs.count < maximumTraversedNodes {
                    let nextNodeID = edge.sourceID
                    guard seenNodeIDs.insert(nextNodeID).inserted else { continue }
                    nextNodeIDs.append(nextNodeID)
                }
            }

            guard !nextNodeIDs.isEmpty else { break }
            let nodesByID = try nodes(withIDs: nextNodeIDs)
            var nextFrontier: [String] = []
            for nodeID in nextNodeIDs {
                guard let node = nodesByID[nodeID] else { continue }
                traversedNodeCount += 1
                nextFrontier.append(nodeID)
                guard isTestPath(node.path), matchedPaths.insert(node.path).inserted else { continue }
                orderedMatchedPaths.append(node.path)
                if orderedMatchedPaths.count == maxResults { break }
            }
            frontier = nextFrontier
        }

        return orderedMatchedPaths.sorted()
    }

    func trace(
        from sourceID: String,
        to targetID: String,
        edgeKinds: Set<WorkGraphEdgeKind>,
        minimumConfidence: Double,
        maxDepth: Int,
        maxNodes: Int
    ) throws -> WorkGraphPath? {
        guard maxNodes > 0,
              maxDepth >= 0,
              minimumConfidence.isFinite,
              !edgeKinds.isEmpty,
              let source = try node(withID: sourceID),
              try node(withID: targetID) != nil else {
            return nil
        }
        guard sourceID != targetID else {
            return WorkGraphPath(nodes: [source], edges: [])
        }
        guard maxDepth > 0 else { return nil }

        var queue: [(id: String, depth: Int)] = [(id: sourceID, depth: 0)]
        var queueIndex = 0
        var seenNodeIDs: Set<String> = [sourceID]
        var parents: [String: (previousID: String, edge: WorkGraphEdge)] = [:]

        while queueIndex < queue.count, seenNodeIDs.count < maxNodes {
            let current = queue[queueIndex]
            queueIndex += 1
            guard current.depth < maxDepth else { continue }

            let adjacentEdges = try edges(
                adjacentTo: current.id,
                direction: .outgoing,
                edgeKinds: edgeKinds,
                minimumConfidence: minimumConfidence
            )
            for edge in adjacentEdges where seenNodeIDs.count < maxNodes {
                let nextNodeID = edge.targetID
                guard seenNodeIDs.insert(nextNodeID).inserted else { continue }

                parents[nextNodeID] = (previousID: current.id, edge: edge)
                if nextNodeID == targetID {
                    return try path(
                        from: sourceID,
                        to: targetID,
                        parents: parents
                    )
                }
                queue.append((id: nextNodeID, depth: current.depth + 1))
            }
        }
        return nil
    }

    private func path(
        from sourceID: String,
        to targetID: String,
        parents: [String: (previousID: String, edge: WorkGraphEdge)]
    ) throws -> WorkGraphPath? {
        var nodeIDs = [targetID]
        var pathEdges: [WorkGraphEdge] = []
        var currentID = targetID

        while currentID != sourceID {
            guard let parent = parents[currentID] else { return nil }
            pathEdges.append(parent.edge)
            currentID = parent.previousID
            nodeIDs.append(currentID)
        }
        nodeIDs.reverse()
        pathEdges.reverse()

        let nodesByID = try nodes(withIDs: nodeIDs)
        let pathNodes = nodeIDs.compactMap { nodesByID[$0] }
        guard pathNodes.count == nodeIDs.count else { return nil }
        return WorkGraphPath(nodes: pathNodes, edges: pathEdges)
    }

    private func edges(
        adjacentTo nodeID: String,
        direction: GraphEdgeDirection,
        edgeKinds: Set<WorkGraphEdgeKind>,
        minimumConfidence: Double
    ) throws -> [WorkGraphEdge] {
        guard !edgeKinds.isEmpty else { return [] }
        let nodeColumn = direction == .incoming ? "target_node_id" : "source_node_id"
        let orderedKinds = edgeKinds.map(\.rawValue).sorted()
        let kindPlaceholders = Array(repeating: "?", count: orderedKinds.count).joined(separator: ", ")
        let statement = try prepare(
            """
            SELECT source_node_id, target_node_id, kind, line, column,
                   confidence, provenance, metadata_json
            FROM edges
            WHERE \(nodeColumn) = ? AND confidence >= ? AND kind IN (\(kindPlaceholders))
            ORDER BY confidence DESC, source_node_id, target_node_id, kind, line, column
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(nodeID, at: 1, to: statement)
        try bind(minimumConfidence, at: 2, to: statement)
        for (offset, kind) in orderedKinds.enumerated() {
            try bind(kind, at: Int32(offset + 3), to: statement)
        }

        var result: [WorkGraphEdge] = []
        while try nextRow(statement) {
            guard let sourceID = columnText(statement, at: 0),
                  let targetID = columnText(statement, at: 1),
                  let kindRaw = columnText(statement, at: 2),
                  let kind = WorkGraphEdgeKind(rawValue: kindRaw),
                  let provenanceRaw = columnText(statement, at: 6),
                  let provenance = WorkGraphEdgeProvenance(rawValue: provenanceRaw) else {
                continue
            }

            let line = columnOptionalInt(statement, at: 3)
            let column = columnOptionalInt(statement, at: 4)
            let location: WorkGraphSourceLocation?
            if let line, let column {
                location = WorkGraphSourceLocation(
                    startLine: line,
                    endLine: line,
                    startColumn: column,
                    endColumn: column
                )
            } else {
                location = nil
            }
            result.append(
                WorkGraphEdge(
                    sourceID: sourceID,
                    targetID: targetID,
                    kind: kind,
                    location: location,
                    confidence: sqlite3_column_double(statement, 5),
                    provenance: provenance,
                    metadataJSON: columnText(statement, at: 7)
                )
            )
        }
        return result
    }

    func node(withID id: String) throws -> WorkGraphNode? {
        let statement = try prepare(nodeSelectSQL + " WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, to: statement)
        guard try nextRow(statement) else { return nil }
        return decodeNode(statement)
    }

    func nodes(qualifiedName: String, maximumResults: Int) throws -> [WorkGraphNode] {
        guard maximumResults > 0 else { return [] }
        let statement = try prepare(
            nodeSelectSQL + " WHERE qualified_name = ? ORDER BY file_path, start_line, id LIMIT ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(qualifiedName, at: 1, to: statement)
        try bind(Int64(maximumResults), at: 2, to: statement)

        var results: [WorkGraphNode] = []
        while try nextRow(statement) {
            if let node = decodeNode(statement) {
                results.append(node)
            }
        }
        return results
    }

    private func nodes(inFilePath path: String) throws -> [WorkGraphNode] {
        let statement = try prepare(
            nodeSelectSQL + " WHERE file_path = ? ORDER BY kind, start_line, id"
        )
        defer { sqlite3_finalize(statement) }
        try bind(path, at: 1, to: statement)

        var results: [WorkGraphNode] = []
        while try nextRow(statement) {
            if let node = decodeNode(statement) {
                results.append(node)
            }
        }
        return results
    }

    private func nodes(withIDs ids: [String]) throws -> [String: WorkGraphNode] {
        guard !ids.isEmpty else { return [:] }
        let statement = try prepare(nodeSelectSQL + " WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        var nodesByID: [String: WorkGraphNode] = [:]
        for id in ids {
            try reset(statement)
            try bind(id, at: 1, to: statement)
            guard try nextRow(statement), let node = decodeNode(statement) else { continue }
            nodesByID[node.id] = node
        }
        return nodesByID
    }

    private var nodeSelectSQL: String {
        """
        SELECT id, kind, name, qualified_name, file_path, language,
               start_line, end_line, start_column, end_column,
               signature, visibility, is_exported, is_async, is_static, is_abstract,
               decorators_json, return_type
        FROM nodes
        """
    }

    private func decodeNode(_ statement: OpaquePointer) -> WorkGraphNode? {
        guard let id = columnText(statement, at: 0),
              let kindRaw = columnText(statement, at: 1),
              let name = columnText(statement, at: 2),
              let qualifiedName = columnText(statement, at: 3),
              let path = columnText(statement, at: 4),
              let languageRaw = columnText(statement, at: 5),
              let decoratorsJSON = columnText(statement, at: 16) else {
            return nil
        }
        let decorators = (try? JSONDecoder().decode([String].self, from: Data(decoratorsJSON.utf8))) ?? []
        return WorkGraphNode(
            id: id,
            kind: WorkGraphNodeKind(rawValue: kindRaw) ?? .unknown,
            name: name,
            qualifiedName: qualifiedName,
            path: path,
            language: WorkGraphLanguage(rawValue: languageRaw) ?? .unknown,
            location: WorkGraphSourceLocation(
                startLine: Int(sqlite3_column_int64(statement, 6)),
                endLine: Int(sqlite3_column_int64(statement, 7)),
                startColumn: Int(sqlite3_column_int64(statement, 8)),
                endColumn: Int(sqlite3_column_int64(statement, 9))
            ),
            signature: columnText(statement, at: 10),
            visibility: columnText(statement, at: 11),
            isExported: sqlite3_column_int64(statement, 12) != 0,
            isAsync: sqlite3_column_int64(statement, 13) != 0,
            isStatic: sqlite3_column_int64(statement, 14) != 0,
            isAbstract: sqlite3_column_int64(statement, 15) != 0,
            returnType: columnText(statement, at: 17),
            decorators: decorators
        )
    }

    private func symbols(at path: String) throws -> [(name: String, location: WorkGraphSourceLocation)] {
        let statement = try prepare(
            """
            SELECT name, start_line, end_line, start_column, end_column
            FROM nodes
            WHERE file_path = ? AND kind != 'file'
            ORDER BY start_line
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(path, at: 1, to: statement)
        var symbols: [(name: String, location: WorkGraphSourceLocation)] = []
        while try nextRow(statement) {
            guard let name = columnText(statement, at: 0) else { continue }
            symbols.append(
                (
                    name: name,
                    location: WorkGraphSourceLocation(
                        startLine: Int(sqlite3_column_int64(statement, 1)),
                        endLine: Int(sqlite3_column_int64(statement, 2)),
                        startColumn: Int(sqlite3_column_int64(statement, 3)),
                        endColumn: Int(sqlite3_column_int64(statement, 4))
                    )
                )
            )
        }
        return symbols
    }

    func hasCompatibleIndex() throws -> Bool {
        guard try integer("PRAGMA user_version") == WorkGraphStore.schemaVersion,
              try hasExpectedSchema(),
              try metadataValue(for: "schema_version") == String(WorkGraphStore.schemaVersion),
              try metadataValue(for: "generated_at") != nil else {
            return false
        }
        return true
    }

    func indexedFiles() throws -> [WorkGraphFileRecord] {
        try cachedFiles()
    }

    private func migrate() throws {
        let version = try integer("PRAGMA user_version")
        guard version <= WorkGraphStore.schemaVersion else {
            throw WorkGraphStoreError.incompatibleSchema(version)
        }
        if version == WorkGraphStore.schemaVersion, try hasExpectedSchema() {
            return
        }

        // WorkGraph is a regenerable cache. Rebuilding older or incomplete schemas
        // avoids treating a partial database as verified syntax facts.
        try execute(
            """
            DROP TABLE IF EXISTS reference_occurrences;
            DROP TABLE IF EXISTS nodes_fts;
            DROP TABLE IF EXISTS edges;
            DROP TABLE IF EXISTS symbols;
            DROP TABLE IF EXISTS nodes;
            DROP TABLE IF EXISTS documents;
            DROP TABLE IF EXISTS files;
            DROP TABLE IF EXISTS metadata;

            CREATE TABLE metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            CREATE TABLE files (
                path TEXT PRIMARY KEY NOT NULL,
                content_hash TEXT NOT NULL,
                language TEXT NOT NULL,
                size INTEGER NOT NULL,
                modified_at INTEGER,
                indexed_at INTEGER NOT NULL,
                node_count INTEGER NOT NULL DEFAULT 0,
                errors_json TEXT NOT NULL,
                generated INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE nodes (
                id TEXT PRIMARY KEY NOT NULL,
                parent_id TEXT,
                kind TEXT NOT NULL,
                name TEXT NOT NULL,
                qualified_name TEXT NOT NULL,
                file_path TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE,
                language TEXT NOT NULL,
                start_line INTEGER NOT NULL,
                end_line INTEGER NOT NULL,
                start_column INTEGER NOT NULL,
                end_column INTEGER NOT NULL,
                signature TEXT,
                visibility TEXT,
                is_exported INTEGER NOT NULL DEFAULT 0,
                is_async INTEGER NOT NULL DEFAULT 0,
                is_static INTEGER NOT NULL DEFAULT 0,
                is_abstract INTEGER NOT NULL DEFAULT 0,
                decorators_json TEXT NOT NULL,
                return_type TEXT,
                updated_at INTEGER NOT NULL
            );
            CREATE INDEX nodes_name_index ON nodes(name);
            CREATE INDEX nodes_qualified_name_index ON nodes(qualified_name);
            CREATE INDEX nodes_file_line_index ON nodes(file_path, start_line);
            CREATE INDEX nodes_language_index ON nodes(language);
            CREATE VIRTUAL TABLE nodes_fts USING fts5(
                id UNINDEXED,
                name,
                qualified_name,
                signature
            );
            CREATE TABLE edges (
                id INTEGER PRIMARY KEY,
                source_node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
                target_node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                line INTEGER,
                column INTEGER,
                confidence REAL NOT NULL,
                provenance TEXT NOT NULL,
                metadata_json TEXT
            );
            CREATE INDEX edges_source_kind_index ON edges(source_node_id, kind);
            CREATE INDEX edges_target_kind_index ON edges(target_node_id, kind);
            CREATE UNIQUE INDEX edges_identity_index
                ON edges(source_node_id, target_node_id, kind, IFNULL(line, -1), IFNULL(column, -1));
            CREATE TABLE reference_occurrences (
                id INTEGER PRIMARY KEY,
                from_node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
                raw_name TEXT NOT NULL,
                relation_kind TEXT NOT NULL,
                line INTEGER NOT NULL,
                column INTEGER NOT NULL,
                candidate_names_json TEXT NOT NULL,
                file_path TEXT NOT NULL,
                language TEXT NOT NULL,
                status TEXT NOT NULL,
                resolved_target_id TEXT REFERENCES nodes(id) ON DELETE SET NULL,
                confidence REAL,
                resolver TEXT,
                name_tail TEXT NOT NULL,
                fingerprint TEXT NOT NULL UNIQUE
            );
            CREATE INDEX references_pending_index ON reference_occurrences(status, name_tail);
            CREATE INDEX references_source_index ON reference_occurrences(from_node_id);
            CREATE TABLE documents (
                path TEXT PRIMARY KEY NOT NULL REFERENCES files(path) ON DELETE CASCADE,
                terms_json TEXT NOT NULL
            );
            """
        )
        try execute("PRAGMA user_version = \(WorkGraphStore.schemaVersion)")
    }

    private func hasExpectedSchema() throws -> Bool {
        let statement = try prepare(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        )
        defer { sqlite3_finalize(statement) }
        var tableNames = Set<String>()
        while try nextRow(statement) {
            if let name = columnText(statement, at: 0) {
                tableNames.insert(name)
            }
        }
        let requiredTables: Set<String> = [
            "metadata", "files", "nodes", "nodes_fts", "edges", "reference_occurrences", "documents"
        ]
        guard requiredTables.isSubset(of: tableNames) else { return false }

        let columns = try tableColumns(named: "nodes")
        return columns.contains("parent_id")
    }

    private func tableColumns(named name: String) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(name))")
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while try nextRow(statement) {
            if let column = columnText(statement, at: 1) {
                columns.insert(column)
            }
        }
        return columns
    }

    private func integer(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard try nextRow(statement) else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw WorkGraphStoreError.database(databaseMessage)
        }
        return statement
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, sqliteTransient)
        }
        guard result == SQLITE_OK else { throw WorkGraphStoreError.database(databaseMessage) }
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw WorkGraphStoreError.database(databaseMessage)
            }
            return
        }
        try bind(value, at: index, to: statement)
    }

    private func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw WorkGraphStoreError.database(databaseMessage)
        }
    }

    private func bind(_ value: Int64?, at index: Int32, to statement: OpaquePointer) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw WorkGraphStoreError.database(databaseMessage)
            }
            return
        }
        try bind(value, at: index, to: statement)
    }

    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw WorkGraphStoreError.database(databaseMessage)
        }
    }

    private func bind(_ value: Double?, at index: Int32, to statement: OpaquePointer) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw WorkGraphStoreError.database(databaseMessage)
            }
            return
        }
        try bind(value, at: index, to: statement)
    }

    private func reset(_ statement: OpaquePointer) throws {
        guard sqlite3_reset(statement) == SQLITE_OK,
              sqlite3_clear_bindings(statement) == SQLITE_OK else {
            throw WorkGraphStoreError.database(databaseMessage)
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw WorkGraphStoreError.database(databaseMessage)
        }
    }

    private func nextRow(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw WorkGraphStoreError.database(databaseMessage)
        }
    }

    private func columnText(_ statement: OpaquePointer, at index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func columnOptionalInt(_ statement: OpaquePointer, at index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func columnOptionalInt64(_ statement: OpaquePointer, at index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private var databaseMessage: String {
        guard let handle, let message = sqlite3_errmsg(handle) else { return "未知 SQLite 错误" }
        return String(cString: message)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
