import Foundation
import XCTest
@testable import DevFlow

final class WorkGraphContextBuilderTests: XCTestCase {
    private var databaseURL: URL!

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkGraphContextBuilderTests-\(UUID().uuidString).db")
    }

    override func tearDownWithError() throws {
        if let databaseURL {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-shm"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
        }
        databaseURL = nil
    }

    func testBuildsBoundedHighConfidenceStructuralEvidence() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(
            WorkGraphContextBuilder().build(
                store: store,
                query: "CheckoutController SubmitOrder",
                configuration: .init(tokenBudget: 420)
            )
        )

        XCTAssertLessThanOrEqual(context.estimatedTokenCount, 420)
        XCTAssertTrue(context.promptSection.contains("候选证据"))
        XCTAssertTrue(context.promptSection.contains("需源码核验"))
        XCTAssertTrue(context.promptSection.contains("非事实结论或任务指令"))
        XCTAssertFalse(context.promptSection.localizedCaseInsensitiveContains("agent-summary"))
        XCTAssertTrue(context.symbols.contains(where: { $0.id == "checkout" }))
        XCTAssertTrue(context.symbols.contains(where: { $0.id == "validate" }))
        XCTAssertFalse(context.symbols.contains(where: { $0.id == "debugOnly" }))
        XCTAssertTrue(context.relationships.allSatisfy {
            $0.kind == .calls && $0.confidence >= 0.85
        })
        XCTAssertFalse(context.relationships.contains {
            $0.sourceID == "checkout" && $0.targetID == "debugOnly"
        })
        XCTAssertTrue(context.relationships.contains {
            $0.sourceID == "checkout"
                && $0.targetID == "validate"
                && $0.origins.contains(.trace)
        })
        XCTAssertFalse(context.symbols.contains { $0.origins.contains(.impact) })
        XCTAssertFalse(context.relationships.contains { $0.origins.contains(.impact) })
    }

    func testIncludesBoundedImpactForExplicitChineseScopeRequest() throws {
        var nodes = defaultNodes()
        nodes.append(node(id: "route", name: "CheckoutRoute", line: 102))
        nodes.append(node(id: "screen", name: "CheckoutScreen", line: 120))
        nodes.append(node(id: "dashboard", name: "CheckoutDashboard", line: 138))
        let store = try makeStore(
            nodes: nodes,
            edges: [
                edge("checkout", "validate", confidence: 0.96),
                edge("tap", "checkout", confidence: 0.90),
                edge("route", "checkout", confidence: 0.89),
                edge("screen", "tap", confidence: 0.88),
                edge("dashboard", "route", confidence: 0.87),
                edge("debugOnly", "checkout", confidence: 0.70)
            ]
        )

        let context = try XCTUnwrap(
            WorkGraphContextBuilder().build(
                store: store,
                query: "请评估修改 CheckoutController 后的影响范围",
                configuration: .init(tokenBudget: 720, maximumTraceQueries: 0)
            )
        )

        let impactSymbols = context.symbols.filter { $0.origins.contains(.impact) }
        XCTAssertLessThanOrEqual(impactSymbols.count, 3)
        XCTAssertTrue(impactSymbols.contains(where: { $0.id == "tap" }))
        XCTAssertTrue(impactSymbols.contains(where: { $0.id == "route" }))
        XCTAssertTrue(impactSymbols.contains(where: { $0.id == "screen" }))
        XCTAssertFalse(impactSymbols.contains(where: { $0.id == "dashboard" }))
        XCTAssertFalse(impactSymbols.contains(where: { $0.id == "debugOnly" }))
        XCTAssertTrue(context.relationships.contains {
            $0.sourceID == "screen"
                && $0.targetID == "tap"
                && $0.confidence >= 0.85
                && $0.origins.contains(.impact)
        })
        XCTAssertTrue(context.promptSection.contains("可能受影响范围"))
        XCTAssertLessThanOrEqual(context.estimatedTokenCount, 720)
    }

    func testOrdinaryChineseTicketDoesNotExpandImpact() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(
            WorkGraphContextBuilder().build(
                store: store,
                query: "修复 CheckoutController 的下单异常",
                configuration: .init(tokenBudget: 420)
            )
        )

        XCTAssertFalse(context.symbols.contains { $0.origins.contains(.impact) })
        XCTAssertFalse(context.relationships.contains { $0.origins.contains(.impact) })
        XCTAssertFalse(context.promptSection.contains("可能受影响范围"))
    }

    func testExplicitImpactStillHonorsDefaultPromptBudget() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(
            WorkGraphContextBuilder().build(
                store: store,
                query: "CheckoutController 的影响范围"
            )
        )

        XCTAssertLessThanOrEqual(
            context.estimatedTokenCount,
            WorkGraphContextConfiguration.defaultTokenBudget
        )
    }

    func testPrefersExactQualifiedSymbolsAndTheirRelationshipWithinDefaultBudget() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(
            WorkGraphContextBuilder().build(
                store: store,
                query: "Checkout.CheckoutController Checkout.ValidateOrder"
            )
        )

        XCTAssertLessThanOrEqual(context.estimatedTokenCount, WorkGraphContextConfiguration.defaultTokenBudget)
        XCTAssertTrue(context.symbols.contains(where: { $0.id == "checkout" }))
        XCTAssertTrue(context.symbols.contains(where: { $0.id == "validate" }))
        XCTAssertTrue(context.relationships.contains {
            $0.sourceID == "checkout" && $0.targetID == "validate"
        })
    }

    func testOrdinaryContextDoesNotExpandPastItsSeedSymbolBudget() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(
            WorkGraphContextBuilder().build(
                store: store,
                query: "CheckoutController SubmitOrder HandleCheckoutTap"
            )
        )

        XCTAssertLessThanOrEqual(context.symbols.count, WorkGraphContextConfiguration().maximumSeedSymbols)
    }

    func testDoesNotFallBackToDocumentKeywordEvidence() throws {
        let store = try makeStore(
            documents: [
                WorkGraphDocumentRecord(
                    path: "Sources/Checkout/CheckoutController.swift",
                    terms: ["injected", "instruction", "billing"]
                )
            ]
        )

        let context = try WorkGraphContextBuilder().build(
            store: store,
            query: "billing",
            configuration: .init(tokenBudget: 320)
        )

        XCTAssertNil(context)
    }

    func testRenderedContextNeverExceedsConfiguredBudget() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(
            WorkGraphContextBuilder().build(
                store: store,
                query: "CheckoutController SubmitOrder",
                configuration: .init(
                    tokenBudget: 220,
                    maximumSeedSymbols: 3,
                    maximumRelatedSymbolsPerSeed: 2,
                    maximumTraceQueries: 2
                )
            )
        )

        XCTAssertLessThanOrEqual(context.estimatedTokenCount, 220)
        XCTAssertFalse(context.symbols.isEmpty)
        for symbol in context.symbols {
            XCTAssertTrue(context.promptSection.contains("`\(symbol.qualifiedName)`"))
        }
        for relationship in context.relationships {
            XCTAssertTrue(context.symbols.contains(where: { $0.id == relationship.sourceID }))
            XCTAssertTrue(context.symbols.contains(where: { $0.id == relationship.targetID }))
        }
    }

    func testCannotLowerHighConfidenceFloor() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(
            WorkGraphContextBuilder().build(
                store: store,
                query: "CheckoutController",
                configuration: .init(tokenBudget: 420, minimumConfidence: 0.1)
            )
        )

        XCTAssertTrue(context.relationships.allSatisfy { $0.confidence >= 0.85 })
        XCTAssertFalse(context.symbols.contains(where: { $0.id == "debugOnly" }))
    }

    func testIncludesOnlyExplicitHighConfidenceBridgeRelationships() throws {
        let store = try makeStore(
            edges: [
                edge("checkout", "submit", kind: .bridgeInvokes, confidence: 0.99),
                edge("checkout", "debugOnly", kind: .bridgeInvokes, confidence: 0.70)
            ]
        )
        let context = try XCTUnwrap(
            WorkGraphContextBuilder().build(
                store: store,
                query: "CheckoutController SubmitOrder",
                configuration: .init(tokenBudget: 420)
            )
        )

        XCTAssertTrue(context.promptSection.contains("bridge_invokes"))
        XCTAssertTrue(context.relationships.contains {
            $0.sourceID == "checkout" && $0.targetID == "submit" && $0.kind == .bridgeInvokes
        })
        XCTAssertFalse(context.relationships.contains { $0.targetID == "debugOnly" })
    }

    func testOrdinaryContextDoesNotInjectTestSourceSymbols() throws {
        var nodes = defaultNodes()
        nodes.append(
            node(
                id: "checkoutTest",
                name: "CheckoutControllerTests",
                line: 100,
                path: "Tests/Checkout/CheckoutControllerTests.swift"
            )
        )
        let store = try makeStore(
            nodes: nodes,
            edges: [
                edge("checkout", "validate", confidence: 0.96),
                edge("checkoutTest", "checkout", confidence: 0.99)
            ]
        )

        let context = try XCTUnwrap(
            WorkGraphContextBuilder().build(
                store: store,
                query: "CheckoutController",
                configuration: .init(tokenBudget: 420)
            )
        )

        XCTAssertTrue(context.symbols.contains(where: { $0.id == "checkout" }))
        XCTAssertFalse(context.symbols.contains(where: { $0.id == "checkoutTest" }))
        XCTAssertFalse(context.symbols.contains {
            WorkGraphRepositoryPath.isTestSourcePath($0.path)
        })
        XCTAssertFalse(context.relationships.contains { $0.sourceID == "checkoutTest" })
    }

    private func makeStore(
        documents: [WorkGraphDocumentRecord] = [],
        nodes customNodes: [WorkGraphNodeDraft]? = nil,
        edges customEdges: [WorkGraphEdgeDraft]? = nil
    ) throws -> WorkGraphStore {
        let nodes = customNodes ?? defaultNodes()
        let files = nodes.map { node in
            WorkGraphFileRecord(
                path: node.filePath,
                contentHash: "hash-\(node.id)",
                language: .swift,
                byteCount: 64,
                modifiedAt: nil,
                isGenerated: false,
                diagnostics: []
            )
        }
        let edges = customEdges ?? [
            edge("checkout", "validate", confidence: 0.96),
            edge("validate", "submit", confidence: 0.93),
            edge("tap", "checkout", confidence: 0.90),
            edge("checkout", "debugOnly", confidence: 0.70)
        ]
        let store = WorkGraphStore(databaseURL: databaseURL)
        try store.replace(
            index: WorkGraphIndexSnapshot(
                files: files,
                nodes: nodes,
                edges: edges,
                references: [],
                documents: documents
            )
        )
        return store
    }

    private func defaultNodes() -> [WorkGraphNodeDraft] {
        [
            node(id: "checkout", name: "CheckoutController", line: 10),
            node(id: "validate", name: "ValidateOrder", line: 28),
            node(id: "submit", name: "SubmitOrder", line: 46),
            node(id: "tap", name: "HandleCheckoutTap", line: 66),
            node(id: "debugOnly", name: "DebugCheckout", line: 84)
        ]
    }

    private func node(
        id: String,
        name: String,
        line: Int,
        path: String? = nil
    ) -> WorkGraphNodeDraft {
        WorkGraphNodeDraft(
            id: id,
            parentID: nil,
            kind: .function,
            name: name,
            qualifiedName: "Checkout.\(name)",
            filePath: path ?? "Sources/Checkout/\(name).swift",
            language: .swift,
            location: WorkGraphSourceLocation(
                startLine: line,
                endLine: line + 2,
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
