import XCTest
@testable import DevFlow

final class WorkGraphResolverTests: XCTestCase {
    func testSameFileExactMatchWinsOverImportedAndRepositoryMatches() {
        let fixture = Fixture()
        let result = WorkGraphResolver().resolve(snapshot: fixture.snapshot(
            nodes: [
                fixture.file("App.swift"),
                fixture.file("Imported.swift"),
                fixture.function("caller", path: "App.swift"),
                fixture.function("perform", path: "App.swift"),
                fixture.function("perform", path: "Imported.swift"),
                fixture.function("perform", path: "Elsewhere.swift")
            ],
            edges: [fixture.importEdge(from: "App.swift", to: "Imported.swift")],
            references: [fixture.reference(from: "caller", name: "perform")]
        ))

        XCTAssertEqual(result.edges.map(\.targetID), ["perform@App.swift"])
        XCTAssertEqual(result.edges.first?.confidence, 0.99)
        XCTAssertEqual(result.references.single?.status, .resolved)
        XCTAssertEqual(result.references.single?.targetID, "perform@App.swift")
    }

    func testImportedExactMatchWinsOverUniqueRepositoryMatch() {
        let fixture = Fixture()
        let result = WorkGraphResolver().resolve(snapshot: fixture.snapshot(
            nodes: [
                fixture.file("App.swift"),
                fixture.file("Imported.swift"),
                fixture.function("caller", path: "App.swift"),
                fixture.function("load", path: "Imported.swift"),
                fixture.function("load", path: "Elsewhere.swift")
            ],
            edges: [fixture.importEdge(from: "App.swift", to: "Imported.swift")],
            references: [fixture.reference(from: "caller", name: "load")]
        ))

        XCTAssertEqual(result.edges.map(\.targetID), ["load@Imported.swift"])
        XCTAssertEqual(result.edges.first?.confidence, 0.95)
        XCTAssertEqual(result.references.single?.status, .resolved)
    }

    func testUniqueRepositoryExactMatchResolvesAtLowestConfidence() {
        let fixture = Fixture()
        let result = WorkGraphResolver().resolve(snapshot: fixture.snapshot(
            nodes: [
                fixture.file("App.swift"),
                fixture.function("caller", path: "App.swift"),
                fixture.function("onlyTarget", path: "Elsewhere.swift")
            ],
            references: [fixture.reference(from: "caller", name: "onlyTarget")]
        ))

        XCTAssertEqual(result.edges.map(\.targetID), ["onlyTarget@Elsewhere.swift"])
        XCTAssertEqual(result.edges.first?.confidence, 0.85)
        XCTAssertEqual(result.references.single?.status, .resolved)
    }

    func testAmbiguityInTheNearestScopeDoesNotFallBack() {
        let fixture = Fixture()
        let result = WorkGraphResolver().resolve(snapshot: fixture.snapshot(
            nodes: [
                fixture.file("App.swift"),
                fixture.file("Imported.swift"),
                fixture.function("caller", path: "App.swift"),
                fixture.function("save", path: "App.swift", suffix: "first"),
                fixture.function("save", path: "App.swift", suffix: "second"),
                fixture.function("save", path: "Imported.swift")
            ],
            edges: [fixture.importEdge(from: "App.swift", to: "Imported.swift")],
            references: [fixture.reference(from: "caller", name: "save")]
        ))

        XCTAssertTrue(result.edges.isEmpty)
        XCTAssertEqual(result.references.single?.status, .ambiguous)
        XCTAssertNil(result.references.single?.targetID)
    }

    func testAmbiguousImportScopeDoesNotCreateAnEdge() {
        let fixture = Fixture()
        let result = WorkGraphResolver().resolve(snapshot: fixture.snapshot(
            nodes: [
                fixture.file("App.swift"),
                fixture.file("First.swift"),
                fixture.file("Second.swift"),
                fixture.function("caller", path: "App.swift"),
                fixture.function("fetch", path: "First.swift"),
                fixture.function("fetch", path: "Second.swift"),
                fixture.function("fetch", path: "Elsewhere.swift")
            ],
            edges: [
                fixture.importEdge(from: "App.swift", to: "First.swift"),
                fixture.importEdge(from: "App.swift", to: "Second.swift")
            ],
            references: [fixture.reference(from: "caller", name: "fetch")]
        ))

        XCTAssertTrue(result.edges.isEmpty)
        XCTAssertEqual(result.references.single?.status, .ambiguous)
    }

    func testImportReferenceResolvesOnlyExactFilePath() {
        let fixture = Fixture()
        let result = WorkGraphResolver().resolve(snapshot: fixture.snapshot(
            nodes: [fixture.file("App.swift"), fixture.file("Feature.swift")],
            references: [fixture.reference(from: "file@App.swift", name: "Feature.swift", kind: .imports)]
        ))

        XCTAssertEqual(result.edges.single?.kind, .imports)
        XCTAssertEqual(result.edges.single?.targetID, "file@Feature.swift")
        XCTAssertEqual(result.references.single?.status, .resolved)
        XCTAssertEqual(result.references.single?.confidence, 0.99)
    }

    func testRelativeImportResolvesAgainstTheSourceDirectory() {
        let fixture = Fixture()
        let result = WorkGraphResolver().resolve(snapshot: fixture.snapshot(
            nodes: [
                fixture.file("Sources/App/Screen.swift"),
                fixture.file("Sources/Shared/Feature.swift")
            ],
            references: [fixture.reference(
                from: "file@Sources/App/Screen.swift",
                name: "../Shared/Feature.swift",
                kind: .imports,
                path: "Sources/App/Screen.swift"
            )]
        ))

        XCTAssertEqual(result.edges.single?.targetID, "file@Sources/Shared/Feature.swift")
        XCTAssertEqual(result.references.single?.status, .resolved)
    }

    func testDartPackageImportResolvesUniqueLocalLibFile() {
        let fixture = Fixture()
        let result = WorkGraphResolver().resolve(snapshot: fixture.snapshot(
            nodes: [
                fixture.file("lib/app.dart", language: .dart),
                fixture.file("lib/features/live/player.dart", language: .dart)
            ],
            references: [fixture.reference(
                from: "file@lib/app.dart",
                name: "package:live/features/live/player.dart",
                kind: .imports,
                path: "lib/app.dart",
                language: .dart
            )]
        ))

        XCTAssertEqual(result.edges.single?.targetID, "file@lib/features/live/player.dart")
        XCTAssertEqual(result.references.single?.status, .resolved)
    }

    func testExtensionlessArkTSRelativeImportResolvesOnlyMatchingFile() {
        let fixture = Fixture()
        let result = WorkGraphResolver().resolve(snapshot: fixture.snapshot(
            nodes: [
                fixture.file("entry/src/main/ets/pages/Index.ets", language: .arkTS),
                fixture.file("entry/src/main/ets/components/Player.ets", language: .arkTS)
            ],
            references: [fixture.reference(
                from: "file@entry/src/main/ets/pages/Index.ets",
                name: "../components/Player",
                kind: .imports,
                path: "entry/src/main/ets/pages/Index.ets",
                language: .arkTS
            )]
        ))

        XCTAssertEqual(result.edges.single?.targetID, "file@entry/src/main/ets/components/Player.ets")
        XCTAssertEqual(result.references.single?.status, .resolved)
    }

    func testAmbiguousDartPackageSuffixDoesNotCreateImportEdge() {
        let fixture = Fixture()
        let result = WorkGraphResolver().resolve(snapshot: fixture.snapshot(
            nodes: [
                fixture.file("packages/first/lib/shared/player.dart", language: .dart),
                fixture.file("packages/second/lib/shared/player.dart", language: .dart),
                fixture.file("lib/app.dart", language: .dart)
            ],
            references: [fixture.reference(
                from: "file@lib/app.dart",
                name: "package:live/shared/player.dart",
                kind: .imports,
                path: "lib/app.dart",
                language: .dart
            )]
        ))

        XCTAssertTrue(result.edges.isEmpty)
        XCTAssertEqual(result.references.single?.status, .ambiguous)
    }

    func testCandidateNamesRequireExactSymbolOrQualifiedName() {
        let fixture = Fixture()
        let target = fixture.function("perform", path: "Feature.swift", qualifiedName: "Feature.perform")
        let result = WorkGraphResolver().resolve(snapshot: fixture.snapshot(
            nodes: [fixture.file("App.swift"), fixture.function("caller", path: "App.swift"), target],
            references: [fixture.reference(from: "caller", name: "receiver.perform", candidates: ["Feature.perform"])]
        ))

        XCTAssertEqual(result.edges.single?.targetID, target.id)
        XCTAssertEqual(result.references.single?.status, .resolved)
    }

    func testCrossLanguageUniqueNameDoesNotResolveWithoutBridgeResolver() {
        let fixture = Fixture()
        let result = WorkGraphResolver().resolve(snapshot: fixture.snapshot(
            nodes: [
                fixture.file("App.swift"),
                fixture.function("caller", path: "App.swift"),
                fixture.function("caller", path: "Main.kt", language: .kotlin),
                fixture.function("platformCall", path: "Main.kt", language: .kotlin)
            ],
            references: [fixture.reference(from: "caller", name: "platformCall")]
        ))

        XCTAssertTrue(result.edges.isEmpty)
        XCTAssertEqual(result.references.single?.status, .failed)
    }

    func testReferenceWithInconsistentSourcePathDoesNotResolve() {
        let fixture = Fixture()
        let reference = WorkGraphReferenceDraft(
            fromNodeID: "caller@App.swift",
            rawName: "target",
            kind: .calls,
            location: .unknown,
            candidateNames: [],
            filePath: "Incorrect.swift",
            language: .swift,
            fingerprint: "inconsistent-source"
        )
        let result = WorkGraphResolver().resolve(snapshot: fixture.snapshot(
            nodes: [
                fixture.file("App.swift"),
                fixture.function("caller", path: "App.swift"),
                fixture.function("target", path: "App.swift")
            ],
            references: [reference]
        ))

        XCTAssertTrue(result.edges.isEmpty)
        XCTAssertEqual(result.references.single?.status, .failed)
    }

    private struct Fixture {
        func snapshot(
            nodes: [WorkGraphNodeDraft],
            edges: [WorkGraphEdgeDraft] = [],
            references: [WorkGraphReferenceDraft] = []
        ) -> WorkGraphIndexSnapshot {
            WorkGraphIndexSnapshot(files: [], nodes: nodes, edges: edges, references: references, documents: [])
        }

        func file(_ path: String, language: WorkGraphLanguage = .swift) -> WorkGraphNodeDraft {
            WorkGraphNodeDraft(
                id: "file@\(path)",
                parentID: nil,
                kind: .file,
                name: path,
                qualifiedName: path,
                filePath: path,
                language: language,
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
        }

        func function(
            _ name: String,
            path: String,
            language: WorkGraphLanguage = .swift,
            qualifiedName: String? = nil,
            suffix: String = ""
        ) -> WorkGraphNodeDraft {
            WorkGraphNodeDraft(
                id: "\(name)@\(path)\(suffix.isEmpty ? "" : "#\(suffix)")",
                parentID: "file@\(path)",
                kind: .function,
                name: name,
                qualifiedName: qualifiedName ?? "\(path)::\(name)",
                filePath: path,
                language: language,
                location: .unknown,
                signature: "func \(name)()",
                visibility: nil,
                isExported: false,
                isAsync: false,
                isStatic: false,
                isAbstract: false,
                returnType: nil,
                decorators: []
            )
        }

        func importEdge(from sourcePath: String, to targetPath: String) -> WorkGraphEdgeDraft {
            WorkGraphEdgeDraft(
                sourceID: "file@\(sourcePath)",
                targetID: "file@\(targetPath)",
                kind: .imports,
                location: .unknown,
                metadataJSON: nil,
                confidence: 1,
                provenance: .ast
            )
        }

        func reference(
            from name: String,
            name rawName: String,
            kind: WorkGraphEdgeKind = .calls,
            candidates: [String] = [],
            path: String = "App.swift",
            language: WorkGraphLanguage = .swift
        ) -> WorkGraphReferenceDraft {
            WorkGraphReferenceDraft(
                fromNodeID: name.contains("@") ? name : "\(name)@App.swift",
                rawName: rawName,
                kind: kind,
                location: .unknown,
                candidateNames: candidates,
                filePath: path,
                language: language,
                fingerprint: "\(kind.rawValue):\(name):\(rawName):\(candidates.joined(separator: ","))"
            )
        }
    }
}

private extension Array where Element == WorkGraphReferenceResolution {
    var single: WorkGraphReferenceResolution? {
        count == 1 ? first : nil
    }
}

private extension Array where Element == WorkGraphEdgeDraft {
    var single: WorkGraphEdgeDraft? {
        count == 1 ? first : nil
    }
}
