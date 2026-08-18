import Foundation
import XCTest
@testable import DevFlow

final class WorkGraphParserRuntimeTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkGraphParserRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testProcessRuntimeSendsRelativePathAndSourceAndCapturesDiagnostics() throws {
        let helperURL = try makeHelper(named: "success-helper", body: """
        IFS= read -r request
        case "$request" in *'"relativePath":"Sources\\/Feature.swift"'*) ;; *) echo "unexpected path" >&2; exit 2 ;; esac
        case "$request" in *'"language":"swift"'*) ;; *) echo "unexpected language" >&2; exit 2 ;; esac
        case "$request" in *'"source":"struct Feature {}"'*) ;; *) echo "unexpected source" >&2; exit 2 ;; esac
        request_id=$(printf '%s' "$request" | /usr/bin/sed -n 's/.*"requestID":"\\([^"]*\\)".*/\\1/p')
        printf '{"protocolVersion":1,"requestID":"%s","kind":"extraction","extraction":{"nodes":[{"id":"node:Feature","parentID":null,"kind":"struct","name":"Feature","qualifiedName":"Feature","filePath":"Sources/Feature.swift","language":"swift","location":{"startLine":1,"endLine":1,"startColumn":0,"endColumn":16},"signature":null,"visibility":null,"isExported":false,"isAsync":false,"isStatic":false,"isAbstract":false,"returnType":null,"decorators":[]}],"edges":[],"references":[],"documents":[]},"diagnostics":["parser warning"],"error":null}\\n' "$request_id"
        """)
        let runtime = WorkGraphParserProcessRuntime(
            helperExecutableURL: helperURL,
            requestIDProvider: { "request-1" }
        )

        let extraction = try runtime.extract(file: sourceFile(path: "Sources/Feature.swift", language: .swift, source: "struct Feature {}"))

        XCTAssertEqual(extraction.nodes.map(\.id), ["node:Feature"])
        XCTAssertEqual(extraction.file.diagnostics, ["parser warning"])
    }

    func testProcessRuntimeIgnoresInvalidReferencesAndAddsDiagnostic() throws {
        let helperURL = try makeHelper(named: "invalid-reference-helper", body: """
        IFS= read -r request
        request_id=$(printf '%s' "$request" | /usr/bin/sed -n 's/.*"requestID":"\\([^"]*\\)".*/\\1/p')
        printf '{"protocolVersion":1,"requestID":"%s","kind":"extraction","extraction":{"nodes":[{"id":"node:Feature","parentID":null,"kind":"struct","name":"Feature","qualifiedName":"Feature","filePath":"Sources/Feature.swift","language":"swift","location":{"startLine":1,"endLine":1,"startColumn":0,"endColumn":16},"signature":null,"visibility":null,"isExported":false,"isAsync":false,"isStatic":false,"isAbstract":false,"returnType":null,"decorators":[]}],"edges":[],"references":[{"fromNodeID":"missing-node","rawName":"Feature","kind":"calls","location":{"startLine":1,"endLine":1,"startColumn":0,"endColumn":7},"candidateNames":[],"filePath":"Sources/Feature.swift","language":"swift","fingerprint":"invalid-reference"}],"documents":[]},"diagnostics":[],"error":null}\\n' "$request_id"
        """)
        let runtime = WorkGraphParserProcessRuntime(
            helperExecutableURL: helperURL,
            requestIDProvider: { "request-invalid-reference" }
        )

        let extraction = try runtime.extract(file: sourceFile(
            path: "Sources/Feature.swift",
            language: .swift,
            source: "struct Feature {}"
        ))

        XCTAssertEqual(extraction.nodes.map(\.id), ["node:Feature"])
        XCTAssertTrue(extraction.references.isEmpty)
        XCTAssertTrue(extraction.file.diagnostics.contains { $0.contains("1 条无效引用") })
    }

    func testUnknownLanguageReturnsDiagnosticWithoutLaunchingHelper() throws {
        let runtime = WorkGraphParserProcessRuntime(
            helperExecutableURL: temporaryDirectory.appendingPathComponent("does-not-exist")
        )

        let extraction = try runtime.extract(file: sourceFile(
            path: "docs/generated.txt",
            language: .unknown,
            source: "not source code"
        ))

        XCTAssertTrue(extraction.nodes.isEmpty)
        XCTAssertTrue(extraction.edges.isEmpty)
        XCTAssertTrue(extraction.file.diagnostics.joined(separator: " ").contains("未知语言"))
    }

    func testProcessRuntimeRejectsResultForAnotherFile() throws {
        let helperURL = try makeHelper(named: "invalid-helper", body: """
        IFS= read -r request
        request_id=$(printf '%s' "$request" | /usr/bin/sed -n 's/.*"requestID":"\\([^"]*\\)".*/\\1/p')
        printf '{"protocolVersion":1,"requestID":"%s","kind":"extraction","extraction":{"nodes":[{"id":"node:Feature","parentID":null,"kind":"struct","name":"Feature","qualifiedName":"Feature","filePath":"Other.swift","language":"swift","location":{"startLine":1,"endLine":1,"startColumn":0,"endColumn":16},"signature":null,"visibility":null,"isExported":false,"isAsync":false,"isStatic":false,"isAbstract":false,"returnType":null,"decorators":[]}],"edges":[],"references":[],"documents":[]},"diagnostics":[],"error":null}\\n' "$request_id"
        """)
        let runtime = WorkGraphParserProcessRuntime(
            helperExecutableURL: helperURL,
            requestIDProvider: { "request-2" }
        )

        XCTAssertThrowsError(
            try runtime.extract(file: sourceFile(path: "Sources/Feature.swift", language: .swift, source: "struct Feature {}"))
        ) { error in
            XCTAssertEqual(
                error as? WorkGraphParserRuntimeError,
                .invalidResponse("节点包含无效标识、路径、语言或位置")
            )
        }
    }

    func testBundledRuntimeExtractsConservativeRelationsAcrossLanguages() throws {
        struct Fixture {
            var name: String
            var path: String
            var language: WorkGraphLanguage
            var source: String
            var expectedRelationKinds: Set<String>
        }

        let fixtures = [
            Fixture(
                name: "Dart",
                path: "Sources/Relations.dart",
                language: .dart,
                source: """
                abstract class Runner { void run(); }
                class Parent { void run() {} }
                class Child extends Parent implements Runner {
                  const Child();
                  @override
                  void run() {}
                }
                void make() { const Child(); }
                """,
                expectedRelationKinds: ["extends", "implements", "overrides", "instantiates"]
            ),
            Fixture(
                name: "Swift",
                path: "Sources/Relations.swift",
                language: .swift,
                source: """
                protocol Runner { func run() }
                class Parent { func run() {} }
                class Child: Parent, Runner { override func run() {} }
                func make() { let child = Child() }
                """,
                expectedRelationKinds: ["extends", "implements", "overrides"]
            ),
            Fixture(
                name: "Objective-C",
                path: "Sources/Relations.m",
                language: .objectiveC,
                source: """
                @protocol BaseProtocol @end
                @protocol ChildProtocol <BaseProtocol> @end
                @interface Parent : NSObject @end
                @interface Child : Parent @end
                void make(void) { Child *child = [Child alloc]; }
                """,
                expectedRelationKinds: ["extends", "instantiates"]
            ),
            Fixture(
                name: "Kotlin",
                path: "Sources/Relations.kt",
                language: .kotlin,
                source: """
                open class Parent {
                  open fun run() {}
                }
                interface Runner {
                  fun run()
                }
                class Child : Parent(), Runner {
                  override fun run() {}
                }
                fun make() { Child() }
                """,
                expectedRelationKinds: ["extends", "implements", "overrides"]
            ),
            Fixture(
                name: "Java",
                path: "Sources/Relations.java",
                language: .java,
                source: """
                class Parent { void run() {} }
                interface Runner { void run(); }
                class Child extends Parent implements Runner {
                  @Override void run() {}
                }
                class App { void make() { new Child(); } }
                """,
                expectedRelationKinds: ["extends", "implements", "overrides", "instantiates"]
            ),
            Fixture(
                name: "C",
                path: "Sources/Relations.c",
                language: .c,
                source: """
                struct Child { int value; };
                void make(void) { struct Child child; }
                """,
                expectedRelationKinds: []
            ),
            Fixture(
                name: "C++",
                path: "Sources/Relations.cpp",
                language: .cpp,
                source: """
                class Parent { public: virtual void run() {} };
                class Child : public Parent { public: void run() override {} };
                void make() { auto child = new Child(); }
                """,
                expectedRelationKinds: ["extends", "overrides", "instantiates"]
            ),
            Fixture(
                name: "ArkTS",
                path: "Sources/Relations.ets",
                language: .arkTS,
                source: """
                interface Runner { run(): void }
                class Parent { run(): void {} }
                class Child extends Parent implements Runner { override run(): void {} }
                function make(): void { let child = new Child(); }
                @Entry @Component struct App { build() { Child() } }
                """,
                expectedRelationKinds: ["extends", "implements", "overrides", "instantiates"]
            )
        ]
        let runtime = try bundledRuntime()
        let extractions = try runtime.extract(files: fixtures.map {
            sourceFile(path: $0.path, language: $0.language, source: $0.source)
        })

        XCTAssertEqual(extractions.count, fixtures.count)
        for (fixture, extraction) in zip(fixtures, extractions) {
            let relationKinds = Set(
                (extraction.edges.map(\.kind) + extraction.references.map(\.kind)).map(\.rawValue)
            )
            XCTAssertTrue(
                fixture.expectedRelationKinds.isSubset(of: relationKinds),
                "\(fixture.name) missing expected relations. Actual: \(relationKinds.sorted())"
            )
            if !fixture.expectedRelationKinds.isEmpty {
                XCTAssertTrue(
                    extraction.edges.contains {
                        fixture.expectedRelationKinds.contains($0.kind.rawValue) && $0.provenance == .ast
                    },
                    "\(fixture.name) did not emit any AST-backed relation edge"
                )
            }
        }
    }

    func testBundledRuntimeDoesNotTreatAmbiguousCallsOrObjectiveCGenericsAsGraphFacts() throws {
        let runtime = try bundledRuntime()
        let files = [
            sourceFile(
                path: "Sources/Ambiguous.swift",
                language: .swift,
                source: """
                func factory() {}
                func make() { factory() }
                """
            ),
            sourceFile(
                path: "Sources/Generic.m",
                language: .objectiveC,
                source: """
                @interface Generic : NSObject @end
                @interface Child : Generic<ProtocolLike> @end
                void make(void) { Child *child = [Child description]; }
                """
            )
        ]

        let extractions = try runtime.extract(files: files)
        XCTAssertFalse(extractions[0].edges.contains { $0.kind == .instantiates })
        XCTAssertFalse(extractions[0].references.contains { $0.kind == .instantiates })
        XCTAssertFalse(extractions[1].edges.contains { $0.kind == .implements })
        XCTAssertFalse(extractions[1].references.contains { $0.kind == .implements })
        XCTAssertFalse(extractions[1].edges.contains { $0.kind == .instantiates })
        XCTAssertFalse(extractions[1].references.contains { $0.kind == .instantiates })
    }

    func testBundledRuntimeKeepsCrossFileRelationsAsResolvableEvidence() throws {
        let runtime = try bundledRuntime()
        let extractions = try runtime.extract(files: [
            sourceFile(
                path: "Sources/Parent.java",
                language: .java,
                source: "class Parent { void run() {} }"
            ),
            sourceFile(
                path: "Sources/Child.java",
                language: .java,
                source: """
                class Child extends Parent {
                  @Override void run() {}
                }
                """
            )
        ])
        let child = try XCTUnwrap(extractions.first { $0.file.path == "Sources/Child.java" })

        XCTAssertTrue(child.references.contains { $0.kind == .extends && $0.rawName == "Parent" })
        XCTAssertTrue(child.references.contains { $0.kind == .overrides && $0.rawName == "Parent.run" })

        let snapshot = WorkGraphIndexSnapshot(
            files: extractions.map(\.file),
            nodes: extractions.flatMap(\.nodes),
            edges: extractions.flatMap(\.edges),
            references: extractions.flatMap(\.references),
            documents: extractions.flatMap(\.documents)
        )
        let resolution = WorkGraphResolver().resolve(snapshot: snapshot)
        let childClass = try XCTUnwrap(child.nodes.first { $0.kind == .class && $0.name == "Child" })
        let childMethod = try XCTUnwrap(child.nodes.first { $0.kind == .method && $0.name == "run" })

        XCTAssertTrue(resolution.edges.contains {
            $0.kind == .extends && $0.sourceID == childClass.id && $0.confidence == 0.85
        })
        XCTAssertTrue(resolution.edges.contains {
            $0.kind == .overrides && $0.sourceID == childMethod.id && $0.confidence == 0.85
        })
    }

    func testInMemoryRuntimeSupportsArkTS() throws {
        let file = sourceFile(
            path: "Sources/App.ets",
            language: .arkTS,
            source: "@Component struct App { build() {} }"
        )
        let expectedDocument = WorkGraphDocumentRecord(path: file.record.path, terms: ["app"])
        let runtime = WorkGraphInMemoryParserRuntime(supportedLanguages: [.arkTS]) { source in
            WorkGraphExtraction(
                file: source.record,
                nodes: [],
                edges: [],
                references: [],
                documents: [expectedDocument]
            )
        }

        let extraction = try runtime.extract(file: file)

        XCTAssertEqual(runtime.supportedLanguages, [.arkTS])
        XCTAssertEqual(extraction.documents, [expectedDocument])
    }

    private func sourceFile(path: String, language: WorkGraphLanguage, source: String) -> WorkGraphSourceFile {
        WorkGraphSourceFile(
            record: WorkGraphFileRecord(
                path: path,
                contentHash: "test-hash",
                language: language,
                byteCount: source.lengthOfBytes(using: .utf8),
                modifiedAt: nil,
                isGenerated: false,
                diagnostics: []
            ),
            source: source
        )
    }

    private func bundledRuntime() throws -> WorkGraphParserProcessRuntime {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtimeDirectory = repositoryURL
            .appendingPathComponent("Sources/DevFlow/Resources/WorkGraphRuntime", isDirectory: true)
        return try XCTUnwrap(WorkGraphRuntimeLocator.runtime(at: runtimeDirectory))
    }

    private func makeHelper(named name: String, body: String) throws -> URL {
        let helperURL = temporaryDirectory.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        return helperURL
    }
}
