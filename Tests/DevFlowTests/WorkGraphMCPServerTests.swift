import Foundation
import XCTest
@testable import DevFlow

final class WorkGraphMCPServerTests: XCTestCase {
    private var repositoryURL: URL!
    private var server: WorkGraphMCPServer!

    override func setUpWithError() throws {
        repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkGraphMCPServerTests-\(UUID().uuidString)", isDirectory: true)
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

        let graphURL = repositoryURL.appendingPathComponent("Sources/App/Graph.swift")
        let testURL = repositoryURL.appendingPathComponent("Tests/App/CheckoutTests.swift")
        try FileManager.default.createDirectory(at: graphURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        final class CheckoutController {
            func validate() {}
        }
        """.write(to: graphURL, atomically: true, encoding: .utf8)
        try "func testCheckout() {}\n".write(to: testURL, atomically: true, encoding: .utf8)

        try WorkGraphStore(databaseURL: workgraphURL.appendingPathComponent(WorkGraphStore.fileName)).replace(
            index: WorkGraphIndexSnapshot(
                files: [
                    try fileRecord(for: graphURL, path: "Sources/App/Graph.swift"),
                    try fileRecord(for: testURL, path: "Tests/App/CheckoutTests.swift")
                ],
                nodes: [
                    node(id: "checkout", name: "CheckoutController", qualifiedName: "App.CheckoutController"),
                    node(id: "caller", name: "HandleCheckout", qualifiedName: "App.HandleCheckout"),
                    node(id: "target", name: "ValidateOrder", qualifiedName: "App.ValidateOrder"),
                    node(
                        id: "test",
                        name: "testCheckout",
                        qualifiedName: "Tests.testCheckout",
                        path: "Tests/App/CheckoutTests.swift"
                    )
                ],
                edges: [
                    edge("caller", "checkout"),
                    edge("checkout", "target"),
                    edge("test", "checkout")
                ],
                references: [],
                documents: []
            )
        )
        server = WorkGraphMCPServer()
    }

    override func tearDownWithError() throws {
        if let repositoryURL {
            try? FileManager.default.removeItem(at: repositoryURL)
        }
        repositoryURL = nil
        server = nil
    }

    func testInitializeAndListExposeBoundedWorkGraphTools() throws {
        let initialize = try response(
            for: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": ["protocolVersion": "2024-11-05"]
            ]
        )
        let initializeResult = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertEqual(initializeResult["protocolVersion"] as? String, "2024-11-05")
        XCTAssertEqual((initializeResult["serverInfo"] as? [String: Any])?["name"] as? String, "devflow-workgraph")
        XCTAssertEqual((initializeResult["serverInfo"] as? [String: Any])?["version"] as? String, "1.2")
        XCTAssertTrue((initializeResult["instructions"] as? String)?.contains("explore") == true)

        let list = try response(for: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let result = try XCTUnwrap(list["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, [
            "explore", "search", "definitions", "node", "callers", "callees", "trace",
            "impact", "affected_tests", "files", "status"
        ])
        XCTAssertTrue(tools.allSatisfy { tool in
            let schema = tool["inputSchema"] as? [String: Any]
            let required = schema?["required"] as? [String]
            return required?.contains("repositoryPath") == true
        })
    }

    func testDefinitionsToolRequiresExplicitRepositoryAndReturnsStructuredPayload() throws {
        let definitionResponse = try self.response(for: [
            "jsonrpc": "2.0",
            "id": "definitions",
            "method": "tools/call",
            "params": [
                "name": "definitions",
                "arguments": [
                    "repositoryPath": repositoryURL.path,
                    "query": "CheckoutController"
                ]
            ]
        ])
        let result = try XCTUnwrap(definitionResponse["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let definitions = try XCTUnwrap(structured["definitions"] as? [String: Any])
        let matches = try XCTUnwrap(definitions["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.first?["qualifiedName"] as? String, "App.CheckoutController")

        let missingRepository = try response(for: [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": "definitions",
                "arguments": ["query": "CheckoutController"]
            ]
        ])
        let errorResult = try XCTUnwrap(missingRepository["result"] as? [String: Any])
        XCTAssertEqual(errorResult["isError"] as? Bool, true)
        let content = try XCTUnwrap(errorResult["content"] as? [[String: Any]])
        let text = content.first.flatMap { $0["text"] as? String }
        XCTAssertTrue(text?.contains("repositoryPath") == true)
    }

    func testSearchToolMatchesCodeGraphSurfaceAndReturnsSearchPayload() throws {
        let response = try self.response(for: [
            "jsonrpc": "2.0",
            "id": "search",
            "method": "tools/call",
            "params": [
                "name": "search",
                "arguments": [
                    "repositoryPath": repositoryURL.path,
                    "query": "CheckoutController"
                ]
            ]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let search = try XCTUnwrap(structured["search"] as? [String: Any])
        let matches = try XCTUnwrap(search["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.first?["qualifiedName"] as? String, "App.CheckoutController")
    }

    func testEveryTraversalToolRoutesToTheQueryFacade() throws {
        let repositoryPath = repositoryURL.path
        let calls: [(String, [String: Any], String)] = [
            (
                "callers",
                ["repositoryPath": repositoryPath, "symbol": ["id": "checkout"]],
                "callers"
            ),
            (
                "callees",
                ["repositoryPath": repositoryPath, "symbol": ["id": "checkout"]],
                "callees"
            ),
            (
                "trace",
                [
                    "repositoryPath": repositoryPath,
                    "source": ["id": "caller"],
                    "target": ["id": "target"]
                ],
                "trace"
            ),
            (
                "impact",
                ["repositoryPath": repositoryPath, "symbol": ["id": "target"]],
                "impact"
            ),
            (
                "affected_tests",
                ["repositoryPath": repositoryPath, "sourcePath": "Sources/App/Graph.swift"],
                "affectedTests"
            )
        ]

        for (index, call) in calls.enumerated() {
            let response = try self.response(for: [
                "jsonrpc": "2.0",
                "id": index + 10,
                "method": "tools/call",
                "params": ["name": call.0, "arguments": call.1]
            ])
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, false, "\(call.0) should succeed")
            let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
            XCTAssertNotNil(structured[call.2], "\(call.0) should return its own payload")
        }
    }

    func testTraversalAcceptsJSONIntegerLimitsAndRejectsBooleanLimits() throws {
        let accepted = try response(for: [
            "jsonrpc": "2.0",
            "id": "integer-limits",
            "method": "tools/call",
            "params": [
                "name": "callees",
                "arguments": [
                    "repositoryPath": repositoryURL.path,
                    "symbol": ["id": "checkout"],
                    "maxDepth": 1,
                    "maxResults": 8
                ]
            ]
        ])
        XCTAssertEqual((accepted["result"] as? [String: Any])?["isError"] as? Bool, false)

        let rejected = try response(for: [
            "jsonrpc": "2.0",
            "id": "boolean-limit",
            "method": "tools/call",
            "params": [
                "name": "callees",
                "arguments": [
                    "repositoryPath": repositoryURL.path,
                    "symbol": ["id": "checkout"],
                    "maxDepth": true
                ]
            ]
        ])
        XCTAssertEqual((rejected["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    func testInspectionToolsReturnCurrentSourceAndRefuseStaleSource() throws {
        let repositoryPath = repositoryURL.path

        let status = try response(for: [
            "jsonrpc": "2.0",
            "id": "status",
            "method": "tools/call",
            "params": ["name": "status", "arguments": ["repositoryPath": repositoryPath]]
        ])
        let statusResult = try XCTUnwrap(status["result"] as? [String: Any])
        let statusPayload = try XCTUnwrap(statusResult["structuredContent"] as? [String: Any])
        let statusValue = try XCTUnwrap(statusPayload["status"] as? [String: Any])
        XCTAssertEqual(statusValue["isQueryable"] as? Bool, true)
        XCTAssertEqual(statusValue["state"] as? String, "current")

        let files = try response(for: [
            "jsonrpc": "2.0",
            "id": "files",
            "method": "tools/call",
            "params": [
                "name": "files",
                "arguments": ["repositoryPath": repositoryPath, "pathPrefix": "Sources"]
            ]
        ])
        let filesPayload = try XCTUnwrap((files["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
        let fileRows = try XCTUnwrap(filesPayload["files"] as? [[String: Any]])
        XCTAssertEqual(fileRows.map { (($0["file"] as? [String: Any])?["path"] as? String) }, ["Sources/App/Graph.swift"])
        XCTAssertEqual(fileRows.first?["isCurrent"] as? Bool, true)

        let node = try response(for: [
            "jsonrpc": "2.0",
            "id": "node",
            "method": "tools/call",
            "params": [
                "name": "node",
                "arguments": [
                    "repositoryPath": repositoryPath,
                    "symbol": ["id": "checkout"],
                    "maxLines": 8
                ]
            ]
        ])
        let nodePayload = try XCTUnwrap((node["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
        let nodeValue = try XCTUnwrap(nodePayload["node"] as? [String: Any])
        XCTAssertEqual(nodeValue["isCurrent"] as? Bool, true)
        XCTAssertTrue((nodeValue["source"] as? String)?.contains("1\tfinal class CheckoutController") == true)

        let explore = try response(for: [
            "jsonrpc": "2.0",
            "id": "explore",
            "method": "tools/call",
            "params": [
                "name": "explore",
                "arguments": ["repositoryPath": repositoryPath, "query": "CheckoutController"]
            ]
        ])
        let explorePayload = try XCTUnwrap((explore["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
        let exploreValue = try XCTUnwrap(explorePayload["explore"] as? [String: Any])
        let exploreFiles = try XCTUnwrap(exploreValue["files"] as? [[String: Any]])
        XCTAssertEqual((exploreFiles.first?["file"] as? [String: Any])?["path"] as? String, "Sources/App/Graph.swift")
        XCTAssertNotNil(exploreFiles.first?["source"] as? String)

        let graphURL = repositoryURL.appendingPathComponent("Sources/App/Graph.swift")
        try "final class CheckoutController { func validate() { print(\"changed\") } }\n".write(
            to: graphURL,
            atomically: true,
            encoding: .utf8
        )
        let refreshedNode = try response(for: [
            "jsonrpc": "2.0",
            "id": "refreshed-node",
            "method": "tools/call",
            "params": [
                "name": "node",
                "arguments": ["repositoryPath": repositoryPath, "path": "Sources/App/Graph.swift"]
            ]
        ])
        let refreshedPayload = try XCTUnwrap((refreshedNode["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
        let refreshedValue = try XCTUnwrap(refreshedPayload["node"] as? [String: Any])
        XCTAssertEqual(refreshedValue["isCurrent"] as? Bool, true)
        XCTAssertTrue((refreshedValue["source"] as? String)?.contains("print(\"changed\")") == true)
    }

    func testNotificationsAndUnknownMethodsFollowJSONRPCRules() throws {
        let notification = server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        XCTAssertNil(notification)

        let unknown = try response(for: ["jsonrpc": "2.0", "id": 8, "method": "unknown"])
        let error = try XCTUnwrap(unknown["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)

        let invalid = try XCTUnwrap(server.handle(Data("not-json".utf8)))
        let parseError = try XCTUnwrap(jsonObject(invalid)["error"] as? [String: Any])
        XCTAssertEqual(parseError["code"] as? Int, -32700)
    }

    private func response(for object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let output = server.handle(data) else {
            throw XCTSkip("Expected a JSON-RPC response")
        }
        return jsonObject(output)
    }

    private func jsonObject(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func writeCurrentManifest(to url: URL) throws {
        let manifest = """
        {
          "aiSummaryProvider": null,
          "fingerprints": [],
          "generatedAt": 0,
          "generatorVersion": "2.2",
          "gitReference": null,
          "indexedEdgeCount": 0,
          "indexedSymbolCount": 1,
          "scanTruncated": false,
          "schemaVersion": 3,
          "sourceFileCount": 1
        }
        """
        try manifest.write(to: url, atomically: true, encoding: .utf8)
    }

    private func node(
        id: String,
        name: String,
        qualifiedName: String,
        path: String = "Sources/App/Graph.swift"
    ) -> WorkGraphNodeDraft {
        WorkGraphNodeDraft(
            id: id,
            parentID: nil,
            kind: .function,
            name: name,
            qualifiedName: qualifiedName,
            filePath: path,
            language: .swift,
            location: .init(startLine: 1, endLine: 5, startColumn: 0, endColumn: 1),
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

    private func edge(_ sourceID: String, _ targetID: String) -> WorkGraphEdgeDraft {
        WorkGraphEdgeDraft(
            sourceID: sourceID,
            targetID: targetID,
            kind: .calls,
            location: nil,
            metadataJSON: nil,
            confidence: 0.99,
            provenance: .resolver
        )
    }

    private func fileRecord(for url: URL, path: String) throws -> WorkGraphFileRecord {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return WorkGraphFileRecord(
            path: path,
            contentHash: path,
            language: .swift,
            byteCount: try XCTUnwrap(values.fileSize),
            modifiedAt: try XCTUnwrap(values.contentModificationDate),
            isGenerated: false,
            diagnostics: []
        )
    }
}
