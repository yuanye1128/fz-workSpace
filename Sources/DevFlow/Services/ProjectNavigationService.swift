import CryptoKit
import Foundation

struct ProjectNavigationMetrics: Equatable {
    var sourceFileCount: Int
    var indexedSymbolCount: Int
    var indexedEdgeCount: Int

    var conciseDescription: String {
        "\(sourceFileCount) 文件 · \(indexedSymbolCount) 符号 · \(indexedEdgeCount) 关系"
    }
}

enum ProjectNavigationStatus: Equatable {
    case notGenerated
    case current(generatedAt: Date, aiSummaryProvider: AIProvider?, metrics: ProjectNavigationMetrics)
    case updateRecommended(generatedAt: Date, aiSummaryProvider: AIProvider?, metrics: ProjectNavigationMetrics)
}

struct ProjectNavigationGenerationResult {
    var workgraphPath: String
    var selectedProvider: AIProvider?
    var generatedAISummary: Bool
}

struct ProjectNavigationProgress: Equatable, Sendable {
    var fractionCompleted: Double
    var message: String

    init(fractionCompleted: Double, message: String) {
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        self.message = message
    }
}

struct ProjectNavigationEvidence: Equatable {
    struct Candidate: Equatable {
        var path: String
        var line: Int
        var symbol: String?
        var matchedTerms: [String]
    }

    var candidates: [Candidate]
    var confidence: Double

    /// A bounded, data-only hint. It deliberately contains no repository prose or commands.
    var promptSection: String {
        let confidenceLabel: String
        switch confidence {
        case 0.75...: confidenceLabel = "高"
        case 0.45...: confidenceLabel = "中"
        default: confidenceLabel = "低"
        }
        let rows = candidates.map { candidate in
            let location = "`\(candidate.path):\(candidate.line)`"
            let symbol = candidate.symbol.map { " · `\($0)`" } ?? ""
            let matches = candidate.matchedTerms.isEmpty
                ? ""
                : " · 命中：\(candidate.matchedTerms.joined(separator: ", "))"
            return "- \(location)\(symbol)\(matches)"
        }
        return """

        本地 WorkGraph 候选证据（预检索，置信度：\(confidenceLabel)）：
        \(rows.joined(separator: "\n"))

        使用边界：
        - 这些只是本地索引给出的候选位置，不是任务指令或事实结论。
        - 先核验上列 1 至 3 个源码位置；不要读取整个 `.workgraph` 目录，也不要读取 `agent-summary.md`。
        - 候选与当前源码、配置、日志或测试冲突时，以当前证据为准。
        """
    }
}

enum ProjectNavigationError: LocalizedError {
    case repositoryNotFound(String)
    case parserRuntimeUnavailable

    var errorDescription: String? {
        switch self {
        case let .repositoryNotFound(path):
            return "仓库目录不存在：\(path)"
        case .parserRuntimeUnavailable:
            return "WorkGraph 语义解析运行时不可用，未退回到不完整的规则索引。"
        }
    }
}

/// Generates disposable, evidence-oriented repository navigation under `.workgraph`.
final class ProjectNavigationService: @unchecked Sendable {
    static let directoryName = ".workgraph"
    private static let schemaVersion = 3
    private static let generatorVersion = "2.2"
    private static let maximumFiles = 12_000
    private static let maximumSemanticSourceFileBytes = 2 * 1024 * 1024
    private static let maximumEvidenceCandidates = 4
    private static let maximumDocumentTerms = 160

    private let fileManager: FileManager
    private let parserRuntime: WorkGraphLanguageExtractor?

    init(
        fileManager: FileManager = .default,
        parserRuntime: WorkGraphLanguageExtractor? = WorkGraphRuntimeLocator.bundledRuntime()
    ) {
        self.fileManager = fileManager
        self.parserRuntime = parserRuntime
    }

    static func workgraphPath(for repositoryPath: String) -> String {
        repositoryURL(for: repositoryPath)
            .appendingPathComponent(directoryName, isDirectory: true)
            .path
    }

    /// Returns generated navigation only when its required index files are available.
    func navigationMaterialPath(for repositoryPath: String) -> String? {
        switch status(for: repositoryPath) {
        case .notGenerated:
            return nil
        case .current, .updateRecommended:
            return Self.workgraphPath(for: repositoryPath)
        }
    }

    /// Creates the deterministic, local structural index without invoking an AI tool.
    @discardableResult
    func generateBaseNavigation(
        repositoryPath: String,
        progress: (@Sendable (ProjectNavigationProgress) -> Void)? = nil
    ) throws -> String {
        progress?(ProjectNavigationProgress(fractionCompleted: 0, message: "准备生成导航"))
        let repositoryURL = Self.repositoryURL(for: repositoryPath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: repositoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectNavigationError.repositoryNotFound(repositoryURL.path)
        }

        progress?(ProjectNavigationProgress(fractionCompleted: 0.08, message: "扫描项目文件"))
        let scan = scanRepository(at: repositoryURL)
        progress?(ProjectNavigationProgress(
            fractionCompleted: 0.14,
            message: "已发现 \(scan.semanticFiles.count) 个源码文件"
        ))
        let workgraphURL = repositoryURL.appendingPathComponent(Self.directoryName, isDirectory: true)
        try fileManager.createDirectory(at: workgraphURL, withIntermediateDirectories: true)
        let manifestURL = workgraphURL.appendingPathComponent("manifest.json")
        let existingManifest = readManifest(at: manifestURL)
        let databaseURL = workgraphURL.appendingPathComponent(WorkGraphStore.fileName)
        let (store, cachedIndex) = try preparedWorkGraphStore(databaseURL: databaseURL)
        let extractedIndex = try buildSemanticIndex(
            from: scan,
            repositoryURL: repositoryURL,
            cachedIndex: isCompatibleCacheManifest(existingManifest) ? cachedIndex : nil,
            progress: progress
        )
        progress?(ProjectNavigationProgress(fractionCompleted: 0.82, message: "建立代码关系"))
        let resolution = WorkGraphResolver().resolve(snapshot: extractedIndex)
        let index = WorkGraphIndexSnapshot(
            files: extractedIndex.files,
            nodes: extractedIndex.nodes,
            edges: extractedIndex.edges + resolution.edges,
            references: extractedIndex.references,
            documents: extractedIndex.documents
        )
        try excludeWorkgraphFromGit(at: repositoryURL)

        let summaryURL = workgraphURL.appendingPathComponent("agent-summary.md")
        let existingSummaryProvider = fileManager.fileExists(atPath: summaryURL.path)
            ? existingManifest?.aiSummaryProvider
            : nil

        let manifest = ProjectNavigationManifest(
            schemaVersion: Self.schemaVersion,
            generatorVersion: Self.generatorVersion,
            generatedAt: Date(),
            gitReference: gitReference(at: repositoryURL),
            sourceFileCount: scan.semanticFiles.count,
            indexedSymbolCount: index.nodes.filter { $0.kind != .file }.count,
            indexedEdgeCount: index.edges.count,
            scanTruncated: scan.isTruncated,
            fingerprints: structuralFingerprints(for: scan, repositoryURL: repositoryURL),
            aiSummaryProvider: existingSummaryProvider
        )

        progress?(ProjectNavigationProgress(fractionCompleted: 0.9, message: "写入导航索引"))
        try store.replace(index: index, resolutions: resolution.references)

        try writeOverview(scan: scan, manifest: manifest, to: workgraphURL.appendingPathComponent("overview.md"))
        try writeJSON(
            ProjectNavigationModulesDocument(
                schemaVersion: Self.schemaVersion,
                generatedAt: manifest.generatedAt,
                modules: scan.modules
            ),
            to: workgraphURL.appendingPathComponent("modules.json")
        )
        try writeJSONLines(index.nodes, to: workgraphURL.appendingPathComponent("symbols.jsonl"))
        try writeJSONLines(index.edges, to: workgraphURL.appendingPathComponent("edges.jsonl"))
        try writeJSONLines(index.documents, to: workgraphURL.appendingPathComponent("documents.jsonl"))
        try writeJSON(manifest, to: workgraphURL.appendingPathComponent("manifest.json"))
        progress?(ProjectNavigationProgress(fractionCompleted: 1, message: "导航生成完成"))
        return workgraphURL.path
    }

    /// Generates only the deterministic local index. AI prose is intentionally excluded from the task path.
    func generate(
        repositoryPath: String,
        progress: (@Sendable (ProjectNavigationProgress) -> Void)? = nil
    ) async throws -> ProjectNavigationGenerationResult {
        let workgraphPath = try await Task.detached(priority: .userInitiated) { [self] in
            try generateBaseNavigation(repositoryPath: repositoryPath, progress: progress)
        }.value
        return ProjectNavigationGenerationResult(
            workgraphPath: workgraphPath,
            selectedProvider: nil,
            generatedAISummary: false
        )
    }

    func status(for repositoryPath: String) -> ProjectNavigationStatus {
        let repositoryURL = Self.repositoryURL(for: repositoryPath)
        let manifestURL = repositoryURL
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            .appendingPathComponent("manifest.json")
        guard let manifest = readManifest(at: manifestURL), manifest.schemaVersion == Self.schemaVersion else {
            return .notGenerated
        }

        let workgraphURL = manifestURL.deletingLastPathComponent()
        let requiredFiles = ["overview.md", "modules.json", "symbols.jsonl", "edges.jsonl", "documents.jsonl"]
        guard requiredFiles.allSatisfy({ fileManager.fileExists(atPath: workgraphURL.appendingPathComponent($0).path) }) else {
            return .notGenerated
        }

        let summaryURL = workgraphURL.appendingPathComponent("agent-summary.md")
        let aiSummaryProvider = fileManager.fileExists(atPath: summaryURL.path) ? manifest.aiSummaryProvider : nil
        let metrics = ProjectNavigationMetrics(
            sourceFileCount: manifest.sourceFileCount,
            indexedSymbolCount: manifest.indexedSymbolCount,
            indexedEdgeCount: manifest.indexedEdgeCount
        )
        let current = manifest.fingerprints.map { fingerprint(for: $0, repositoryURL: repositoryURL) }
        if manifest.generatorVersion == Self.generatorVersion, current == manifest.fingerprints {
            return .current(
                generatedAt: manifest.generatedAt,
                aiSummaryProvider: aiSummaryProvider,
                metrics: metrics
            )
        }
        return .updateRecommended(
            generatedAt: manifest.generatedAt,
            aiSummaryProvider: aiSummaryProvider,
            metrics: metrics
        )
    }

    /// Performs a cheap repository-to-index comparison used by silent query
    /// catch-up. It checks the same source-file set and size/mtime facts used by
    /// incremental generation, without parsing source or reading AI prose.
    func needsRebuild(repositoryPath: String) -> Bool {
        let repositoryURL = Self.repositoryURL(for: repositoryPath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: repositoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return true
        }
        guard case .current = status(for: repositoryPath) else { return true }

        let databaseURL = repositoryURL
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            .appendingPathComponent(WorkGraphStore.fileName)
        guard fileManager.fileExists(atPath: databaseURL.path),
              let indexedFiles = try? WorkGraphStore(databaseURL: databaseURL, accessMode: .readOnly).indexedFiles() else {
            return true
        }

        let scan = scanRepository(at: repositoryURL)
        guard scan.semanticFiles.count == indexedFiles.count else { return true }
        let indexedByPath = Dictionary(uniqueKeysWithValues: indexedFiles.map { ($0.path, $0) })
        guard Set(indexedByPath.keys) == Set(scan.semanticFiles.map(\.path)) else { return true }

        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        for scanned in scan.semanticFiles {
            guard let indexed = indexedByPath[scanned.path],
                  indexed.language == WorkGraphLanguage(fileExtension: scanned.fileExtension),
                  indexed.byteCount == scanned.byteCount else {
                return true
            }
            let fileURL = repositoryURL.appendingPathComponent(scanned.path)
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true,
                  let currentModifiedAt = values.contentModificationDate,
                  let indexedModifiedAt = indexed.modifiedAt else {
                return true
            }
            let currentMilliseconds = Int64(currentModifiedAt.timeIntervalSince1970 * 1_000)
            let indexedMilliseconds = Int64(indexedModifiedAt.timeIntervalSince1970 * 1_000)
            guard currentMilliseconds == indexedMilliseconds else { return true }
        }
        return false
    }

    /// Returns a bounded, local query result instead of exposing the whole navigation directory to an Agent.
    func evidence(for repositoryPath: String, query: String) -> ProjectNavigationEvidence? {
        guard case .current = status(for: repositoryPath) else { return nil }
        let terms = Self.searchTerms(in: query)
        guard !terms.isEmpty else { return nil }

        let workgraphURL = URL(fileURLWithPath: Self.workgraphPath(for: repositoryPath), isDirectory: true)
        let databaseURL = workgraphURL.appendingPathComponent(WorkGraphStore.fileName)
        if fileManager.fileExists(atPath: databaseURL.path),
           let storedCandidates = try? WorkGraphStore(databaseURL: databaseURL).evidence(
               for: terms,
               limit: Self.maximumEvidenceCandidates * 8
           ) {
            let candidates = storedCandidates
                .filter { !WorkGraphRepositoryPath.isTestSourcePath($0.path) }
                .prefix(Self.maximumEvidenceCandidates)
                .map { candidate in
                    (
                        candidate: ProjectNavigationEvidence.Candidate(
                            path: candidate.path,
                            line: candidate.line,
                            symbol: candidate.symbol,
                            matchedTerms: candidate.matchedTerms
                        ),
                        score: candidate.score
                    )
                }
            if let evidence = navigationEvidence(from: candidates) {
                return evidence
            }
        }

        let documents: [WorkGraphDocumentRecord] = readJSONLines(from: workgraphURL.appendingPathComponent("documents.jsonl"))
            .filter { !WorkGraphRepositoryPath.isTestSourcePath($0.path) }
        let symbols: [WorkGraphNodeDraft] = readJSONLines(from: workgraphURL.appendingPathComponent("symbols.jsonl"))
        guard !documents.isEmpty else { return nil }

        let symbolsByPath = Dictionary(grouping: symbols, by: \.filePath)
        var scoredCandidates: [(candidate: ProjectNavigationEvidence.Candidate, score: Int)] = []
        for document in documents {
            var score = 0
            var matches: [String] = []
            for term in terms {
                if document.terms.contains(term) {
                    score += 3
                    matches.append(term)
                } else if term.count >= 3, document.terms.contains(where: { $0.contains(term) }) {
                    score += 1
                    matches.append(term)
                }
            }

            let matchingSymbols = (symbolsByPath[document.path] ?? []).filter { symbol in
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

            let primary = matchingSymbols.first ?? symbolsByPath[document.path]?.first
            let matchedTerms = Array(Set(matches)).sorted().prefix(3).map { $0 }
            let candidate = ProjectNavigationEvidence.Candidate(
                path: document.path,
                line: primary?.location.startLine ?? 1,
                symbol: primary?.name,
                matchedTerms: matchedTerms
            )
            scoredCandidates.append((candidate, score))
        }
        let candidates = scoredCandidates.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.candidate.path < rhs.candidate.path : lhs.score > rhs.score
        }

        return navigationEvidence(from: candidates)
    }

    private func navigationEvidence(
        from candidates: [(candidate: ProjectNavigationEvidence.Candidate, score: Int)]
    ) -> ProjectNavigationEvidence? {
        guard !candidates.isEmpty else { return nil }
        let selected = Array(candidates.prefix(Self.maximumEvidenceCandidates))
        let bestScore = selected.first?.score ?? 0
        let confidence = min(0.95, 0.25 + Double(bestScore) / 12.0)
        return ProjectNavigationEvidence(candidates: selected.map { $0.candidate }, confidence: confidence)
    }

    private func scanRepository(at repositoryURL: URL) -> ProjectNavigationScan {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: repositoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return ProjectNavigationScan.empty
        }

        var allFiles: [ProjectNavigationScannedFile] = []
        var isTruncated = false
        while let fileURL = enumerator.nextObject() as? URL {
            let values = try? fileURL.resourceValues(forKeys: resourceKeys)
            if values?.isDirectory == true {
                if Self.ignoredDirectoryNames.contains(fileURL.lastPathComponent.lowercased()) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if allFiles.count >= Self.maximumFiles {
                isTruncated = true
                break
            }

            let relativePath = relativePath(of: fileURL, from: repositoryURL)
            allFiles.append(
                ProjectNavigationScannedFile(
                    path: relativePath,
                    fileExtension: fileURL.pathExtension.lowercased(),
                    byteCount: values?.fileSize ?? 0
                )
            )
        }

        let markerFiles = allFiles.filter { Self.technologyMarker(for: $0.path) != nil }
        let candidateSourceFiles = allFiles.filter { file in
            Self.language(for: file.fileExtension) != nil && !markerFiles.contains(where: { $0.path == file.path })
        }
        let testFiles = candidateSourceFiles.filter { Self.isTestSource($0.path) }
        let sourceFiles = candidateSourceFiles.filter { !Self.isTestSource($0.path) }
        let semanticFiles = (sourceFiles + testFiles).sorted { $0.path < $1.path }
        let sourceRoots = Set(sourceFiles.compactMap { Self.sourceRoot(for: $0.path) })
        let testRoots = Set(testFiles.compactMap { Self.testRoot(for: $0.path) })
        let entryPaths = sourceFiles.compactMap { file -> String? in
            Self.isEntryCandidate(file.path) ? file.path : nil
        }
        let routePaths = sourceFiles.compactMap { file -> String? in
            Self.isRouteCandidate(file.path) ? file.path : nil
        }

        var technologies = Set(markerFiles.compactMap { Self.technologyMarker(for: $0.path) })
        technologies.formUnion(sourceFiles.compactMap { Self.language(for: $0.fileExtension) })
        let modules = modules(for: sourceFiles, testRoots: testRoots)

        return ProjectNavigationScan(
            markerPaths: markerFiles.map(\.path).sorted(),
            technologies: technologies.sorted(),
            sourceFiles: sourceFiles.sorted { $0.path < $1.path },
            semanticFiles: semanticFiles,
            sourceRoots: sourceRoots.sorted(),
            testRoots: testRoots.sorted(),
            entryPaths: entryPaths.sorted(),
            routePaths: routePaths.sorted(),
            modules: modules,
            isTruncated: isTruncated
        )
    }

    private func modules(
        for sourceFiles: [ProjectNavigationScannedFile],
        testRoots: Set<String>
    ) -> [ProjectNavigationModule] {
        var grouped: [String: [ProjectNavigationScannedFile]] = [:]
        for file in sourceFiles where Self.testRoot(for: file.path) == nil {
            let sourceRoot = Self.sourceRoot(for: file.path) ?? "."
            let modulePath = Self.modulePath(for: file.path, sourceRoot: sourceRoot)
            grouped[modulePath, default: []].append(file)
        }

        return grouped.keys.sorted().map { path in
            let files = grouped[path, default: []].sorted { $0.path < $1.path }
            return ProjectNavigationModule(
                path: path,
                sourceFileCount: files.count,
                languages: Set(files.compactMap { Self.language(for: $0.fileExtension) }).sorted(),
                sampleFiles: Array(files.prefix(8).map(\.path)),
                testRoots: testRoots.sorted()
            )
        }
    }

    /// Builds syntax facts with the bundled parser. This intentionally has no
    /// regex fallback: a missing runtime must be visible rather than creating a
    /// database that looks semantic but only contains shallow guesses.
    private func buildSemanticIndex(
        from scan: ProjectNavigationScan,
        repositoryURL: URL,
        cachedIndex: WorkGraphIndexSnapshot?,
        progress: (@Sendable (ProjectNavigationProgress) -> Void)? = nil
    ) throws -> WorkGraphIndexSnapshot {
        var files: [WorkGraphFileRecord] = []
        var parserInputs: [WorkGraphSourceFile] = []
        var bridgeSources: [WorkGraphSourceFile] = []
        var retainedNodes: [WorkGraphNodeDraft] = []
        var retainedEdges: [WorkGraphEdgeDraft] = []
        var retainedReferences: [WorkGraphReferenceDraft] = []
        var retainedDocuments: [WorkGraphDocumentRecord] = []
        var reusedPaths = Set<String>()

        let cachedFilesByPath = cachedIndex.map {
            Dictionary(uniqueKeysWithValues: $0.files.map { ($0.path, $0) })
        } ?? [:]
        let cachedNodesByPath = cachedIndex.map {
            Dictionary(grouping: $0.nodes, by: \.filePath)
        } ?? [:]
        let cachedNodePathsByID = cachedIndex.map {
            Dictionary(uniqueKeysWithValues: $0.nodes.map { ($0.id, $0.filePath) })
        } ?? [:]
        let cachedEdgesBySourcePath = Dictionary(grouping: cachedIndex?.edges ?? []) { edge in
            cachedNodePathsByID[edge.sourceID] ?? ""
        }
        let cachedReferencesByPath = cachedIndex.map {
            Dictionary(grouping: $0.references, by: \.filePath)
        } ?? [:]
        let cachedDocumentsByPath = cachedIndex.map {
            Dictionary(grouping: $0.documents, by: \.path)
        } ?? [:]

        var processedSourceCount = 0
        let sourceFileTotal = max(scan.semanticFiles.count, 1)
        for scanned in scan.semanticFiles {
            defer {
                processedSourceCount += 1
                let fraction = min(
                    0.3,
                    0.14 + 0.16 * Double(processedSourceCount) / Double(sourceFileTotal)
                )
                progress?(ProjectNavigationProgress(
                    fractionCompleted: fraction,
                    message: "读取源码 \(processedSourceCount)/\(scan.semanticFiles.count)"
                ))
            }
            let fileURL = repositoryURL.appendingPathComponent(scanned.path)
            let language = WorkGraphLanguage(fileExtension: scanned.fileExtension)
            let modifiedAt = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            var record = WorkGraphFileRecord(
                path: scanned.path,
                contentHash: "unreadable:\(scanned.path):\(scanned.byteCount)",
                language: language,
                byteCount: scanned.byteCount,
                modifiedAt: modifiedAt,
                isGenerated: Self.isLikelyGenerated(scanned.path),
                diagnostics: []
            )

            guard language.supportsSemanticExtraction else {
                files.append(record)
                continue
            }
            guard scanned.byteCount <= Self.maximumSemanticSourceFileBytes else {
                record.diagnostics.append("源文件超过 \(Self.maximumSemanticSourceFileBytes) 字节，未进行语义解析。")
                files.append(record)
                continue
            }
            guard let sourceData = try? Data(contentsOf: fileURL),
                  let source = String(data: sourceData, encoding: .utf8) else {
                record.diagnostics.append("无法以 UTF-8 读取源文件，未进行语义解析。")
                files.append(record)
                continue
            }

            record.contentHash = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
            files.append(record)
            bridgeSources.append(WorkGraphSourceFile(record: record, source: source))
            if let cachedRecord = cachedFilesByPath[record.path],
               isReusableCachedRecord(cachedRecord, for: record) {
                reusedPaths.insert(record.path)
                // Bridge handlers are derived from the full current source set
                // below. Never retain them from a previous run, or removed
                // literal contracts could survive an incremental generation.
                retainedNodes.append(contentsOf: (cachedNodesByPath[record.path] ?? []).filter {
                    $0.kind != .bridgeHandler
                })
                retainedEdges.append(contentsOf: cachedEdgesBySourcePath[record.path] ?? [])
                retainedReferences.append(contentsOf: cachedReferencesByPath[record.path] ?? [])
                retainedDocuments.append(contentsOf: cachedDocumentsByPath[record.path] ?? [])
                continue
            }
            parserInputs.append(WorkGraphSourceFile(record: record, source: source))
        }

        let extractions: [WorkGraphExtraction]
        if parserInputs.isEmpty {
            extractions = []
        } else {
            guard let parserRuntime else { throw ProjectNavigationError.parserRuntimeUnavailable }
            if let processRuntime = parserRuntime as? WorkGraphParserProcessRuntime {
                extractions = try processRuntime.extract(files: parserInputs) { completed, total in
                    let ratio = total == 0 ? 1 : Double(completed) / Double(total)
                    progress?(ProjectNavigationProgress(
                        fractionCompleted: 0.3 + 0.5 * ratio,
                        message: "解析代码 \(completed)/\(total)"
                    ))
                }
            } else {
                var results: [WorkGraphExtraction] = []
                results.reserveCapacity(parserInputs.count)
                for (index, input) in parserInputs.enumerated() {
                    results.append(try parserRuntime.extract(file: input))
                    let completed = index + 1
                    progress?(ProjectNavigationProgress(
                        fractionCompleted: 0.3 + 0.5 * Double(completed) / Double(parserInputs.count),
                        message: "解析代码 \(completed)/\(parserInputs.count)"
                    ))
                }
                extractions = results
            }
        }
        progress?(ProjectNavigationProgress(fractionCompleted: 0.8, message: "整理解析结果"))

        let diagnosticsByPath = Dictionary(uniqueKeysWithValues: extractions.map { ($0.file.path, $0.file.diagnostics) })
        files = files.map { record in
            var record = record
            if let diagnostics = diagnosticsByPath[record.path] {
                record.diagnostics = diagnostics
            } else if reusedPaths.contains(record.path) {
                record.diagnostics = cachedFilesByPath[record.path]?.diagnostics ?? []
            }
            return record
        }

        var nodes = retainedNodes + extractions.flatMap(\.nodes)
        var edges = retainedEdges + extractions.flatMap(\.edges)
        let references = retainedReferences + extractions.flatMap(\.references)
        var documents = retainedDocuments + extractions.flatMap(\.documents)
        let existingFileNodes = Set(nodes.filter { $0.kind == .file }.map(\.filePath))
        for record in files where !existingFileNodes.contains(record.path) {
            nodes.append(
                WorkGraphNodeDraft(
                    id: Self.fileNodeID(for: record.path),
                    parentID: nil,
                    kind: .file,
                    name: record.path,
                    qualifiedName: record.path,
                    filePath: record.path,
                    language: record.language,
                    location: .unknown,
                    signature: nil,
                    visibility: nil,
                    isExported: false,
                    isAsync: false,
                    isStatic: false,
                    isAbstract: false,
                    returnType: nil,
                    decorators: []
                )
            )
        }

        let availableNodeIDs = Set(nodes.map(\.id))
        edges.removeAll { !availableNodeIDs.contains($0.sourceID) || !availableNodeIDs.contains($0.targetID) }

        let indexedDocuments = Set(documents.map(\.path))
        for record in files where !indexedDocuments.contains(record.path) {
            documents.append(WorkGraphDocumentRecord(path: record.path, terms: Self.indexTerms(in: record.path)))
        }

        nodes.sort { $0.id < $1.id }
        edges.sort {
            if $0.sourceID != $1.sourceID { return $0.sourceID < $1.sourceID }
            if $0.targetID != $1.targetID { return $0.targetID < $1.targetID }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        documents.sort { $0.path < $1.path }
        let syntaxSnapshot = WorkGraphIndexSnapshot(
            files: files.sorted { $0.path < $1.path },
            nodes: nodes,
            edges: edges,
            references: references.sorted { $0.fingerprint < $1.fingerprint },
            documents: documents
        )
        let bridgeResolution = WorkGraphBridgeResolver().resolve(
            snapshot: syntaxSnapshot,
            sources: bridgeSources
        )
        nodes.append(contentsOf: bridgeResolution.nodes)
        edges.append(contentsOf: bridgeResolution.edges)
        nodes.sort { $0.id < $1.id }
        edges.sort {
            if $0.sourceID != $1.sourceID { return $0.sourceID < $1.sourceID }
            if $0.targetID != $1.targetID { return $0.targetID < $1.targetID }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        return WorkGraphIndexSnapshot(
            files: files.sorted { $0.path < $1.path },
            nodes: nodes,
            edges: edges,
            references: references.sorted { $0.fingerprint < $1.fingerprint },
            documents: documents
        )
    }

    private func isReusableCachedRecord(
        _ cached: WorkGraphFileRecord,
        for current: WorkGraphFileRecord
    ) -> Bool {
        cached.contentHash == current.contentHash &&
            cached.language == current.language &&
            cached.byteCount == current.byteCount &&
            cached.isGenerated == current.isGenerated
    }

    private func isCompatibleCacheManifest(_ manifest: ProjectNavigationManifest?) -> Bool {
        manifest?.schemaVersion == Self.schemaVersion && manifest?.generatorVersion == Self.generatorVersion
    }

    private func preparedWorkGraphStore(
        databaseURL: URL
    ) throws -> (store: WorkGraphStore, cachedIndex: WorkGraphIndexSnapshot?) {
        let store = WorkGraphStore(databaseURL: databaseURL)
        do {
            return (store, try store.cachedSyntaxSnapshot())
        } catch WorkGraphStoreError.incompatibleSchema {
            // The database is a derived cache. Clearing only its SQLite files is
            // safer than keeping a newer incompatible graph beside fresh JSON artifacts.
            try discardWorkGraphCache(at: databaseURL)
            return (WorkGraphStore(databaseURL: databaseURL), nil)
        } catch {
            // A readable database with incomplete metadata or malformed cache
            // facts will be atomically replaced after a full extraction.
            return (store, nil)
        }
    }

    private func discardWorkGraphCache(at databaseURL: URL) throws {
        let cacheFiles = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
        for url in cacheFiles where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func structuralFingerprints(
        for scan: ProjectNavigationScan,
        repositoryURL: URL
    ) -> [ProjectNavigationFingerprint] {
        let watchedFiles = Set(scan.markerPaths + scan.entryPaths + scan.routePaths)
        let fileFingerprints = watchedFiles.sorted().map {
            fingerprint(
                path: $0,
                kind: .file,
                repositoryURL: repositoryURL
            )
        }
        let rootFingerprints = Set(scan.sourceRoots + scan.testRoots).sorted().map {
            fingerprint(
                path: $0,
                kind: .directory,
                repositoryURL: repositoryURL
            )
        }
        return fileFingerprints + rootFingerprints
    }

    private func fingerprint(
        for existing: ProjectNavigationFingerprint,
        repositoryURL: URL
    ) -> ProjectNavigationFingerprint {
        fingerprint(path: existing.path, kind: existing.kind, repositoryURL: repositoryURL)
    }

    private func fingerprint(
        path: String,
        kind: ProjectNavigationFingerprint.Kind,
        repositoryURL: URL
    ) -> ProjectNavigationFingerprint {
        let url = path == "." ? repositoryURL : repositoryURL.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return ProjectNavigationFingerprint(path: path, kind: kind, exists: false, modifiedAt: nil, byteCount: nil, childDirectories: [])
        }

        switch kind {
        case .file:
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return ProjectNavigationFingerprint(
                path: path,
                kind: kind,
                exists: !isDirectory.boolValue,
                modifiedAt: values?.contentModificationDate,
                byteCount: values?.fileSize,
                childDirectories: []
            )
        case .directory:
            let directories = (try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ))?.compactMap { child -> String? in
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true,
                      !Self.ignoredDirectoryNames.contains(child.lastPathComponent.lowercased()) else { return nil }
                return child.lastPathComponent
            }.sorted() ?? []
            return ProjectNavigationFingerprint(
                path: path,
                kind: kind,
                exists: isDirectory.boolValue,
                modifiedAt: nil,
                byteCount: nil,
                childDirectories: directories
            )
        }
    }

    private func excludeWorkgraphFromGit(at repositoryURL: URL) throws {
        guard let gitDirectory = gitDirectory(at: repositoryURL) else { return }
        let infoDirectory = gitDirectory.appendingPathComponent("info", isDirectory: true)
        try fileManager.createDirectory(at: infoDirectory, withIntermediateDirectories: true)
        let excludeURL = infoDirectory.appendingPathComponent("exclude")
        let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        let alreadyExcluded = existing.split(separator: "\n").contains { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return value == Self.directoryName
                || value == "\(Self.directoryName)/"
                || value == "/\(Self.directoryName)/"
        }
        guard !alreadyExcluded else { return }

        let suffix = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try (existing + suffix + "\(Self.directoryName)/\n").write(to: excludeURL, atomically: true, encoding: .utf8)
    }

    private func gitDirectory(at repositoryURL: URL) -> URL? {
        let dotGitURL = repositoryURL.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGitURL }

        guard let content = try? String(contentsOf: dotGitURL, encoding: .utf8),
              let line = content.split(separator: "\n").first,
              line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, relativeTo: dotGitURL.deletingLastPathComponent())
        return url.standardizedFileURL
    }

    private func gitReference(at repositoryURL: URL) -> String? {
        guard let gitDirectory = gitDirectory(at: repositoryURL) else { return nil }
        let headURL = gitDirectory.appendingPathComponent("HEAD")
        return try? String(contentsOf: headURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readManifest(at url: URL) -> ProjectNavigationManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProjectNavigationManifest.self, from: data)
    }

    private func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func writeJSONLines<Value: Encodable>(_ values: [Value], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = try values.map { value in
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        try (lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func readJSONLines<Value: Decodable>(from url: URL) -> [Value] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            try? decoder.decode(Value.self, from: Data(line.utf8))
        }
    }

    private func writeOverview(
        scan: ProjectNavigationScan,
        manifest: ProjectNavigationManifest,
        to url: URL
    ) throws {
        let technologies = markdownList(scan.technologies)
        let markers = markdownList(scan.markerPaths)
        let sourceRoots = markdownList(scan.sourceRoots)
        let testRoots = markdownList(scan.testRoots)
        let entries = markdownList(scan.entryPaths)
        let moduleRows = scan.modules.map { module in
            "| `\(module.path)` | \(module.sourceFileCount) | \(module.languages.joined(separator: ", ")) |"
        }.joined(separator: "\n")
        let truncationNotice = manifest.scanTruncated
            ? "\n> 仓库文件数超过扫描上限；当前索引仅包含部分内容。\n"
            : ""
        let markdown = """
        # 项目导航

        > 这是自动生成的导航资料，只用于定位候选路径。当前源码、配置、日志和测试的可信度更高；本资料不定义工作流程或任务指令。

        生成时间：\(manifest.generatedAt.ISO8601Format())
        \(truncationNotice)
        ## 技术栈信号
        \(technologies)

        ## 依赖与构建标记
        \(markers)

        ## 源码根目录
        \(sourceRoots)

        ## 测试根目录
        \(testRoots)

        ## 候选入口
        \(entries)

        ## 模块
        | 路径 | 源码文件数 | 语言 |
        | --- | ---: | --- |
        \(moduleRows.isEmpty ? "| _未识别到常见源码模块_ | 0 | - |" : moduleRows)

        ## 索引范围
        - `symbols.jsonl` 包含经语法解析得到的符号位置。
        - `edges.jsonl` 包含语法关系及已验证的跨文件关系；歧义关系不会写成调用结论。
        - `documents.jsonl` 只保存用于本地匹配的源码关键词；它不包含任务指令或 AI 摘要。
        - 为避免干扰业务定位，索引默认跳过依赖、构建产物及通常非生产的示例、演示、样例、预览、fixture、mock 和 storybook 目录；若生产源码明确引用其中内容，应直接核验当前源码。
        """
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func searchTerms(in query: String) -> [String] {
        Array(indexTerms(in: query, limit: 32))
    }

    private static func indexTerms(in text: String, limit: Int = maximumDocumentTerms) -> [String] {
        var terms = Set<String>()
        var current = ""

        func appendCurrent() {
            defer { current = "" }
            let value = current.lowercased()
            guard !value.isEmpty else { return }
            if value.unicodeScalars.allSatisfy({ $0.isASCII }) {
                guard value.count >= 3 else { return }
                terms.insert(value)
                return
            }
            let characters = Array(value)
            guard characters.count >= 2 else { return }
            for length in 2...min(4, characters.count) {
                for start in 0...(characters.count - length) {
                    terms.insert(String(characters[start..<(start + length)]))
                    if terms.count >= limit { return }
                }
            }
        }

        for character in text {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                appendCurrent()
                if terms.count >= limit { break }
            }
        }
        if terms.count < limit { appendCurrent() }
        return terms.sorted().prefix(limit).map { $0 }
    }

    private func markdownList(_ values: [String]) -> String {
        guard !values.isEmpty else { return "- _未检测到_" }
        return values.map { "- `\($0)`" }.joined(separator: "\n")
    }

    private func relativePath(of url: URL, from root: URL) -> String {
        let canonicalURL = url.resolvingSymlinksInPath()
        let canonicalRoot = root.resolvingSymlinksInPath()
        let rootPath = canonicalRoot.path.hasSuffix("/") ? String(canonicalRoot.path.dropLast()) : canonicalRoot.path
        guard canonicalURL.path.hasPrefix(rootPath + "/") else { return canonicalURL.lastPathComponent }
        return String(canonicalURL.path.dropFirst(rootPath.count + 1))
    }

    private static func repositoryURL(for path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private static func fileNodeID(for path: String) -> String {
        "file:\(path)"
    }

    private static func symbolNodeID(path: String, kind: String, name: String, line: Int) -> String {
        "symbol:\(path):\(kind):\(name):\(line)"
    }

    private static func sourceRoot(for path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return "." }
        for index in components.indices.dropLast() where sourceDirectoryNames.contains(components[index].lowercased()) {
            return components[0...index].joined(separator: "/")
        }
        return "."
    }

    private static func testRoot(for path: String) -> String? {
        WorkGraphRepositoryPath.testRoot(for: path)
    }

    private static func isTestSource(_ path: String) -> Bool {
        WorkGraphRepositoryPath.isTestSourcePath(path)
    }

    private static func modulePath(for path: String, sourceRoot: String) -> String {
        guard sourceRoot != "." else { return "." }
        let components = path.split(separator: "/").map(String.init)
        let rootCount = sourceRoot.split(separator: "/").count
        guard components.count > rootCount + 1 else { return sourceRoot }
        return (sourceRoot.split(separator: "/").map(String.init) + [components[rootCount]])
            .joined(separator: "/")
    }

    private static func language(for fileExtension: String) -> String? {
        sourceLanguages[fileExtension]
    }

    private static func technologyMarker(for path: String) -> String? {
        let fileName = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return technologyMarkers[fileName]
    }

    private static func isEntryCandidate(_ path: String) -> Bool {
        let fileName = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return entryFileNames.contains(fileName)
    }

    private static func isRouteCandidate(_ path: String) -> Bool {
        let fileName = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return fileName.contains("route") || fileName.contains("router") || fileName.contains("navigation")
    }

    private static func isLikelyGenerated(_ path: String) -> Bool {
        let lowered = path.lowercased()
        let fileName = URL(fileURLWithPath: lowered).lastPathComponent
        return lowered.contains("/generated/") ||
            lowered.contains("/autogenerated/") ||
            fileName.hasSuffix(".g.dart") ||
            fileName.hasSuffix(".freezed.dart") ||
            fileName.hasSuffix(".generated.swift")
    }

    private static let ignoredDirectoryNames: Set<String> = [
        ".git", directoryName, ".build", ".dart_tool", ".gradle", ".next", ".swiftpm",
        ".turbo", ".venv", "build", "coverage", "deriveddata", "dist", "node_modules",
        "pods", "target", "vendor", "venv", "__pycache__",
        "demo", "demos", "example", "examples", "fixture", "fixtures", "mock", "mocks",
        "playground", "playgrounds", "preview", "previews", "sample", "samples", "storybook"
    ]

    private static let sourceDirectoryNames: Set<String> = [
        "app", "lib", "packages", "source", "sources", "src"
    ]

    private static let sourceLanguages: [String: String] = [
        "c": "C",
        "cc": "C++",
        "cpp": "C++",
        "cs": "C#",
        "dart": "Dart",
        "ets": "ArkTS",
        "go": "Go",
        "h": "C/C++",
        "hpp": "C++",
        "java": "Java",
        "js": "JavaScript",
        "jsx": "JavaScript",
        "kt": "Kotlin",
        "kts": "Kotlin",
        "m": "Objective-C",
        "mm": "Objective-C++",
        "php": "PHP",
        "py": "Python",
        "rb": "Ruby",
        "rs": "Rust",
        "scala": "Scala",
        "sh": "Shell",
        "sql": "SQL",
        "swift": "Swift",
        "ts": "TypeScript",
        "tsx": "TypeScript",
        "vue": "Vue"
    ]

    private static let technologyMarkers: [String: String] = [
        "build.gradle": "Gradle",
        "build.gradle.kts": "Gradle",
        "cargo.toml": "Rust",
        "composer.json": "PHP",
        "gemfile": "Ruby",
        "go.mod": "Go",
        "package.json": "Node.js",
        "package.swift": "Swift Package Manager",
        "pnpm-workspace.yaml": "Node.js",
        "pom.xml": "Maven",
        "pubspec.yaml": "Flutter/Dart",
        "pyproject.toml": "Python",
        "requirements.txt": "Python",
        "settings.gradle": "Gradle",
        "settings.gradle.kts": "Gradle"
    ]

    private static let entryFileNames: Set<String> = [
        "app.dart", "app.swift", "index.js", "index.ts", "main.dart", "main.go", "main.py",
        "main.swift", "main.ts", "main.tsx", "manage.py", "program.cs"
    ]

}

private struct ProjectNavigationManifest: Codable {
    var schemaVersion: Int
    var generatorVersion: String
    var generatedAt: Date
    var gitReference: String?
    var sourceFileCount: Int
    var indexedSymbolCount: Int
    var indexedEdgeCount: Int
    var scanTruncated: Bool
    var fingerprints: [ProjectNavigationFingerprint]
    var aiSummaryProvider: AIProvider?
}

private struct ProjectNavigationScan {
    var markerPaths: [String]
    var technologies: [String]
    var sourceFiles: [ProjectNavigationScannedFile]
    var semanticFiles: [ProjectNavigationScannedFile]
    var sourceRoots: [String]
    var testRoots: [String]
    var entryPaths: [String]
    var routePaths: [String]
    var modules: [ProjectNavigationModule]
    var isTruncated: Bool

    static let empty = ProjectNavigationScan(
        markerPaths: [],
        technologies: [],
        sourceFiles: [],
        semanticFiles: [],
        sourceRoots: [],
        testRoots: [],
        entryPaths: [],
        routePaths: [],
        modules: [],
        isTruncated: false
    )
}

private struct ProjectNavigationScannedFile {
    var path: String
    var fileExtension: String
    var byteCount: Int
}

private struct ProjectNavigationModulesDocument: Codable {
    var schemaVersion: Int
    var generatedAt: Date
    var modules: [ProjectNavigationModule]
}

private struct ProjectNavigationModule: Codable {
    var path: String
    var sourceFileCount: Int
    var languages: [String]
    var sampleFiles: [String]
    var testRoots: [String]
}

private struct ProjectNavigationFingerprint: Codable, Equatable {
    enum Kind: String, Codable {
        case file
        case directory
    }

    var path: String
    var kind: Kind
    var exists: Bool
    var modifiedAt: Date?
    var byteCount: Int?
    var childDirectories: [String]
}
