import Foundation
import XCTest
@testable import DevFlow

final class WorkGraphEndToEndTests: XCTestCase {
    private var repositoryURL: URL!

    override func setUpWithError() throws {
        repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkGraphEndToEndTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let repositoryURL {
            try? FileManager.default.removeItem(at: repositoryURL)
        }
        repositoryURL = nil
    }

    func testGeneratesMultilanguageGraphAndServesStructuralQueries() throws {
        try writeFixtureRepository()
        let extractor = RecordingExtractor(try bundledRuntime())
        let navigation = ProjectNavigationService(parserRuntime: extractor)

        let workgraphPath = try navigation.generateBaseNavigation(repositoryPath: repositoryURL.path)
        XCTAssertEqual(workgraphPath, ProjectNavigationService.workgraphPath(for: repositoryURL.path))
        XCTAssertTrue(isCurrent(navigation.status(for: repositoryURL.path)))

        let workgraphURL = URL(fileURLWithPath: workgraphPath, isDirectory: true)
        let nodes = try readJSONLines(WorkGraphNodeDraft.self, from: workgraphURL.appendingPathComponent("symbols.jsonl"))
        let edges = try readJSONLines(WorkGraphEdgeDraft.self, from: workgraphURL.appendingPathComponent("edges.jsonl"))

        XCTAssertEqual(
            Set(extractor.extractedPaths),
            Set(fixtureSourcePaths + ["test/dart_entry_test.dart"])
        )
        assertExtractedSymbols(nodes, existFor: [
            ("src/dart/Api.dart", .dart),
            ("src/dart/Main.dart", .dart),
            ("src/swift/Bridge.swift", .swift),
            ("src/objc/Flow.m", .objectiveC),
            ("src/kotlin/Flow.kt", .kotlin),
            ("src/java/JavaFlow.java", .java),
            ("src/c/Flow.c", .c),
            ("src/cpp/Flow.cpp", .cpp),
            ("src/ark/Flow.ets", .arkTS)
        ])
        XCTAssertTrue(edges.contains { $0.kind == .calls })
        XCTAssertTrue(edges.contains { $0.kind == .imports })
        XCTAssertTrue(edges.contains { $0.kind == .bridgeInvokes })

        let dartEntry = try node(named: "dartEntry", in: "src/dart/Main.dart", from: nodes)
        let apiValue = try node(named: "apiValue", in: "src/dart/Api.dart", from: nodes)
        let configureChannel = try node(named: "configureChannel", in: "src/swift/Bridge.swift", from: nodes)
        let bridgeHandler = try XCTUnwrap(nodes.first {
            $0.kind == .bridgeHandler && $0.name == "e2e.channel.ping"
        })
        let query = WorkGraphQueryService()

        let definitions = try query.execute(
            repositoryPath: repositoryURL.path,
            request: .definitions(.init(query: "dartEntry"))
        )
        guard case let .definitions(definitionResult) = definitions else {
            return XCTFail("Expected definition result")
        }
        XCTAssertTrue(definitionResult.matches.contains { $0.id == dartEntry.id })

        let callers = try query.execute(
            repositoryPath: repositoryURL.path,
            request: .callers(
                .init(
                    symbol: .id(apiValue.id),
                    options: .init(
                        limits: .init(maxDepth: 2, maxResults: 12),
                        edgeKinds: [.calls]
                    )
                )
            )
        )
        guard case let .callers(callersResult) = callers else {
            return XCTFail("Expected callers result")
        }
        XCTAssertEqual(callersResult.root.id, apiValue.id)
        XCTAssertTrue(callersResult.traversal.nodes.contains { $0.id == dartEntry.id })

        let callees = try query.execute(
            repositoryPath: repositoryURL.path,
            request: .callees(
                .init(
                    symbol: .id(dartEntry.id),
                    options: .init(
                        limits: .init(maxDepth: 1, maxResults: 12),
                        edgeKinds: [.calls, .bridgeInvokes]
                    )
                )
            )
        )
        guard case let .callees(calleesResult) = callees else {
            return XCTFail("Expected callees result")
        }
        XCTAssertTrue(calleesResult.traversal.nodes.contains { $0.id == apiValue.id })
        XCTAssertTrue(calleesResult.traversal.nodes.contains { $0.id == bridgeHandler.id })

        let trace = try query.execute(
            repositoryPath: repositoryURL.path,
            request: .trace(
                .init(
                    source: .id(dartEntry.id),
                    target: .id(configureChannel.id),
                    options: .init(
                        limits: .init(maxDepth: 3, maxResults: 12),
                        edgeKinds: [.bridgeInvokes]
                    )
                )
            )
        )
        guard case let .trace(traceResult) = trace else {
            return XCTFail("Expected trace result")
        }
        XCTAssertEqual(traceResult.path?.nodes.map(\.id), [dartEntry.id, bridgeHandler.id, configureChannel.id])
        XCTAssertEqual(traceResult.path?.edges.map(\.kind), [.bridgeInvokes, .bridgeInvokes])

        let impact = try query.execute(
            repositoryPath: repositoryURL.path,
            request: .impact(
                .init(
                    symbol: .id(configureChannel.id),
                    options: .init(
                        limits: .init(maxDepth: 3, maxResults: 12),
                        edgeKinds: [.bridgeInvokes]
                    )
                )
            )
        )
        guard case let .impact(impactResult) = impact else {
            return XCTFail("Expected impact result")
        }
        XCTAssertTrue(impactResult.traversal.nodes.contains { $0.id == bridgeHandler.id })
        XCTAssertTrue(impactResult.traversal.nodes.contains { $0.id == dartEntry.id })

        let affectedTests = try query.execute(
            repositoryPath: repositoryURL.path,
            request: .affectedTests(
                .init(
                    sourcePath: "src/dart/Main.dart",
                    limits: .init(maxDepth: 3, maxResults: 8)
                )
            )
        )
        guard case let .affectedTests(affectedTestsResult) = affectedTests else {
            return XCTFail("Expected affected tests result")
        }
        XCTAssertEqual(affectedTestsResult.testPaths, ["test/dart_entry_test.dart"])
    }

    func testIncrementalGenerationReusesUnchangedFilesAndReextractsOnlyChangedFile() throws {
        try writeFixtureRepository()
        let extractor = RecordingExtractor(try bundledRuntime())
        let navigation = ProjectNavigationService(parserRuntime: extractor)

        _ = try navigation.generateBaseNavigation(repositoryPath: repositoryURL.path)
        extractor.reset()

        _ = try navigation.generateBaseNavigation(repositoryPath: repositoryURL.path)
        XCTAssertTrue(extractor.extractedPaths.isEmpty)

        try write(
            """
            int renamedApiValue() => 2;
            """,
            to: "src/dart/Api.dart"
        )
        extractor.reset()

        let workgraphPath = try navigation.generateBaseNavigation(repositoryPath: repositoryURL.path)
        XCTAssertEqual(extractor.extractedPaths, ["src/dart/Api.dart"])
        XCTAssertTrue(isCurrent(navigation.status(for: repositoryURL.path)))

        let nodes = try readJSONLines(
            WorkGraphNodeDraft.self,
            from: URL(fileURLWithPath: workgraphPath, isDirectory: true).appendingPathComponent("symbols.jsonl")
        )
        XCTAssertFalse(nodes.contains { $0.filePath == "src/dart/Api.dart" && $0.name == "apiValue" })
        XCTAssertTrue(nodes.contains { $0.filePath == "src/dart/Api.dart" && $0.name == "renamedApiValue" })
    }

    private var fixtureSourcePaths: [String] {
        [
            "src/dart/Api.dart",
            "src/dart/Main.dart",
            "src/swift/Bridge.swift",
            "src/objc/Flow.m",
            "src/kotlin/Flow.kt",
            "src/java/JavaFlow.java",
            "src/c/Flow.c",
            "src/cpp/Flow.cpp",
            "src/ark/Flow.ets"
        ]
    }

    private func writeFixtureRepository() throws {
        try write(
            """
            int apiValue() => 1;
            """,
            to: "src/dart/Api.dart"
        )
        try write(
            """
            import 'Api.dart';
            import 'package:flutter/services.dart';

            int dartEntry() {
              MethodChannel('e2e.channel').invokeMethod('ping');
              return apiValue();
            }
            """,
            to: "src/dart/Main.dart"
        )
        try write(
            """
            import Foundation

            func configureChannel() {
              let channel = FlutterMethodChannel(name: "e2e.channel", binaryMessenger: messenger)
              channel.setMethodCallHandler { call, result in
                switch call.method {
                case "ping":
                  result(nil)
                default:
                  result(nil)
                }
              }
            }
            """,
            to: "src/swift/Bridge.swift"
        )
        try write(
            """
            void objcTarget(void) {}
            void objcCaller(void) { objcTarget(); }
            """,
            to: "src/objc/Flow.m"
        )
        try write(
            """
            fun kotlinTarget() {}
            fun kotlinCaller() { kotlinTarget() }
            """,
            to: "src/kotlin/Flow.kt"
        )
        try write(
            """
            class JavaFlow {
              void javaTarget() {}
              void javaCaller() { javaTarget(); }
            }
            """,
            to: "src/java/JavaFlow.java"
        )
        try write(
            """
            void cTarget(void) {}
            void cCaller(void) { cTarget(); }
            """,
            to: "src/c/Flow.c"
        )
        try write(
            """
            void cppTarget() {}
            void cppCaller() { cppTarget(); }
            """,
            to: "src/cpp/Flow.cpp"
        )
        try write(
            """
            function arkTarget(): void {}
            function arkCaller(): void { arkTarget(); }
            """,
            to: "src/ark/Flow.ets"
        )
        try write(
            """
            import '../src/dart/Main.dart';

            void verifyEntry() {
              dartEntry();
            }
            """,
            to: "test/dart_entry_test.dart"
        )
    }

    private func write(_ source: String, to relativePath: String) throws {
        let url = repositoryURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: url, atomically: true, encoding: .utf8)
    }

    private func assertExtractedSymbols(
        _ nodes: [WorkGraphNodeDraft],
        existFor expectations: [(path: String, language: WorkGraphLanguage)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for expectation in expectations {
            XCTAssertTrue(
                nodes.contains {
                    $0.filePath == expectation.path && $0.language == expectation.language && $0.kind != .file
                },
                "Expected parsed symbols for \(expectation.path)",
                file: file,
                line: line
            )
        }
    }

    private func node(
        named name: String,
        in path: String,
        from nodes: [WorkGraphNodeDraft]
    ) throws -> WorkGraphNodeDraft {
        try XCTUnwrap(nodes.first { $0.name == name && $0.filePath == path })
    }

    private func readJSONLines<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> [Value] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return try content.split(whereSeparator: \.isNewline).map { line in
            try decoder.decode(Value.self, from: Data(String(line).utf8))
        }
    }

    private func isCurrent(_ status: ProjectNavigationStatus) -> Bool {
        if case .current = status { return true }
        return false
    }

    private func bundledRuntime() throws -> WorkGraphParserProcessRuntime {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtimeDirectory = projectURL
            .appendingPathComponent("Sources/DevFlow/Resources/WorkGraphRuntime", isDirectory: true)
        return try XCTUnwrap(WorkGraphRuntimeLocator.runtime(at: runtimeDirectory))
    }
}

private final class RecordingExtractor: WorkGraphLanguageExtractor {
    private let underlying: WorkGraphLanguageExtractor
    private(set) var extractedPaths: [String] = []

    init(_ underlying: WorkGraphLanguageExtractor) {
        self.underlying = underlying
    }

    var supportedLanguages: Set<WorkGraphLanguage> {
        underlying.supportedLanguages
    }

    func extract(file: WorkGraphSourceFile) throws -> WorkGraphExtraction {
        extractedPaths.append(file.record.path)
        return try underlying.extract(file: file)
    }

    func reset() {
        extractedPaths.removeAll()
    }
}
