import Foundation
import XCTest
@testable import DevFlow

final class WorkGraphQueryServiceTests: XCTestCase {
    private var repositoryURL: URL!
    private var databaseURL: URL!
    private var service: WorkGraphQueryService!

    override func setUpWithError() throws {
        repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkGraphQueryServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        let workgraphURL = repositoryURL.appendingPathComponent(".workgraph", isDirectory: true)
        try FileManager.default.createDirectory(at: workgraphURL, withIntermediateDirectories: true)
        try writeCurrentManifest(to: workgraphURL.appendingPathComponent("manifest.json"))
        for fileName in ["overview.md", "modules.json", "symbols.jsonl", "edges.jsonl", "documents.jsonl"] {
            try "".write(
                to: workgraphURL.appendingPathComponent(fileName),
                atomically: true,
                encoding: .utf8
            )
        }

        databaseURL = workgraphURL.appendingPathComponent(WorkGraphStore.fileName)
        try WorkGraphStore(databaseURL: databaseURL).replace(
            index: WorkGraphIndexSnapshot(
                files: [
                    WorkGraphFileRecord(
                        path: "Sources/App/Graph.swift",
                        contentHash: "graph",
                        language: .swift,
                        byteCount: 128,
                        modifiedAt: nil,
                        isGenerated: false,
                        diagnostics: []
                    )
                ],
                nodes: graphNodes(),
                edges: graphEdges(),
                references: [],
                documents: []
            )
        )
        // These tests seed a deliberately synthetic SQLite graph without a
        // matching source tree. Keep them focused on query semantics rather
        // than allowing the production auto-catch-up path to replace it.
        service = WorkGraphQueryService(
            syncCoordinator: WorkGraphAutoSyncCoordinator(automaticallyRebuild: false)
        )
    }

    override func tearDownWithError() throws {
        if let repositoryURL {
            try? FileManager.default.removeItem(at: repositoryURL)
        }
        repositoryURL = nil
        databaseURL = nil
        service = nil
    }

    func testFindsDefinitionsAndRejectsAmbiguousQualifiedName() throws {
        let definitions = try service.execute(
            repositoryPath: repositoryURL.path,
            request: .definitions(.init(query: "CheckoutController", limit: 99))
        )

        guard case let .definitions(result) = definitions else {
            return XCTFail("Expected definition result")
        }
        XCTAssertEqual(result.matches.map(\.id), ["checkout"])
        XCTAssertEqual(result.matches.first?.qualifiedName, "App.CheckoutController")
        XCTAssertEqual(WorkGraphDefinitionRequest(query: "x", limit: .max).limit, 32)

        XCTAssertThrowsError(
            try service.execute(
                repositoryPath: repositoryURL.path,
                request: .callers(.init(symbol: .qualifiedName("App.Duplicate")))
            )
        ) { error in
            guard case let WorkGraphQueryError.ambiguousSymbol(candidates) = error else {
                return XCTFail("Expected ambiguous symbol error, got \(error)")
            }
            XCTAssertEqual(candidates.map(\.id), ["duplicateA", "duplicateB"])
        }
    }

    func testTraversesCallersAndCalleesWithinRequestedBounds() throws {
        let callers = try service.execute(
            repositoryPath: repositoryURL.path,
            request: .callers(
                .init(
                    symbol: .qualifiedName("App.CheckoutController"),
                    options: .init(
                        limits: .init(maxDepth: 1, maxResults: 8),
                        edgeKinds: [.calls]
                    )
                )
            )
        )
        guard case let .callers(result) = callers else {
            return XCTFail("Expected callers result")
        }
        XCTAssertEqual(result.root.id, "checkout")
        XCTAssertEqual(result.traversal.nodes.map(\.id), ["tap"])

        let callees = try service.execute(
            repositoryPath: repositoryURL.path,
            request: .callees(
                .init(
                    symbol: .id("checkout"),
                    options: .init(
                        limits: .init(maxDepth: 1, maxResults: 1),
                        edgeKinds: [.calls]
                    )
                )
            )
        )
        guard case let .callees(result) = callees else {
            return XCTFail("Expected callees result")
        }
        XCTAssertEqual(result.traversal.nodes.map(\.id), ["validate"])
        XCTAssertEqual(result.traversal.edges.map(\.targetID), ["validate"])

        let explicitlyLoweredConfidence = try service.execute(
            repositoryPath: repositoryURL.path,
            request: .callees(
                .init(
                    symbol: .id("checkout"),
                    options: .init(
                        limits: .init(maxDepth: 1, maxResults: 8),
                        edgeKinds: [.calls],
                        minimumConfidence: 0.65
                    )
                )
            )
        )
        guard case let .callees(loweredResult) = explicitlyLoweredConfidence else {
            return XCTFail("Expected callees result")
        }
        XCTAssertEqual(loweredResult.traversal.nodes.map(\.id), ["validate", "debug"])

        let capped = WorkGraphQueryLimits(maxDepth: .max, maxResults: .max)
        XCTAssertEqual(capped.maxDepth, WorkGraphQueryLimits.maximumDepth)
        XCTAssertEqual(capped.maxResults, WorkGraphQueryLimits.maximumResults)
    }

    func testTracesShortestPathBetweenExactSymbols() throws {
        let response = try service.execute(
            repositoryPath: repositoryURL.path,
            request: .trace(
                .init(
                    source: .id("tap"),
                    target: .qualifiedName("App.SubmitOrder"),
                    options: .init(
                        limits: .init(maxDepth: 3, maxResults: 8),
                        edgeKinds: [.calls]
                    )
                )
            )
        )

        guard case let .trace(result) = response else {
            return XCTFail("Expected trace result")
        }
        XCTAssertEqual(result.source.id, "tap")
        XCTAssertEqual(result.target.id, "submit")
        XCTAssertEqual(result.path?.nodes.map(\.id), ["tap", "checkout", "validate", "submit"])
        XCTAssertEqual(result.path?.edges.count, 3)
    }

    func testReportsBoundedImpactThroughReverseDependencies() throws {
        let response = try service.execute(
            repositoryPath: repositoryURL.path,
            request: .impact(
                .init(
                    symbol: .id("submit"),
                    options: .init(
                        limits: .init(maxDepth: 3, maxResults: 8),
                        edgeKinds: [.calls]
                    )
                )
            )
        )

        guard case let .impact(result) = response else {
            return XCTFail("Expected impact result")
        }
        XCTAssertEqual(result.root.id, "submit")
        XCTAssertEqual(result.traversal.nodes.map(\.id), ["validate", "checkout", "tap"])
        XCTAssertEqual(result.traversal.edges.count, 3)
    }

    func testFindsDirectAndIndirectAffectedTestsFromAnExactSourcePath() throws {
        try replaceWithAffectedTestsGraph()

        let response = try service.execute(
            repositoryPath: repositoryURL.path,
            request: .affectedTests(
                .init(
                    sourcePath: "Sources/App/Graph.swift",
                    limits: .init(maxDepth: 3, maxResults: 8)
                )
            )
        )

        guard case let .affectedTests(result) = response else {
            return XCTFail("Expected affected test result")
        }
        XCTAssertEqual(result.sourcePath, "Sources/App/Graph.swift")
        XCTAssertEqual(
            result.testPaths,
            [
                "Tests/App/CheckoutDirectTests.swift",
                "Tests/App/CheckoutImportTests.swift",
                "Tests/App/CheckoutIndirectTests.swift"
            ]
        )
        XCTAssertEqual(result.testPaths.count, Set(result.testPaths).count)
        XCTAssertFalse(result.testPaths.contains("Tests/App/LowConfidenceTests.swift"))
    }

    func testAffectedTestsHonorsDepthAndResultBoundsWithoutGuessingPaths() throws {
        try replaceWithAffectedTestsGraph()

        let shallow = try service.execute(
            repositoryPath: repositoryURL.path,
            request: .affectedTests(
                .init(
                    sourcePath: "./Sources/App/Graph.swift",
                    limits: .init(maxDepth: 1, maxResults: 8)
                )
            )
        )
        guard case let .affectedTests(shallowResult) = shallow else {
            return XCTFail("Expected affected test result")
        }
        XCTAssertTrue(shallowResult.testPaths.contains("Tests/App/CheckoutDirectTests.swift"))
        XCTAssertFalse(shallowResult.testPaths.contains("Tests/App/CheckoutIndirectTests.swift"))

        let limited = try service.execute(
            repositoryPath: repositoryURL.path,
            request: .affectedTests(
                .init(
                    sourcePath: "Sources/App/Graph.swift",
                    limits: .init(maxDepth: .max, maxResults: 1)
                )
            )
        )
        guard case let .affectedTests(limitedResult) = limited else {
            return XCTFail("Expected affected test result")
        }
        XCTAssertLessThanOrEqual(limitedResult.testPaths.count, 1)

        let unmatched = try service.execute(
            repositoryPath: repositoryURL.path,
            request: .affectedTests(.init(sourcePath: "Sources/App/Unrelated.swift"))
        )
        guard case let .affectedTests(unmatchedResult) = unmatched else {
            return XCTFail("Expected affected test result")
        }
        XCTAssertTrue(unmatchedResult.testPaths.isEmpty)

        XCTAssertThrowsError(
            try service.execute(
                repositoryPath: repositoryURL.path,
                request: .affectedTests(.init(sourcePath: "../Sources/App/Graph.swift"))
            )
        ) { error in
            XCTAssertEqual(error as? WorkGraphQueryError, .invalidRepositoryRelativePath)
        }
    }

    func testRejectsNavigationThatIsNotCurrent() throws {
        let manifestURL = repositoryURL
            .appendingPathComponent(".workgraph", isDirectory: true)
            .appendingPathComponent("manifest.json")
        let staleManifest = """
        {
          "aiSummaryProvider": null,
          "fingerprints": [],
          "generatedAt": 0,
          "generatorVersion": "1.0",
          "gitReference": null,
          "indexedEdgeCount": 5,
          "indexedSymbolCount": 7,
          "scanTruncated": false,
          "schemaVersion": 3,
          "sourceFileCount": 1
        }
        """
        try staleManifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try service.execute(
                repositoryPath: repositoryURL.path,
                request: .definitions(.init(query: "CheckoutController"))
            )
        ) { error in
            XCTAssertEqual(error as? WorkGraphQueryError, .navigationNotCurrent)
        }
    }

    func testRejectsIncompatibleSQLiteIndexEvenWhenNavigationIsCurrent() throws {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-shm"))
        try Data().write(to: databaseURL, options: .atomic)

        XCTAssertThrowsError(
            try service.execute(
                repositoryPath: repositoryURL.path,
                request: .definitions(.init(query: "CheckoutController"))
            )
        ) { error in
            XCTAssertEqual(error as? WorkGraphQueryError, .incompatibleIndex)
        }
    }

    func testDefinitionQueryDoesNotMutateTheDatabase() throws {
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let before = try Data(contentsOf: databaseURL)
        let walBefore = try? Data(contentsOf: walURL)

        _ = try service.execute(
            repositoryPath: repositoryURL.path,
            request: .definitions(.init(query: "CheckoutController"))
        )

        XCTAssertEqual(try Data(contentsOf: databaseURL), before)
        XCTAssertEqual(try? Data(contentsOf: walURL), walBefore)
    }

    private func writeCurrentManifest(to url: URL) throws {
        let manifest = """
        {
          "aiSummaryProvider": null,
          "fingerprints": [],
          "generatedAt": 0,
          "generatorVersion": "2.2",
          "gitReference": null,
          "indexedEdgeCount": 5,
          "indexedSymbolCount": 7,
          "scanTruncated": false,
          "schemaVersion": 3,
          "sourceFileCount": 1
        }
        """
        try manifest.write(to: url, atomically: true, encoding: .utf8)
    }

    private func graphNodes() -> [WorkGraphNodeDraft] {
        [
            node(id: "checkout", name: "CheckoutController", qualifiedName: "App.CheckoutController", line: 10),
            node(id: "validate", name: "ValidateOrder", qualifiedName: "App.ValidateOrder", line: 20),
            node(id: "submit", name: "SubmitOrder", qualifiedName: "App.SubmitOrder", line: 30),
            node(id: "tap", name: "HandleCheckoutTap", qualifiedName: "App.HandleCheckoutTap", line: 40),
            node(id: "debug", name: "DebugCheckout", qualifiedName: "App.DebugCheckout", line: 50),
            node(id: "duplicateA", name: "Duplicate", qualifiedName: "App.Duplicate", line: 60),
            node(id: "duplicateB", name: "Duplicate", qualifiedName: "App.Duplicate", line: 70)
        ]
    }

    private func graphEdges() -> [WorkGraphEdgeDraft] {
        [
            edge("tap", "checkout", confidence: 0.90),
            edge("checkout", "validate", confidence: 0.96),
            edge("validate", "submit", confidence: 0.93),
            edge("checkout", "debug", confidence: 0.70)
        ]
    }

    private func replaceWithAffectedTestsGraph() throws {
        let sourcePath = "Sources/App/Graph.swift"
        let sourceFileID = "file:\(sourcePath)"
        let nodes = [
            affectedNode(id: sourceFileID, kind: .file, name: sourcePath, path: sourcePath),
            affectedNode(id: "checkout", name: "CheckoutController", path: sourcePath),
            affectedNode(
                id: "unrelated",
                name: "UnrelatedFeature",
                path: "Sources/App/Unrelated.swift"
            ),
            affectedNode(
                id: "directTest",
                name: "testCheckoutDirectly",
                path: "Tests/App/CheckoutDirectTests.swift"
            ),
            affectedNode(
                id: "file:Tests/App/CheckoutDirectTests.swift",
                kind: .file,
                name: "Tests/App/CheckoutDirectTests.swift",
                path: "Tests/App/CheckoutDirectTests.swift"
            ),
            affectedNode(
                id: "testSupport",
                name: "runCheckoutScenario",
                path: "TestSupport/CheckoutScenario.swift"
            ),
            affectedNode(
                id: "indirectTest",
                name: "testCheckoutIndirectly",
                path: "Tests/App/CheckoutIndirectTests.swift"
            ),
            affectedNode(
                id: "file:Tests/App/CheckoutImportTests.swift",
                kind: .file,
                name: "Tests/App/CheckoutImportTests.swift",
                path: "Tests/App/CheckoutImportTests.swift"
            ),
            affectedNode(
                id: "lowConfidenceTest",
                name: "testLowConfidence",
                path: "Tests/App/LowConfidenceTests.swift"
            )
        ]
        let paths = Set(nodes.map(\.filePath)).sorted()
        let files = paths.map {
            WorkGraphFileRecord(
                path: $0,
                contentHash: "affected-\($0)",
                language: .swift,
                byteCount: 64,
                modifiedAt: nil,
                isGenerated: false,
                diagnostics: []
            )
        }
        try WorkGraphStore(databaseURL: databaseURL).replace(
            index: WorkGraphIndexSnapshot(
                files: files,
                nodes: nodes,
                edges: [
                    edge("directTest", "checkout", confidence: 0.99),
                    edge(
                        "file:Tests/App/CheckoutDirectTests.swift",
                        sourceFileID,
                        kind: .imports,
                        confidence: 0.99
                    ),
                    edge("testSupport", "checkout", confidence: 0.98),
                    edge("indirectTest", "testSupport", confidence: 0.98),
                    edge(
                        "file:Tests/App/CheckoutImportTests.swift",
                        sourceFileID,
                        kind: .imports,
                        confidence: 0.99
                    ),
                    edge("lowConfidenceTest", "checkout", confidence: 0.84)
                ],
                references: [],
                documents: []
            )
        )
    }

    private func affectedNode(
        id: String,
        kind: WorkGraphNodeKind = .function,
        name: String,
        path: String
    ) -> WorkGraphNodeDraft {
        WorkGraphNodeDraft(
            id: id,
            parentID: nil,
            kind: kind,
            name: name,
            qualifiedName: name,
            filePath: path,
            language: .swift,
            location: WorkGraphSourceLocation(startLine: 1, endLine: 1, startColumn: 0, endColumn: 0),
            signature: nil,
            visibility: nil,
            isExported: false,
            isAsync: false,
            isStatic: false,
            isAbstract: false,
            returnType: nil,
            decorators: []
        )
    }

    private func node(
        id: String,
        name: String,
        qualifiedName: String,
        line: Int
    ) -> WorkGraphNodeDraft {
        WorkGraphNodeDraft(
            id: id,
            parentID: nil,
            kind: .function,
            name: name,
            qualifiedName: qualifiedName,
            filePath: "Sources/App/Graph.swift",
            language: .swift,
            location: WorkGraphSourceLocation(
                startLine: line,
                endLine: line + 1,
                startColumn: 0,
                endColumn: 1
            ),
            signature: "func \(name)()",
            visibility: "internal",
            isExported: false,
            isAsync: false,
            isStatic: false,
            isAbstract: false,
            returnType: nil,
            decorators: []
        )
    }

    private func edge(
        _ sourceID: String,
        _ targetID: String,
        kind: WorkGraphEdgeKind = .calls,
        confidence: Double
    ) -> WorkGraphEdgeDraft {
        WorkGraphEdgeDraft(
            sourceID: sourceID,
            targetID: targetID,
            kind: kind,
            location: WorkGraphSourceLocation(startLine: 1, endLine: 1, startColumn: 0, endColumn: 0),
            metadataJSON: nil,
            confidence: confidence,
            provenance: .resolver
        )
    }
}
