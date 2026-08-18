import Foundation

/// A compact, data-only slice of a WorkGraph for an Agent prompt.
///
/// The context intentionally contains symbol locations and resolved structural
/// edges only. It never reads navigation prose, source snippets, task files, or
/// user-authored repository content beyond parser-produced symbol metadata.
struct WorkGraphAgentContext: Equatable {
    enum EvidenceOrigin: String, CaseIterable, Hashable {
        case symbolMatch = "symbol_match"
        case caller = "caller"
        case callee = "callee"
        case trace = "trace"
        case impact = "impact"
    }

    struct SymbolCandidate: Equatable {
        var id: String
        var name: String
        var qualifiedName: String
        var kind: WorkGraphNodeKind
        var path: String
        var location: WorkGraphSourceLocation
        var language: WorkGraphLanguage
        var origins: [EvidenceOrigin]
    }

    struct RelationshipCandidate: Equatable {
        var sourceID: String
        var targetID: String
        var kind: WorkGraphEdgeKind
        var location: WorkGraphSourceLocation?
        var confidence: Double
        var origins: [EvidenceOrigin]
    }

    var symbols: [SymbolCandidate]
    var relationships: [RelationshipCandidate]
    var promptSection: String
    var estimatedTokenCount: Int
}

/// Controls both graph expansion and the hard, conservative prompt budget.
///
/// `minimumConfidence` cannot lower the safety floor of 0.85. The builder only
/// follows resolved `calls` edges or explicit cross-platform bridge edges, so
/// low-confidence and ambiguous references can never become Agent context
/// through this path.
struct WorkGraphContextConfiguration: Equatable {
    static let defaultTokenBudget = 420

    var tokenBudget: Int
    var maximumSeedSymbols: Int
    var maximumRelatedSymbolsPerSeed: Int
    var maximumTraceQueries: Int
    var maximumTraceDepth: Int
    var minimumConfidence: Double
    /// Ordinary work-item context starts from production evidence. Test sources
    /// remain indexed for explicit structural queries such as affected tests.
    var includeTestSources: Bool

    init(
        tokenBudget: Int = Self.defaultTokenBudget,
        maximumSeedSymbols: Int = 3,
        maximumRelatedSymbolsPerSeed: Int = 2,
        maximumTraceQueries: Int = 2,
        maximumTraceDepth: Int = 4,
        minimumConfidence: Double = 0.85,
        includeTestSources: Bool = false
    ) {
        self.tokenBudget = tokenBudget
        self.maximumSeedSymbols = maximumSeedSymbols
        self.maximumRelatedSymbolsPerSeed = maximumRelatedSymbolsPerSeed
        self.maximumTraceQueries = maximumTraceQueries
        self.maximumTraceDepth = maximumTraceDepth
        self.minimumConfidence = minimumConfidence
        self.includeTestSources = includeTestSources
    }
}

/// Builds a small, structural candidate-evidence block for an Agent.
///
/// This is deliberately not a semantic answer generator. Search hits establish
/// only candidate anchors; graph relationships are included only when the
/// database has a resolved high-confidence `calls` edge or explicit bridge
/// edge. The caller should omit the context when this returns `nil` rather than
/// falling back to prose or a broad document search.
final class WorkGraphContextBuilder {
    private static let confidenceFloor = 0.85
    private static let maximumLookupTerms = 8
    private static let allowedRelationshipKinds: Set<WorkGraphEdgeKind> = [.calls, .bridgeInvokes]
    private static let maximumImpactSeedSymbols = 1
    private static let maximumImpactSymbolsPerSeed = 3
    private static let maximumImpactDepth = 2
    private static let ChineseImpactIntentPhrases = [
        "影响范围", "影响分析", "影响评估", "受影响", "调用方", "调用链", "依赖方", "回归范围", "变更范围"
    ]
    private static let EnglishImpactIntentTerms: Set<String> = [
        "impact", "affected", "affect", "caller", "callers", "dependent", "dependents", "dependency", "dependencies", "break", "breaks", "breaking"
    ]

    func build(
        store: WorkGraphStore,
        query: String,
        configuration: WorkGraphContextConfiguration = .init(),
        excludedFilePaths: Set<String> = []
    ) throws -> WorkGraphAgentContext? {
        let tokenBudget = max(0, configuration.tokenBudget)
        let maximumSeeds = max(0, configuration.maximumSeedSymbols)
        guard tokenBudget > 0, maximumSeeds > 0 else { return nil }

        let minimumConfidence = max(Self.confidenceFloor, configuration.minimumConfidence)
        let anchors = try searchAnchors(
            in: store,
            query: query,
            maximumSeeds: maximumSeeds,
            excludedFilePaths: excludedFilePaths,
            includeTestSources: configuration.includeTestSources
        )
        guard !anchors.isEmpty else { return nil }

        var symbolsByID: [String: MutableSymbol] = [:]
        var relationshipsByKey: [RelationshipKey: MutableRelationship] = [:]

        func isExcludedFilePath(_ path: String) -> Bool {
            excludedFilePaths.contains(path)
                || (!configuration.includeTestSources && WorkGraphRepositoryPath.isTestSourcePath(path))
        }

        func addSymbol(_ descriptor: SymbolDescriptor, origin: WorkGraphAgentContext.EvidenceOrigin, score: Int) {
            guard !isExcludedFilePath(descriptor.path) else { return }
            if var existing = symbolsByID[descriptor.id] {
                existing.origins.insert(origin)
                existing.score = max(existing.score, score)
                symbolsByID[descriptor.id] = existing
            } else {
                symbolsByID[descriptor.id] = MutableSymbol(
                    descriptor: descriptor,
                    origins: [origin],
                    score: score
                )
            }
        }

        func addRelationship(_ edge: WorkGraphEdge, origin: WorkGraphAgentContext.EvidenceOrigin) {
            guard Self.allowedRelationshipKinds.contains(edge.kind), edge.confidence >= minimumConfidence else { return }
            let key = RelationshipKey(edge: edge)
            if var existing = relationshipsByKey[key] {
                existing.origins.insert(origin)
                if edge.confidence > existing.confidence {
                    existing.confidence = edge.confidence
                    existing.location = edge.location
                }
                relationshipsByKey[key] = existing
            } else {
                relationshipsByKey[key] = MutableRelationship(
                    sourceID: edge.sourceID,
                    targetID: edge.targetID,
                    kind: edge.kind,
                    location: edge.location,
                    confidence: edge.confidence,
                    origins: [origin]
                )
            }
        }

        let relatedLimit = max(0, configuration.maximumRelatedSymbolsPerSeed)
        for anchor in anchors {
            addSymbol(anchor.descriptor, origin: .symbolMatch, score: anchor.score)
            guard relatedLimit > 0 else { continue }

            let callees = try store.callees(
                of: anchor.descriptor.id,
                edgeKinds: Self.allowedRelationshipKinds,
                minimumConfidence: minimumConfidence,
                maxDepth: 1,
                limit: relatedLimit
            )
            for node in callees.nodes {
                addSymbol(
                    SymbolDescriptor(node),
                    origin: .callee,
                    score: anchor.score - 10
                )
            }
            for edge in callees.edges {
                addRelationship(edge, origin: .callee)
            }

            let callers = try store.callers(
                of: anchor.descriptor.id,
                edgeKinds: Self.allowedRelationshipKinds,
                minimumConfidence: minimumConfidence,
                maxDepth: 1,
                limit: relatedLimit
            )
            for node in callers.nodes {
                addSymbol(
                    SymbolDescriptor(node),
                    origin: .caller,
                    score: anchor.score - 10
                )
            }
            for edge in callers.edges {
                addRelationship(edge, origin: .caller)
            }
        }

        // An impact traversal is intentionally opt-in by wording and is bounded
        // more tightly than ordinary neighbor expansion. This prevents routine
        // tickets from receiving a broad reverse-dependency slice by default.
        if shouldExpandImpact(for: query) {
            for anchor in explicitImpactAnchors(from: anchors, query: query).prefix(Self.maximumImpactSeedSymbols) {
                let impact = try store.impact(
                    of: anchor.descriptor.id,
                    edgeKinds: Self.allowedRelationshipKinds,
                    minimumConfidence: minimumConfidence,
                    maxDepth: Self.maximumImpactDepth,
                    maxNodes: Self.maximumImpactSymbolsPerSeed
                )
                for node in impact.nodes {
                    addSymbol(
                        SymbolDescriptor(node),
                        origin: .impact,
                        score: anchor.score - 20
                    )
                }
                for edge in impact.edges {
                    addRelationship(edge, origin: .impact)
                }
            }
        }

        let traceQueryLimit = max(0, configuration.maximumTraceQueries)
        if traceQueryLimit > 0, anchors.count > 1 {
            let tracePairs = orderedTracePairs(for: anchors)
            for pair in tracePairs.prefix(traceQueryLimit) {
                guard let trace = try store.trace(
                    from: pair.sourceID,
                    to: pair.targetID,
                    edgeKinds: Self.allowedRelationshipKinds,
                    minimumConfidence: minimumConfidence,
                    maxDepth: max(1, configuration.maximumTraceDepth),
                    maxNodes: max(8, maximumSeeds * (relatedLimit * 2 + 1))
                ) else {
                    continue
                }
                for node in trace.nodes {
                    addSymbol(SymbolDescriptor(node), origin: .trace, score: pair.score - 5)
                }
                for edge in trace.edges {
                    addRelationship(edge, origin: .trace)
                }
            }
        }

        return render(
            symbolsByID: symbolsByID,
            relationshipsByKey: relationshipsByKey,
            tokenBudget: tokenBudget,
            maximumSeedSymbols: maximumSeeds,
            minimumConfidence: minimumConfidence
        )
    }

    private func searchAnchors(
        in store: WorkGraphStore,
        query: String,
        maximumSeeds: Int,
        excludedFilePaths: Set<String>,
        includeTestSources: Bool
    ) throws -> [ScoredAnchor] {
        let terms = lookupTerms(in: query)
        guard !terms.isEmpty else { return [] }

        var candidatesByID: [String: ScoredAnchor] = [:]
        let queryLimit = max(6, maximumSeeds * 3)

        func addCandidate(_ descriptor: SymbolDescriptor, score: Int) {
            let candidate = ScoredAnchor(descriptor: descriptor, score: score)
            if let existing = candidatesByID[descriptor.id] {
                if candidate.score > existing.score {
                    candidatesByID[descriptor.id] = candidate
                }
            } else {
                candidatesByID[descriptor.id] = candidate
            }
        }

        // A qualified symbol named directly in a ticket is stronger evidence
        // than a partial keyword hit, especially where method names repeat.
        for (index, qualifiedName) in qualifiedSymbolNames(in: query).enumerated() {
            let matches = try store.nodes(qualifiedName: qualifiedName, limit: queryLimit)
            for match in matches {
                let descriptor = SymbolDescriptor(match)
                guard !excludedFilePaths.contains(descriptor.path),
                      includeTestSources || !WorkGraphRepositoryPath.isTestSourcePath(descriptor.path) else {
                    continue
                }
                addCandidate(
                    descriptor,
                    score: 2_000 - index * 25
                )
            }
        }

        for (termIndex, term) in terms.prefix(Self.maximumLookupTerms).enumerated() {
            let matches = try store.searchSymbols(query: term, limit: queryLimit)
            for match in matches where match.kind != .file
                && !excludedFilePaths.contains(match.path)
                && (includeTestSources || !WorkGraphRepositoryPath.isTestSourcePath(match.path)) {
                addCandidate(
                    SymbolDescriptor(match),
                    score: score(match: match, term: term, termIndex: termIndex)
                )
            }
        }

        return candidatesByID.values.sorted(by: anchorOrdering).prefix(maximumSeeds).map { $0 }
    }

    private func lookupTerms(in query: String) -> [String] {
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./-"))
        let rawTerms = query.components(separatedBy: permitted.inverted)
        var seen = Set<String>()
        var terms: [String] = []

        for rawTerm in rawTerms {
            let fragments = rawTerm.split(whereSeparator: { $0 == "/" || $0 == "." || $0 == "-" })
            for fragment in fragments {
                let term = String(fragment).trimmingCharacters(in: .whitespacesAndNewlines)
                guard term.count >= 3,
                      term.rangeOfCharacter(from: .decimalDigits.inverted) != nil else {
                    continue
                }
                let key = term.lowercased()
                guard seen.insert(key).inserted else { continue }
                terms.append(String(term.prefix(96)))
            }
        }
        return terms
    }

    private func qualifiedSymbolNames(in query: String) -> [String] {
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./-"))
        var seen = Set<String>()
        var names: [String] = []

        for rawTerm in query.components(separatedBy: permitted.inverted) where !rawTerm.contains("/") {
            let fragments = rawTerm.split(separator: ".")
            guard fragments.count >= 2,
                  fragments.allSatisfy({ fragment in
                      fragment.count >= 3 && fragment.rangeOfCharacter(from: .decimalDigits.inverted) != nil
                  }) else {
                continue
            }
            let name = fragments.joined(separator: ".")
            guard seen.insert(name.lowercased()).inserted else { continue }
            names.append(String(name.prefix(192)))
        }
        return names
    }

    private func shouldExpandImpact(for query: String) -> Bool {
        let normalized = query.lowercased()
        if Self.ChineseImpactIntentPhrases.contains(where: { normalized.contains($0) }) {
            return true
        }

        let latinTerms = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return latinTerms.contains { Self.EnglishImpactIntentTerms.contains($0) }
    }

    /// Reverse reachability is only useful when the ticket names a concrete
    /// symbol. A broad keyword hit is enough for normal candidate context but
    /// not precise enough to claim an impact slice.
    private func explicitImpactAnchors(
        from anchors: [ScoredAnchor],
        query: String
    ) -> [ScoredAnchor] {
        let queryTerms = Set(lookupTerms(in: query).map { $0.lowercased() })
        guard !queryTerms.isEmpty else { return [] }

        let exactAnchors = anchors.filter { anchor in
            queryTerms.contains(anchor.descriptor.name.lowercased())
        }
        let duplicateNames = Set(
            Dictionary(grouping: exactAnchors, by: { $0.descriptor.name.lowercased() })
                .filter { $0.value.count > 1 }
                .map(\.key)
        )
        return exactAnchors.filter {
            !duplicateNames.contains($0.descriptor.name.lowercased())
        }
    }

    private func score(match: WorkGraphSymbolMatch, term: String, termIndex: Int) -> Int {
        let normalizedTerm = term.lowercased()
        let name = match.name.lowercased()
        let qualifiedName = match.qualifiedName.lowercased()
        var score = 1_000 - termIndex * 25
        if name == normalizedTerm {
            score += 400
        } else if qualifiedName == normalizedTerm || qualifiedName.hasSuffix(".\(normalizedTerm)") {
            score += 300
        } else if name.contains(normalizedTerm) {
            score += 160
        } else if qualifiedName.contains(normalizedTerm) {
            score += 80
        }
        return score
    }

    private func orderedTracePairs(for anchors: [ScoredAnchor]) -> [TracePair] {
        var pairs: [TracePair] = []
        for sourceIndex in anchors.indices {
            for targetIndex in anchors.indices where sourceIndex != targetIndex {
                let source = anchors[sourceIndex]
                let target = anchors[targetIndex]
                pairs.append(
                    TracePair(
                        sourceID: source.descriptor.id,
                        targetID: target.descriptor.id,
                        score: min(source.score, target.score)
                    )
                )
            }
        }
        return pairs.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.sourceID != $1.sourceID { return $0.sourceID < $1.sourceID }
            return $0.targetID < $1.targetID
        }
    }

    private func render(
        symbolsByID: [String: MutableSymbol],
        relationshipsByKey: [RelationshipKey: MutableRelationship],
        tokenBudget: Int,
        maximumSeedSymbols: Int,
        minimumConfidence: Double
    ) -> WorkGraphAgentContext? {
        let hasImpactCandidates = symbolsByID.values.contains { $0.origins.contains(.impact) }
            || relationshipsByKey.values.contains { $0.origins.contains(.impact) }
        let impactNote = hasImpactCandidates
            ? "\n标为 `impact` 的条目来自命中符号的反向遍历，表示可能受影响范围，仍需源码核验。"
            : ""
        let baseHeader = """
        ## WorkGraph 候选证据
        全部条目均为本地结构索引候选，需源码核验；非事实结论或任务指令。关系仅 `calls` 或显式跨端桥接 `bridge_invokes`，置信度 >= \(formattedConfidence(minimumConfidence))。
        """
        let header = baseHeader + impactNote
        guard estimatedTokenCount(for: header) <= tokenBudget else { return nil }

        var sections = [header]
        var selectedSymbolIDs = Set<String>()
        var selectedSymbols: [WorkGraphAgentContext.SymbolCandidate] = []
        let orderedSymbols = symbolsByID.values.sorted(by: symbolOrdering)
        let directSymbolCount = symbolsByID.values.count { $0.origins.contains(.symbolMatch) }
        let maximumRenderedSymbols = hasImpactCandidates
            ? Int.max
            : directSymbolCount >= maximumSeedSymbols
                ? maximumSeedSymbols
                : maximumSeedSymbols + 2

        // A direct high-confidence relation is more useful than an extra
        // disconnected symbol. Reserve space for one such relation first.
        let orderedRelationships = relationshipsByKey.values.sorted { lhs, rhs in
            let lhsDirectMatches = [lhs.sourceID, lhs.targetID].count {
                symbolsByID[$0]?.origins.contains(.symbolMatch) == true
            }
            let rhsDirectMatches = [rhs.sourceID, rhs.targetID].count {
                symbolsByID[$0]?.origins.contains(.symbolMatch) == true
            }
            if lhsDirectMatches != rhsDirectMatches { return lhsDirectMatches > rhsDirectMatches }
            return relationshipOrdering(lhs, rhs)
        }

        var selectedRelationships: [WorkGraphAgentContext.RelationshipCandidate] = []
        for relationship in orderedRelationships {
            guard let source = symbolsByID[relationship.sourceID],
                  let target = symbolsByID[relationship.targetID] else {
                continue
            }

            let directMatches = [source, target].count { $0.origins.contains(.symbolMatch) }
            guard directMatches == 2 else { continue }

            var prospectiveSections = sections
            var prospectiveIDs = selectedSymbolIDs
            var prospectiveSymbols = selectedSymbols
            var canIncludeRelationship = true
            for symbol in [source, target] where !prospectiveIDs.contains(symbol.descriptor.id) {
                let line = symbolLine(for: symbol)
                let fragment = prospectiveSymbols.isEmpty ? "符号候选：\n\(line)" : line
                guard canAppend(fragment, to: prospectiveSections, tokenBudget: tokenBudget) else {
                    canIncludeRelationship = false
                    break
                }
                prospectiveSections.append(fragment)
                prospectiveIDs.insert(symbol.descriptor.id)
                prospectiveSymbols.append(symbol.asCandidate)
            }
            guard canIncludeRelationship else { continue }

            let relationLine = relationshipLine(relationship, source: source.descriptor, target: target.descriptor)
            let relationFragment = "关系候选：\n\(relationLine)"
            guard canAppend(relationFragment, to: prospectiveSections, tokenBudget: tokenBudget) else {
                continue
            }

            sections = prospectiveSections + [relationFragment]
            selectedSymbolIDs = prospectiveIDs
            selectedSymbols = prospectiveSymbols
            selectedRelationships.append(relationship.asCandidate)
            break
        }

        for symbol in orderedSymbols {
            guard selectedSymbols.count < maximumRenderedSymbols else { break }
            guard !selectedSymbolIDs.contains(symbol.descriptor.id) else { continue }
            let line = symbolLine(for: symbol)
            let fragment = selectedSymbols.isEmpty ? "符号候选：\n\(line)" : line
            guard canAppend(fragment, to: sections, tokenBudget: tokenBudget) else { continue }
            sections.append(fragment)
            selectedSymbolIDs.insert(symbol.descriptor.id)
            selectedSymbols.append(symbol.asCandidate)
        }
        guard !selectedSymbols.isEmpty else { return nil }

        for relationship in orderedRelationships {
            guard !selectedRelationships.contains(where: {
                $0.sourceID == relationship.sourceID
                    && $0.targetID == relationship.targetID
                    && $0.kind == relationship.kind
            }) else {
                continue
            }
            guard selectedSymbolIDs.contains(relationship.sourceID),
                  selectedSymbolIDs.contains(relationship.targetID),
                  let source = symbolsByID[relationship.sourceID],
                  let target = symbolsByID[relationship.targetID] else {
                continue
            }
            let line = relationshipLine(relationship, source: source.descriptor, target: target.descriptor)
            let fragment = selectedRelationships.isEmpty ? "关系候选：\n\(line)" : line
            guard canAppend(fragment, to: sections, tokenBudget: tokenBudget) else { continue }
            sections.append(fragment)
            selectedRelationships.append(relationship.asCandidate)
        }

        let includesSelectedImpact = selectedSymbols.contains { $0.origins.contains(.impact) }
            || selectedRelationships.contains { $0.origins.contains(.impact) }
        if hasImpactCandidates && !includesSelectedImpact {
            sections[0] = baseHeader
        }

        let promptSection = sections.joined(separator: "\n")
        let estimatedTokenCount = estimatedTokenCount(for: promptSection)
        guard estimatedTokenCount <= tokenBudget else { return nil }
        return WorkGraphAgentContext(
            symbols: selectedSymbols,
            relationships: selectedRelationships,
            promptSection: promptSection,
            estimatedTokenCount: estimatedTokenCount
        )
    }

    private func canAppend(_ fragment: String, to sections: [String], tokenBudget: Int) -> Bool {
        let candidate = (sections + [fragment]).joined(separator: "\n")
        return estimatedTokenCount(for: candidate) <= tokenBudget
    }

    private func symbolLine(for symbol: MutableSymbol) -> String {
        let descriptor = symbol.descriptor
        let qualifiedName = descriptor.qualifiedName.isEmpty ? descriptor.name : descriptor.qualifiedName
        let origins = orderedOrigins(symbol.origins).map(\.rawValue).joined(separator: ",")
        return "- `\(displayValue(qualifiedName))` [\(descriptor.kind.rawValue), \(descriptor.language.rawValue)] @ `\(displayValue(descriptor.path)):\(descriptor.location.startLine)` (\(origins))"
    }

    private func relationshipLine(
        _ relationship: MutableRelationship,
        source: SymbolDescriptor,
        target: SymbolDescriptor
    ) -> String {
        let sourceName = source.qualifiedName.isEmpty ? source.name : source.qualifiedName
        let targetName = target.qualifiedName.isEmpty ? target.name : target.qualifiedName
        let origins = orderedOrigins(relationship.origins).map(\.rawValue).joined(separator: ",")
        let location = relationship.location.map {
            " @ `\(displayValue(source.path)):\($0.startLine)`"
        } ?? ""
        return "- `\(displayValue(sourceName))` -> `\(displayValue(targetName))` [\(relationship.kind.rawValue), \(formattedConfidence(relationship.confidence)); \(origins)]\(location)"
    }

    private func orderedOrigins(_ origins: Set<WorkGraphAgentContext.EvidenceOrigin>) -> [WorkGraphAgentContext.EvidenceOrigin] {
        WorkGraphAgentContext.EvidenceOrigin.allCases.filter { origins.contains($0) }
    }

    private func formattedConfidence(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// This intentionally overestimates mixed Chinese/ASCII prompt text. It is
    /// a budget guard, not a model-specific tokenizer, so the final output is
    /// smaller than the caller's configured allowance in normal use.
    private func estimatedTokenCount(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return (text.lengthOfBytes(using: .utf8) + 1) / 2
    }

    private func displayValue(_ value: String, limit: Int = 120) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "`", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count <= limit { return normalized }
        return String(normalized.prefix(limit - 1)) + "…"
    }

    private func anchorOrdering(_ lhs: ScoredAnchor, _ rhs: ScoredAnchor) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.descriptor.qualifiedName != rhs.descriptor.qualifiedName {
            return lhs.descriptor.qualifiedName < rhs.descriptor.qualifiedName
        }
        if lhs.descriptor.path != rhs.descriptor.path { return lhs.descriptor.path < rhs.descriptor.path }
        return lhs.descriptor.id < rhs.descriptor.id
    }

    private func symbolOrdering(_ lhs: MutableSymbol, _ rhs: MutableSymbol) -> Bool {
        let lhsIsAnchor = lhs.origins.contains(.symbolMatch)
        let rhsIsAnchor = rhs.origins.contains(.symbolMatch)
        if lhsIsAnchor != rhsIsAnchor { return lhsIsAnchor }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.descriptor.qualifiedName != rhs.descriptor.qualifiedName {
            return lhs.descriptor.qualifiedName < rhs.descriptor.qualifiedName
        }
        if lhs.descriptor.path != rhs.descriptor.path { return lhs.descriptor.path < rhs.descriptor.path }
        return lhs.descriptor.id < rhs.descriptor.id
    }

    private func relationshipOrdering(_ lhs: MutableRelationship, _ rhs: MutableRelationship) -> Bool {
        if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
        if lhs.sourceID != rhs.sourceID { return lhs.sourceID < rhs.sourceID }
        return lhs.targetID < rhs.targetID
    }
}

/// Convenience API for the UI/service boundary. It refuses stale or incomplete
/// navigation and has no JSONL/document fallback, preventing old keyword
/// navigation from being mistaken for graph evidence.
extension ProjectNavigationService {
    func graphAgentContext(
        for repositoryPath: String,
        query: String,
        configuration: WorkGraphContextConfiguration = .init()
    ) -> WorkGraphAgentContext? {
        guard case .current = status(for: repositoryPath) else { return nil }
        let databaseURL = URL(fileURLWithPath: Self.workgraphPath(for: repositoryPath), isDirectory: true)
            .appendingPathComponent(WorkGraphStore.fileName)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        do {
            let store = WorkGraphStore(databaseURL: databaseURL, accessMode: .readOnly)
            let stalePaths = try staleIndexedFilePaths(for: repositoryPath, store: store)
            return try WorkGraphContextBuilder().build(
                store: store,
                query: query,
                configuration: configuration,
                excludedFilePaths: stalePaths
            )
        } catch {
            return nil
        }
    }

    /// Freshness indicators stay quiet in the UI, but changed files are never
    /// injected as structural evidence for a task. This uses the same cheap
    /// size/mtime signal as the incremental index before any parser work runs.
    private func staleIndexedFilePaths(
        for repositoryPath: String,
        store: WorkGraphStore
    ) throws -> Set<String> {
        let repositoryURL = URL(fileURLWithPath: repositoryPath, isDirectory: true)
            .standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]

        return Set(try store.indexedFiles().compactMap { record in
            let fileURL = repositoryURL.appendingPathComponent(record.path)
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let byteCount = values.fileSize,
                  byteCount == record.byteCount,
                  let indexedAt = record.modifiedAt,
                  let currentModifiedAt = values.contentModificationDate else {
                return record.path
            }

            let indexedMilliseconds = Int64(indexedAt.timeIntervalSince1970 * 1_000)
            let currentMilliseconds = Int64(currentModifiedAt.timeIntervalSince1970 * 1_000)
            return indexedMilliseconds == currentMilliseconds ? nil : record.path
        })
    }
}

private struct SymbolDescriptor: Hashable {
    var id: String
    var name: String
    var qualifiedName: String
    var kind: WorkGraphNodeKind
    var path: String
    var location: WorkGraphSourceLocation
    var language: WorkGraphLanguage

    init(_ match: WorkGraphSymbolMatch) {
        id = match.id
        name = match.name
        qualifiedName = match.qualifiedName
        kind = match.kind
        path = match.path
        location = match.location
        language = match.language
    }

    init(_ node: WorkGraphNode) {
        id = node.id
        name = node.name
        qualifiedName = node.qualifiedName
        kind = node.kind
        path = node.path
        location = node.location
        language = node.language
    }
}

private struct ScoredAnchor {
    var descriptor: SymbolDescriptor
    var score: Int
}

private struct TracePair {
    var sourceID: String
    var targetID: String
    var score: Int
}

private struct MutableSymbol {
    var descriptor: SymbolDescriptor
    var origins: Set<WorkGraphAgentContext.EvidenceOrigin>
    var score: Int

    var asCandidate: WorkGraphAgentContext.SymbolCandidate {
        WorkGraphAgentContext.SymbolCandidate(
            id: descriptor.id,
            name: descriptor.name,
            qualifiedName: descriptor.qualifiedName,
            kind: descriptor.kind,
            path: descriptor.path,
            location: descriptor.location,
            language: descriptor.language,
            origins: WorkGraphAgentContext.EvidenceOrigin.allCases.filter { origins.contains($0) }
        )
    }
}

private struct RelationshipKey: Hashable {
    var sourceID: String
    var targetID: String
    var kind: WorkGraphEdgeKind

    init(edge: WorkGraphEdge) {
        sourceID = edge.sourceID
        targetID = edge.targetID
        kind = edge.kind
    }
}

private struct MutableRelationship {
    var sourceID: String
    var targetID: String
    var kind: WorkGraphEdgeKind
    var location: WorkGraphSourceLocation?
    var confidence: Double
    var origins: Set<WorkGraphAgentContext.EvidenceOrigin>

    var asCandidate: WorkGraphAgentContext.RelationshipCandidate {
        WorkGraphAgentContext.RelationshipCandidate(
            sourceID: sourceID,
            targetID: targetID,
            kind: kind,
            location: location,
            confidence: confidence,
            origins: WorkGraphAgentContext.EvidenceOrigin.allCases.filter { origins.contains($0) }
        )
    }
}
