import Foundation

/// Resolves a deliberately narrow set of explicit Flutter platform-channel contracts.
///
/// This resolver never uses a shared symbol name as a cross-language signal. A
/// bridge edge exists only when both the Dart call and native handler contain the
/// same literal channel and method name, and there is one handler for that key on
/// the target platform.
struct WorkGraphBridgeResolver {
    private static let maximumSourceBytes = 512 * 1024
    private static let maximumBindingsPerFile = 128
    private static let maximumMethodsPerHandler = 128

    func resolve(
        snapshot: WorkGraphIndexSnapshot,
        sources: [WorkGraphSourceFile]
    ) -> WorkGraphBridgeResolutionResult {
        let nodesByID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        let usableSources = sources.filter {
            $0.source.lengthOfBytes(using: .utf8) <= Self.maximumSourceBytes
        }
        let dartCalls = usableSources
            .filter { $0.record.language == .dart }
            .flatMap {
                self.dartInvocations(
                    in: $0,
                    nodes: snapshot.nodes,
                    references: snapshot.references,
                    nodesByID: nodesByID
                )
            }
        let discoveredContracts = usableSources.flatMap { source in
            self.nativeContracts(in: source, nodes: snapshot.nodes)
        }

        let contractsByKey = Dictionary(grouping: discoveredContracts) {
            PlatformMethodKey(
                platform: $0.platform,
                channel: $0.channel,
                method: $0.method
            )
        }
        let uniqueContracts = contractsByKey.values.compactMap { contracts -> NativeContract? in
            let unique = Dictionary(grouping: contracts, by: \.identity)
                .compactMap { $0.value.first }
            return unique.count == 1 ? unique.first : nil
        }
        let targetsByMethod = Dictionary(grouping: uniqueContracts) {
            ChannelMethodKey(channel: $0.channel, method: $0.method)
        }

        let existingNodeIDs = Set(snapshot.nodes.map(\.id))
        var generatedNodes: [WorkGraphNodeDraft] = []
        var generatedEdges: [WorkGraphEdgeDraft] = []

        for invocation in dartCalls {
            let key = ChannelMethodKey(channel: invocation.channel, method: invocation.method)
            let targets = (targetsByMethod[key] ?? []).sorted {
                if $0.platform != $1.platform { return $0.platform.rawValue < $1.platform.rawValue }
                return $0.filePath < $1.filePath
            }
            for target in targets {
                let handler = bridgeHandler(for: target)
                if !existingNodeIDs.contains(handler.id), !generatedNodes.contains(where: { $0.id == handler.id }) {
                    generatedNodes.append(handler)
                }
                generatedEdges.append(
                    bridgeEdge(
                        sourceID: invocation.owner.id,
                        targetID: handler.id,
                        location: invocation.location,
                        channel: invocation.channel,
                        method: invocation.method,
                        platform: target.platform,
                        role: "dart_invocation"
                    )
                )
                generatedEdges.append(
                    bridgeEdge(
                        sourceID: handler.id,
                        targetID: target.owner.id,
                        location: target.location,
                        channel: target.channel,
                        method: target.method,
                        platform: target.platform,
                        role: "native_handler"
                    )
                )
            }
        }

        return WorkGraphBridgeResolutionResult(
            nodes: generatedNodes.sorted { $0.id < $1.id },
            edges: deduplicated(generatedEdges)
        )
    }

    private func dartInvocations(
        in sourceFile: WorkGraphSourceFile,
        nodes: [WorkGraphNodeDraft],
        references: [WorkGraphReferenceDraft],
        nodesByID: [String: WorkGraphNodeDraft]
    ) -> [DartInvocation] {
        let pattern = #"(?:const\s+)?MethodChannel\s*\(\s*(['"])([^'"\\\r\n]+)\1\s*\)\s*\.invokeMethod(?:\s*<[^>\r\n]+>)?\s*\(\s*(['"])([^'"\\\r\n]+)\3"#
        let source = maskingComments(in: sourceFile.source)
        return regexMatches(pattern, in: source).prefix(Self.maximumBindingsPerFile).compactMap { match in
            let line = lineNumber(at: match.range.location, in: source)
            guard let channel = capture(2, from: match, in: source),
                  let method = capture(4, from: match, in: source),
                  let owner = ownerForDartInvocation(
                    at: line,
                    filePath: sourceFile.record.path,
                    nodes: nodes,
                    references: references,
                    nodesByID: nodesByID
                  ) else {
                return nil
            }
            return DartInvocation(
                channel: channel,
                method: method,
                owner: owner,
                location: location(at: match.range.location, in: source)
            )
        }
    }

    private func ownerForDartInvocation(
        at line: Int,
        filePath: String,
        nodes: [WorkGraphNodeDraft],
        references: [WorkGraphReferenceDraft],
        nodesByID: [String: WorkGraphNodeDraft]
    ) -> WorkGraphNodeDraft? {
        let referenceOwners = Set(
            references.compactMap { reference -> String? in
                guard reference.language == .dart,
                      reference.filePath == filePath,
                      reference.kind == .calls,
                      reference.location.startLine == line,
                      let node = nodesByID[reference.fromNodeID],
                      node.filePath == filePath,
                      node.language == .dart,
                      [.function, .method].contains(node.kind) else {
                    return nil
                }
                return node.id
            }
        )
        if referenceOwners.count == 1, let id = referenceOwners.first, let owner = nodesByID[id] {
            return owner
        }
        return enclosingCallable(at: line, filePath: filePath, language: .dart, nodes: nodes)
    }

    private func nativeContracts(
        in sourceFile: WorkGraphSourceFile,
        nodes: [WorkGraphNodeDraft]
    ) -> [NativeContract] {
        let sourceFile = WorkGraphSourceFile(
            record: sourceFile.record,
            source: maskingComments(in: sourceFile.source)
        )
        switch sourceFile.record.language {
        case .swift:
            return contracts(
                in: sourceFile,
                nodes: nodes,
                platform: .iOS,
                declarationPattern: #"(?:let|var)\s+([A-Za-z_]\w*)\s*=\s*FlutterMethodChannel\s*\(\s*name\s*:\s*"([^"\\\r\n]+)""#,
                handlerPattern: { variable in #"\b\#(variable)\s*\.\s*setMethodCallHandler\b"# },
                methodExtractor: swiftMethods
            )
        case .objectiveC:
            return contracts(
                in: sourceFile,
                nodes: nodes,
                platform: .iOS,
                declarationPattern: #"FlutterMethodChannel\s*\*\s*([A-Za-z_]\w*)\s*=\s*\[\s*FlutterMethodChannel\s+methodChannelWithName\s*:\s*@"([^"\\\r\n]+)""#,
                handlerPattern: { variable in #"\[\s*\#(variable)\s+setMethodCallHandler\b"# },
                methodExtractor: objectiveCMethods
            )
        case .kotlin:
            return contracts(
                in: sourceFile,
                nodes: nodes,
                platform: .android,
                declarationPattern: #"(?:val|var)\s+([A-Za-z_]\w*)\s*=\s*MethodChannel\s*\(\s*[^,\r\n]+,\s*"([^"\\\r\n]+)"\s*\)"#,
                handlerPattern: { variable in #"\b\#(variable)\s*\.\s*setMethodCallHandler\b"# },
                methodExtractor: kotlinMethods
            )
        case .java:
            return contracts(
                in: sourceFile,
                nodes: nodes,
                platform: .android,
                declarationPattern: #"(?:final\s+)?MethodChannel\s+([A-Za-z_]\w*)\s*=\s*new\s+MethodChannel\s*\(\s*[^,\r\n]+,\s*"([^"\\\r\n]+)"\s*\)"#,
                handlerPattern: { variable in #"\b\#(variable)\s*\.\s*setMethodCallHandler\b"# },
                methodExtractor: javaMethods
            )
        case .arkTS:
            // There is no verified, bundled Flutter-Harmony native API fixture yet.
            // Do not infer a channel from generic ArkTS identifiers or imports.
            return []
        case .dart, .c, .cpp, .unknown:
            return []
        }
    }

    private func contracts(
        in sourceFile: WorkGraphSourceFile,
        nodes: [WorkGraphNodeDraft],
        platform: BridgePlatform,
        declarationPattern: String,
        handlerPattern: (String) -> String,
        methodExtractor: (String, NSRange) -> [MethodLiteral]
    ) -> [NativeContract] {
        let declarations = regexMatches(declarationPattern, in: sourceFile.source)
            .prefix(Self.maximumBindingsPerFile)
        var contracts: [NativeContract] = []

        for (index, declaration) in declarations.enumerated() {
            guard let variable = capture(1, from: declaration, in: sourceFile.source),
                  let channel = capture(2, from: declaration, in: sourceFile.source) else {
                continue
            }
            let upperBound = index + 1 < declarations.count
                ? declarations[index + 1].range.location
                : (sourceFile.source as NSString).length
            guard declaration.range.upperBound < upperBound else { continue }
            let searchRange = NSRange(location: declaration.range.upperBound, length: upperBound - declaration.range.upperBound)
            guard let handler = firstRegexMatch(handlerPattern(variable), in: sourceFile.source, range: searchRange) else {
                continue
            }
            guard let handlerBody = inlineHandlerBody(
                after: handler.range.upperBound,
                before: upperBound,
                in: sourceFile.source
            ) else {
                continue
            }
            let methods = methodExtractor(sourceFile.source, handlerBody).prefix(Self.maximumMethodsPerHandler)

            for literal in methods {
                guard let owner = enclosingCallable(
                    at: literal.location.startLine,
                    filePath: sourceFile.record.path,
                    language: sourceFile.record.language,
                    nodes: nodes
                ) else {
                    continue
                }
                contracts.append(
                    NativeContract(
                        platform: platform,
                        channel: channel,
                        method: literal.value,
                        filePath: sourceFile.record.path,
                        language: sourceFile.record.language,
                        location: literal.location,
                        owner: owner
                    )
                )
            }
        }

        return Array(Dictionary(grouping: contracts, by: \.identity).compactMap { $0.value.first })
    }

    private func swiftMethods(_ source: String, _ range: NSRange) -> [MethodLiteral] {
        let switchPattern = #"switch\s+call\s*\.\s*method\s*\{"#
        let casePattern = #"case\s+"([^"\\\r\n]+)"\s*:"#
        let equalityPattern = #"\bcall\s*\.\s*method\s*==\s*"([^"\\\r\n]+)""#
        return switchMethods(
            source: source,
            range: range,
            switchPattern: switchPattern,
            methodPattern: casePattern
        ) + literals(matching: equalityPattern, in: source, range: range)
    }

    private func objectiveCMethods(_ source: String, _ range: NSRange) -> [MethodLiteral] {
        let pattern = #"\[\s*call\s*\.\s*method\s+isEqualToString\s*:\s*@"([^"\\\r\n]+)"\s*\]"#
        return literals(matching: pattern, in: source, range: range)
    }

    private func kotlinMethods(_ source: String, _ range: NSRange) -> [MethodLiteral] {
        let switchPattern = #"when\s*\(\s*call\s*\.\s*method\s*\)\s*\{"#
        let branchPattern = #""([^"\\\r\n]+)"\s*->"#
        let equalityPattern = #"\bcall\s*\.\s*method\s*==\s*"([^"\\\r\n]+)""#
        return switchMethods(
            source: source,
            range: range,
            switchPattern: switchPattern,
            methodPattern: branchPattern
        ) + literals(matching: equalityPattern, in: source, range: range)
    }

    private func javaMethods(_ source: String, _ range: NSRange) -> [MethodLiteral] {
        let switchPattern = #"switch\s*\(\s*call\s*\.\s*method\s*\)\s*\{"#
        let casePattern = #"case\s+"([^"\\\r\n]+)"\s*:"#
        let equalsPattern = #"\bcall\s*\.\s*method\s*\.\s*equals\s*\(\s*"([^"\\\r\n]+)"\s*\)"#
        return switchMethods(
            source: source,
            range: range,
            switchPattern: switchPattern,
            methodPattern: casePattern
        ) + literals(matching: equalsPattern, in: source, range: range)
    }

    private func switchMethods(
        source: String,
        range: NSRange,
        switchPattern: String,
        methodPattern: String
    ) -> [MethodLiteral] {
        regexMatches(switchPattern, in: source, range: range).flatMap { match -> [MethodLiteral] in
            guard let body = bracedRange(startingAt: match.range.location, in: source) else {
                return []
            }
            return literals(matching: methodPattern, in: source, range: body)
        }
    }

    private func literals(matching pattern: String, in source: String, range: NSRange) -> [MethodLiteral] {
        regexMatches(pattern, in: source, range: range).compactMap { match in
            guard let value = capture(1, from: match, in: source) else { return nil }
            return MethodLiteral(value: value, location: location(at: match.range.location, in: source))
        }
    }

    private func enclosingCallable(
        at line: Int,
        filePath: String,
        language: WorkGraphLanguage,
        nodes: [WorkGraphNodeDraft]
    ) -> WorkGraphNodeDraft? {
        let candidates = nodes.filter {
            $0.filePath == filePath
                && $0.language == language
                && [.function, .method].contains($0.kind)
                && $0.location.startLine <= line
                && $0.location.endLine >= line
        }
        guard let narrowestRange = candidates.map({ $0.location.endLine - $0.location.startLine }).min() else {
            return nil
        }
        let narrowest = candidates.filter { $0.location.endLine - $0.location.startLine == narrowestRange }
        return narrowest.count == 1 ? narrowest.first : nil
    }

    private func bridgeHandler(for contract: NativeContract) -> WorkGraphNodeDraft {
        WorkGraphNodeDraft(
            id: "bridge_handler:flutter_method_channel:\(contract.platform.rawValue):\(contract.filePath):\(contract.location.startLine):\(contract.channel):\(contract.method)",
            parentID: contract.owner.id,
            kind: .bridgeHandler,
            name: "\(contract.channel).\(contract.method)",
            qualifiedName: "flutter_method_channel::\(contract.platform.rawValue)::\(contract.channel)::\(contract.method)",
            filePath: contract.filePath,
            language: contract.language,
            location: contract.location,
            signature: "MethodChannel(\"\(contract.channel)\").\(contract.method)",
            visibility: nil,
            isExported: false,
            isAsync: false,
            isStatic: false,
            isAbstract: false,
            returnType: nil,
            decorators: ["flutter_method_channel", contract.platform.rawValue]
        )
    }

    private func bridgeEdge(
        sourceID: String,
        targetID: String,
        location: WorkGraphSourceLocation,
        channel: String,
        method: String,
        platform: BridgePlatform,
        role: String
    ) -> WorkGraphEdgeDraft {
        WorkGraphEdgeDraft(
            sourceID: sourceID,
            targetID: targetID,
            kind: .bridgeInvokes,
            location: location,
            metadataJSON: metadata(channel: channel, method: method, platform: platform, role: role),
            confidence: 0.99,
            provenance: .bridgeResolver
        )
    }

    private func metadata(channel: String, method: String, platform: BridgePlatform, role: String) -> String? {
        let value = BridgeMetadata(
            transport: "flutter_method_channel",
            channel: channel,
            method: method,
            platform: platform.rawValue,
            role: role
        )
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func deduplicated(_ edges: [WorkGraphEdgeDraft]) -> [WorkGraphEdgeDraft] {
        Array(Dictionary(grouping: edges, by: \ .self).compactMap { $0.value.first })
            .sorted {
                if $0.sourceID != $1.sourceID { return $0.sourceID < $1.sourceID }
                if $0.targetID != $1.targetID { return $0.targetID < $1.targetID }
                return ($0.location?.startLine ?? 0) < ($1.location?.startLine ?? 0)
            }
    }

    private func regexMatches(_ pattern: String, in source: String, range: NSRange? = nil) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let searchRange = range ?? NSRange(location: 0, length: (source as NSString).length)
        return expression.matches(in: source, range: searchRange).filter {
            !isWithinStringOrComment(at: $0.range.location, in: source)
        }
    }

    private func firstRegexMatch(_ pattern: String, in source: String, range: NSRange) -> NSTextCheckingResult? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return expression.matches(in: source, range: range).first {
            !isWithinStringOrComment(at: $0.range.location, in: source)
        }
    }

    private func capture(_ index: Int, from match: NSTextCheckingResult, in source: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return (source as NSString).substring(with: range)
    }

    private func inlineHandlerBody(after start: Int, before upperBound: Int, in source: String) -> NSRange? {
        let text = source as NSString
        var quote: unichar?
        var escaped = false

        for index in start..<upperBound {
            let character = text.character(at: index)
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == 92 {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }
            if character == 34 || character == 39 {
                quote = character
                continue
            }
            if character == 59 {
                return nil
            }
            if character == 123 {
                return bracedRange(startingAt: index, in: source, upperBound: upperBound)
            }
        }
        return nil
    }

    private func bracedRange(startingAt start: Int, in source: String, upperBound: Int? = nil) -> NSRange? {
        let text = source as NSString
        let limit = min(upperBound ?? text.length, text.length)
        var openingBrace: Int?
        var depth = 0
        var quote: unichar?
        var escaped = false

        for index in start..<limit {
            let character = text.character(at: index)
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == 92 {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }
            if character == 34 || character == 39 {
                quote = character
                continue
            }
            if character == 123 {
                if openingBrace == nil { openingBrace = index }
                depth += 1
            } else if character == 125, let openingBrace {
                depth -= 1
                if depth == 0 {
                    return NSRange(location: openingBrace, length: index - openingBrace + 1)
                }
            }
        }
        return nil
    }

    /// Replaces comments with spaces while preserving UTF-16 offsets and line
    /// breaks, so source positions remain valid for graph nodes and edges.
    private func maskingComments(in source: String) -> String {
        let text = source as NSString
        var output = Array<unichar>(repeating: 32, count: text.length)
        var index = 0
        var quote: unichar?
        var escaped = false
        var lineComment = false
        var blockComment = false

        while index < text.length {
            let character = text.character(at: index)
            let next = index + 1 < text.length ? text.character(at: index + 1) : 0

            if lineComment {
                if character == 10 || character == 13 {
                    output[index] = character
                    lineComment = false
                }
                index += 1
                continue
            }
            if blockComment {
                if character == 42, next == 47 {
                    blockComment = false
                    index += 2
                    continue
                }
                if character == 10 || character == 13 {
                    output[index] = character
                }
                index += 1
                continue
            }
            if let activeQuote = quote {
                output[index] = character
                if escaped {
                    escaped = false
                } else if character == 92 {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                index += 1
                continue
            }
            if character == 47, next == 47 {
                lineComment = true
                index += 2
                continue
            }
            if character == 47, next == 42 {
                blockComment = true
                index += 2
                continue
            }

            output[index] = character
            if character == 34 || character == 39 {
                quote = character
            }
            index += 1
        }

        return String(decoding: output, as: UTF16.self)
    }

    private func isWithinStringOrComment(at utf16Offset: Int, in source: String) -> Bool {
        let text = source as NSString
        var index = 0
        var quote: unichar?
        var escaped = false
        var lineComment = false
        var blockComment = false

        while index < utf16Offset {
            let character = text.character(at: index)
            let next = index + 1 < text.length ? text.character(at: index + 1) : 0

            if lineComment {
                if character == 10 || character == 13 { lineComment = false }
                index += 1
                continue
            }
            if blockComment {
                if character == 42, next == 47 {
                    blockComment = false
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == 92 {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                index += 1
                continue
            }
            if character == 47, next == 47 {
                lineComment = true
                index += 2
                continue
            }
            if character == 47, next == 42 {
                blockComment = true
                index += 2
                continue
            }
            if character == 34 || character == 39 {
                quote = character
            }
            index += 1
        }
        return quote != nil || lineComment || blockComment
    }

    private func lineNumber(at utf16Offset: Int, in source: String) -> Int {
        let prefix = (source as NSString).substring(to: utf16Offset)
        return prefix.utf8.reduce(into: 1) { count, byte in
            if byte == 10 { count += 1 }
        }
    }

    private func location(at utf16Offset: Int, in source: String) -> WorkGraphSourceLocation {
        let line = lineNumber(at: utf16Offset, in: source)
        return WorkGraphSourceLocation(startLine: line, endLine: line, startColumn: 0, endColumn: 0)
    }

    private enum BridgePlatform: String, Hashable {
        case iOS = "ios"
        case android
    }

    private struct ChannelMethodKey: Hashable {
        var channel: String
        var method: String
    }

    private struct PlatformMethodKey: Hashable {
        var platform: BridgePlatform
        var channel: String
        var method: String
    }

    private struct DartInvocation {
        var channel: String
        var method: String
        var owner: WorkGraphNodeDraft
        var location: WorkGraphSourceLocation
    }

    private struct NativeContract: Hashable {
        var platform: BridgePlatform
        var channel: String
        var method: String
        var filePath: String
        var language: WorkGraphLanguage
        var location: WorkGraphSourceLocation
        var owner: WorkGraphNodeDraft

        var identity: String {
            "\(platform.rawValue):\(filePath):\(location.startLine):\(channel):\(method):\(owner.id)"
        }
    }

    private struct MethodLiteral {
        var value: String
        var location: WorkGraphSourceLocation
    }

    private struct BridgeMetadata: Encodable {
        var transport: String
        var channel: String
        var method: String
        var platform: String
        var role: String
    }
}

struct WorkGraphBridgeResolutionResult: Equatable {
    var nodes: [WorkGraphNodeDraft]
    var edges: [WorkGraphEdgeDraft]
}
