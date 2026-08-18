import Foundation
import XCTest
@testable import DevFlow

final class WorkGraphQueryTests: XCTestCase {
    private var databaseURL: URL!

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkGraphQueryTests-\(UUID().uuidString).db")
    }

    override func tearDownWithError() throws {
        if let databaseURL {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
        }
        databaseURL = nil
    }

    func testCallersAndCalleesRespectExactEdgeKindsAndConfidence() throws {
        let store = try makeStore()

        let highConfidenceCallees = try store.callees(
            of: "a",
            edgeKinds: [.calls],
            minimumConfidence: 0.85,
            maxDepth: 1,
            limit: 8
        )
        XCTAssertEqual(highConfidenceCallees.nodes.map(\.id), ["b"])
        XCTAssertEqual(highConfidenceCallees.edges.map(\.kind), [.calls])

        let container = try store.callers(
            of: "a",
            edgeKinds: [.contains],
            minimumConfidence: 1,
            maxDepth: 1,
            limit: 8
        )
        XCTAssertEqual(container.nodes.map(\.id), ["file"])

        let contains = try store.callees(
            of: "file",
            edgeKinds: [.contains],
            minimumConfidence: 1,
            maxDepth: 1,
            limit: 8
        )
        XCTAssertEqual(contains.nodes.map(\.id), ["a"])

        let includingLowConfidence = try store.callees(
            of: "a",
            edgeKinds: [.calls],
            minimumConfidence: 0.65,
            maxDepth: 1,
            limit: 8
        )
        XCTAssertEqual(includingLowConfidence.nodes.map(\.id), ["b", "d"])
    }

    func testTraversalHonorsDepthAndDeduplicatesCycles() throws {
        let store = try makeStore()

        let oneHop = try store.callees(
            of: "a",
            edgeKinds: [.calls],
            maxDepth: 1,
            limit: 8
        )
        XCTAssertEqual(oneHop.nodes.map(\.id), ["b"])

        let cyclic = try store.callees(
            of: "a",
            edgeKinds: [.calls],
            maxDepth: 4,
            limit: 8
        )
        XCTAssertEqual(cyclic.nodes.map(\.id), ["b", "c"])
        XCTAssertEqual(cyclic.edges.count, 2)
        XCTAssertFalse(cyclic.nodes.contains(where: { $0.id == "a" }))

        let limited = try store.callers(
            of: "c",
            edgeKinds: [.calls],
            maxDepth: 4,
            limit: 1
        )
        XCTAssertEqual(limited.nodes.map(\.id), ["b"])
        XCTAssertEqual(limited.edges.count, 1)
    }

    func testTraceUsesBoundedHighConfidenceShortestPath() throws {
        let store = try makeStore()

        let trace = try store.trace(
            from: "a",
            to: "c",
            edgeKinds: [.calls],
            maxDepth: 2,
            maxNodes: 8
        )
        XCTAssertEqual(trace?.nodes.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(trace?.edges.map(\.kind), [.calls, .calls])

        let depthLimited = try store.trace(
            from: "a",
            to: "c",
            edgeKinds: [.calls],
            maxDepth: 1,
            maxNodes: 8
        )
        XCTAssertNil(depthLimited)

        let lowConfidenceFiltered = try store.trace(
            from: "a",
            to: "e",
            edgeKinds: [.calls],
            minimumConfidence: 0.85,
            maxDepth: 2,
            maxNodes: 8
        )
        XCTAssertNil(lowConfidenceFiltered)

        let lowConfidenceAllowed = try store.trace(
            from: "a",
            to: "e",
            edgeKinds: [.calls],
            minimumConfidence: 0.65,
            maxDepth: 2,
            maxNodes: 8
        )
        XCTAssertEqual(lowConfidenceAllowed?.nodes.map(\.id), ["a", "d", "e"])
    }

    func testImpactWalksReverseDependenciesWithoutRevisitingRoot() throws {
        let store = try makeStore()

        let impact = try store.impact(
            of: "c",
            edgeKinds: [.calls],
            minimumConfidence: 0.85,
            maxDepth: 4,
            maxNodes: 8
        )
        XCTAssertEqual(impact.nodes.map(\.id), ["b", "a"])
        XCTAssertEqual(Set(impact.nodes.map(\.id)).count, impact.nodes.count)
        XCTAssertFalse(impact.nodes.contains(where: { $0.id == "c" }))
    }

    private func makeStore() throws -> WorkGraphStore {
        let files = ["file", "a", "b", "c", "d", "e"].map { id in
            WorkGraphFileRecord(
                path: "Sources/\(id).swift",
                contentHash: "hash-\(id)",
                language: .swift,
                byteCount: 32,
                modifiedAt: nil,
                isGenerated: false,
                diagnostics: []
            )
        }
        let nodes = [
            node(id: "file", kind: .file),
            node(id: "a"),
            node(id: "b"),
            node(id: "c"),
            node(id: "d"),
            node(id: "e")
        ]
        let edges = [
            edge("file", "a", .contains),
            edge("a", "b", .calls),
            edge("a", "d", .calls, confidence: 0.7),
            edge("b", "c", .calls, confidence: 0.95),
            edge("c", "a", .calls),
            edge("d", "e", .calls)
        ]
        let store = WorkGraphStore(databaseURL: databaseURL)
        try store.replace(
            index: WorkGraphIndexSnapshot(
                files: files,
                nodes: nodes,
                edges: edges,
                references: [],
                documents: []
            )
        )
        return store
    }

    private func node(
        id: String,
        kind: WorkGraphNodeKind = .function
    ) -> WorkGraphNodeDraft {
        WorkGraphNodeDraft(
            id: id,
            parentID: nil,
            kind: kind,
            name: id,
            qualifiedName: "App.\(id)",
            filePath: "Sources/\(id).swift",
            language: .swift,
            location: WorkGraphSourceLocation(startLine: 1, endLine: 1, startColumn: 0, endColumn: 0),
            signature: "func \(id)()",
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
        _ kind: WorkGraphEdgeKind,
        confidence: Double = 1
    ) -> WorkGraphEdgeDraft {
        WorkGraphEdgeDraft(
            sourceID: sourceID,
            targetID: targetID,
            kind: kind,
            location: WorkGraphSourceLocation(startLine: 1, endLine: 1, startColumn: 0, endColumn: 0),
            metadataJSON: nil,
            confidence: confidence,
            provenance: .ast
        )
    }
}
