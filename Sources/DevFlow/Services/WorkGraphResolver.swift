import Foundation

/// Resolves only exact, unambiguous references already extracted from source.
///
/// Resolution is intentionally limited to same-language symbols. Cross-language
/// links require an explicit bridge resolver so a coincidental shared name cannot
/// become a false call edge.
struct WorkGraphResolver {
    private static let resolverName = "conservative-exact"

    func resolve(snapshot: WorkGraphIndexSnapshot) -> WorkGraphResolutionResult {
        let nodesByID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        let resolvedImports = resolveImports(
            in: snapshot.references,
            nodes: snapshot.nodes,
            nodesByID: nodesByID
        )
        let importScopeByPath = importScope(
            existingEdges: snapshot.edges,
            resolvedImportEdges: resolvedImports.edges,
            nodesByID: nodesByID
        )

        var generatedEdges = resolvedImports.edges
        var resolutions = resolvedImports.references

        for reference in snapshot.references where reference.kind != .imports {
            let outcome = resolve(
                reference: reference,
                nodes: snapshot.nodes,
                nodesByID: nodesByID,
                importScopeByPath: importScopeByPath
            )
            resolutions.append(outcome.resolution)
            if let edge = outcome.edge {
                generatedEdges.append(edge)
            }
        }

        return WorkGraphResolutionResult(
            edges: deduplicated(generatedEdges),
            references: resolutions.sorted { $0.fingerprint < $1.fingerprint }
        )
    }

    private func resolveImports(
        in references: [WorkGraphReferenceDraft],
        nodes: [WorkGraphNodeDraft],
        nodesByID: [String: WorkGraphNodeDraft]
    ) -> WorkGraphResolutionResult {
        var edges: [WorkGraphEdgeDraft] = []
        var resolutions: [WorkGraphReferenceResolution] = []
        let fileNodes = nodes.filter { $0.kind == .file }

        for reference in references where reference.kind == .imports {
            guard let source = nodesByID[reference.fromNodeID], source.filePath == reference.filePath else {
                resolutions.append(failed(reference))
                continue
            }

            let matches = importMatches(
                for: reference,
                sourcePath: source.filePath,
                in: fileNodes
            )
            switch matches.count {
            case 1:
                guard let target = matches.first else { continue }
                edges.append(edge(from: reference, to: target, confidence: 0.99))
                resolutions.append(resolved(reference, target: target, confidence: 0.99))
            case 0:
                resolutions.append(failed(reference))
            default:
                resolutions.append(ambiguous(reference))
            }
        }

        return WorkGraphResolutionResult(edges: edges, references: resolutions)
    }

    /// Resolves a source import to a file only when its path has one exact,
    /// repository-local interpretation. This is deliberately separate from
    /// symbol resolution: package and relative paths are file contracts, not
    /// name guesses.
    private func importMatches(
        for reference: WorkGraphReferenceDraft,
        sourcePath: String,
        in fileNodes: [WorkGraphNodeDraft]
    ) -> [WorkGraphNodeDraft] {
        let importNames = names(for: reference)
        var candidatePaths = Set<String>()

        for importName in importNames {
            candidatePaths.formUnion(importPathCandidates(
                for: importName,
                sourcePath: sourcePath,
                language: reference.language
            ))
        }

        let directMatches = fileNodes.filter { candidatePaths.contains($0.filePath) }
        let packageMatches = importNames.flatMap { importName in
            packageImportMatches(importName, in: fileNodes)
        }
        let matches = directMatches + packageMatches
        return Array(Dictionary(grouping: matches, by: \.id).compactMap { $0.value.first })
            .sorted { $0.id < $1.id }
    }

    private func importPathCandidates(
        for rawName: String,
        sourcePath: String,
        language: WorkGraphLanguage
    ) -> Set<String> {
        let importName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !importName.isEmpty,
              !importName.hasPrefix("dart:"),
              !importName.hasPrefix("http:"),
              !importName.hasPrefix("https:") else {
            return []
        }

        var paths: Set<String> = [importName]
        if importName.hasPrefix("./") || importName.hasPrefix("../") {
            paths.insert(joinRelativePath(importName, toDirectoryOf: sourcePath))
        } else if !importName.contains(":") {
            // Java/Kotlin-style fully-qualified imports can only resolve to an
            // exact source path. Suffix matches are handled separately and
            // require uniqueness.
            paths.insert(importName.replacingOccurrences(of: ".", with: "/"))
        }

        let extensionCandidates = sourceExtensions(for: language)
        let withoutExtension = paths.filter { URL(fileURLWithPath: $0).pathExtension.isEmpty }
        for path in withoutExtension {
            for fileExtension in extensionCandidates {
                paths.insert("\(path).\(fileExtension)")
            }
        }
        return paths
    }

    private func packageImportMatches(
        _ rawName: String,
        in fileNodes: [WorkGraphNodeDraft]
    ) -> [WorkGraphNodeDraft] {
        guard rawName.hasPrefix("package:") else { return [] }
        let components = rawName.dropFirst("package:".count).split(separator: "/", maxSplits: 1)
        guard components.count == 2 else { return [] }
        let packageName = String(components[0])
        let relativePath = String(components[1])
        let direct = [
            "lib/\(relativePath)",
            "packages/\(packageName)/lib/\(relativePath)"
        ]
        let suffix = "/lib/\(relativePath)"
        return fileNodes.filter {
            direct.contains($0.filePath) || $0.filePath.hasSuffix(suffix)
        }
    }

    private func joinRelativePath(_ path: String, toDirectoryOf sourcePath: String) -> String {
        var components = sourcePath.split(separator: "/").dropLast().map(String.init)
        for component in path.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(component))
            }
        }
        return components.joined(separator: "/")
    }

    private func sourceExtensions(for language: WorkGraphLanguage) -> [String] {
        switch language {
        case .dart: return ["dart"]
        case .swift: return ["swift"]
        case .objectiveC: return ["h", "m", "mm"]
        case .kotlin: return ["kt", "kts", "java"]
        case .java: return ["java"]
        case .c: return ["h", "c"]
        case .cpp: return ["h", "hpp", "hh", "cc", "cpp", "cxx"]
        case .arkTS: return ["ets"]
        case .unknown: return []
        }
    }

    private func resolve(
        reference: WorkGraphReferenceDraft,
        nodes: [WorkGraphNodeDraft],
        nodesByID: [String: WorkGraphNodeDraft],
        importScopeByPath: [String: Set<String>]
    ) -> (edge: WorkGraphEdgeDraft?, resolution: WorkGraphReferenceResolution) {
        guard let source = nodesByID[reference.fromNodeID], source.filePath == reference.filePath else {
            return (nil, failed(reference))
        }

        let names = names(for: reference)
        let eligibleNodes = nodes.filter {
            $0.kind != .file && $0.language == reference.language && isEligible($0, for: reference.kind)
        }

        let sameFileMatches = exactMatches(
            names: names,
            in: eligibleNodes.filter { $0.filePath == source.filePath }
        )
        if !sameFileMatches.isEmpty {
            return outcome(reference: reference, matches: sameFileMatches, confidence: 0.99)
        }

        let importedPaths = importScopeByPath[source.filePath] ?? []
        let importedMatches = exactMatches(
            names: names,
            in: eligibleNodes.filter { importedPaths.contains($0.filePath) }
        )
        if !importedMatches.isEmpty {
            return outcome(reference: reference, matches: importedMatches, confidence: 0.95)
        }

        let repositoryMatches = exactMatches(names: names, in: eligibleNodes)
        return outcome(reference: reference, matches: repositoryMatches, confidence: 0.85)
    }

    private func importScope(
        existingEdges: [WorkGraphEdgeDraft],
        resolvedImportEdges: [WorkGraphEdgeDraft],
        nodesByID: [String: WorkGraphNodeDraft]
    ) -> [String: Set<String>] {
        var paths: [String: Set<String>] = [:]
        for edge in (existingEdges + resolvedImportEdges) where edge.kind == .imports {
            guard let source = nodesByID[edge.sourceID],
                  let target = nodesByID[edge.targetID] else {
                continue
            }
            let sourcePath = source.filePath
            let targetPath = target.filePath
            paths[sourcePath, default: []].insert(targetPath)
        }
        return paths
    }

    private func names(for reference: WorkGraphReferenceDraft) -> Set<String> {
        Set([reference.rawName] + reference.candidateNames).filter { !$0.isEmpty }
    }

    private func exactMatches(
        names: Set<String>,
        in nodes: [WorkGraphNodeDraft]
    ) -> [WorkGraphNodeDraft] {
        guard !names.isEmpty else { return [] }
        let matches = nodes.filter { names.contains($0.name) || names.contains($0.qualifiedName) }
        return Array(Dictionary(grouping: matches, by: \.id).compactMap { $0.value.first })
            .sorted { $0.id < $1.id }
    }

    private func isEligible(_ node: WorkGraphNodeDraft, for kind: WorkGraphEdgeKind) -> Bool {
        switch kind {
        case .calls:
            return [.function, .method, .bridgeHandler].contains(node.kind)
        case .extends, .implements, .typeOf, .returns, .instantiates:
            return [.class, .struct, .interface, .protocol, .enumeration, .typeAlias].contains(node.kind)
        case .overrides:
            return [.function, .method].contains(node.kind)
        case .imports:
            return node.kind == .file
        case .contains, .exports, .references, .decorates:
            return node.kind != .file
        case .bridgeInvokes:
            return false
        }
    }

    private func outcome(
        reference: WorkGraphReferenceDraft,
        matches: [WorkGraphNodeDraft],
        confidence: Double
    ) -> (edge: WorkGraphEdgeDraft?, resolution: WorkGraphReferenceResolution) {
        switch matches.count {
        case 1:
            guard let target = matches.first else { return (nil, failed(reference)) }
            return (
                edge(from: reference, to: target, confidence: confidence),
                resolved(reference, target: target, confidence: confidence)
            )
        case 0:
            return (nil, failed(reference))
        default:
            return (nil, ambiguous(reference))
        }
    }

    private func edge(
        from reference: WorkGraphReferenceDraft,
        to target: WorkGraphNodeDraft,
        confidence: Double
    ) -> WorkGraphEdgeDraft {
        WorkGraphEdgeDraft(
            sourceID: reference.fromNodeID,
            targetID: target.id,
            kind: reference.kind,
            location: reference.location,
            metadataJSON: nil,
            confidence: confidence,
            provenance: .resolver
        )
    }

    private func resolved(
        _ reference: WorkGraphReferenceDraft,
        target: WorkGraphNodeDraft,
        confidence: Double
    ) -> WorkGraphReferenceResolution {
        WorkGraphReferenceResolution(
            fingerprint: reference.fingerprint,
            status: .resolved,
            targetID: target.id,
            confidence: confidence,
            resolver: Self.resolverName
        )
    }

    private func ambiguous(_ reference: WorkGraphReferenceDraft) -> WorkGraphReferenceResolution {
        WorkGraphReferenceResolution(
            fingerprint: reference.fingerprint,
            status: .ambiguous,
            targetID: nil,
            confidence: nil,
            resolver: Self.resolverName
        )
    }

    private func failed(_ reference: WorkGraphReferenceDraft) -> WorkGraphReferenceResolution {
        WorkGraphReferenceResolution(
            fingerprint: reference.fingerprint,
            status: .failed,
            targetID: nil,
            confidence: nil,
            resolver: Self.resolverName
        )
    }

    private func deduplicated(_ edges: [WorkGraphEdgeDraft]) -> [WorkGraphEdgeDraft] {
        Array(Dictionary(grouping: edges, by: \.self).compactMap { $0.value.first })
            .sorted {
                if $0.sourceID != $1.sourceID { return $0.sourceID < $1.sourceID }
                if $0.targetID != $1.targetID { return $0.targetID < $1.targetID }
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return ($0.location?.startLine ?? 0) < ($1.location?.startLine ?? 0)
            }
    }
}
