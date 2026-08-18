import Foundation
import XCTest
@testable import DevFlow

final class WorkGraphAutoSyncCoordinatorTests: XCTestCase {
    private var repositoryURL: URL!

    override func setUpWithError() throws {
        repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkGraphAutoSyncCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let repositoryURL {
            try? FileManager.default.removeItem(at: repositoryURL)
        }
        repositoryURL = nil
    }

    func testDoesNotGenerateFirstNavigationDuringAutomaticCheck() throws {
        try write("func checkout() {}\n", to: "Sources/App/Checkout.swift")
        let navigation = ProjectNavigationService()
        let coordinator = WorkGraphAutoSyncCoordinator(navigationService: navigation)

        XCTAssertEqual(
            try coordinator.ensureCurrent(repositoryPath: repositoryURL.path),
            .unchanged
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ProjectNavigationService.workgraphPath(for: repositoryURL.path)
            )
        )
    }

    func testRebuildsExistingNavigationWhenSourceChanges() throws {
        let sourcePath = "Sources/App/Checkout.swift"
        try write("func checkout() {}\n", to: sourcePath)
        let navigation = ProjectNavigationService()
        _ = try navigation.generateBaseNavigation(repositoryPath: repositoryURL.path)

        try write("func checkout() { print(\"changed\") }\n", to: sourcePath)
        let coordinator = WorkGraphAutoSyncCoordinator(navigationService: navigation)

        XCTAssertEqual(
            try coordinator.ensureCurrent(repositoryPath: repositoryURL.path),
            .rebuilt
        )

        let databaseURL = URL(fileURLWithPath: ProjectNavigationService.workgraphPath(for: repositoryURL.path))
            .appendingPathComponent(WorkGraphStore.fileName)
        let snapshot = try XCTUnwrap(try WorkGraphStore(databaseURL: databaseURL).cachedSyntaxSnapshot())
        XCTAssertTrue(snapshot.files.contains { $0.path == sourcePath })
        XCTAssertTrue(snapshot.nodes.contains { $0.filePath == sourcePath && $0.name == "checkout" })
    }

    func testConcurrentChecksShareOneRebuild() throws {
        let sourcePath = "Sources/App/Checkout.swift"
        try write("func checkout() {}\n", to: sourcePath)
        let countingExtractor = try CountingExtractor(underlying: bundledRuntime())
        let navigation = ProjectNavigationService(parserRuntime: countingExtractor)
        _ = try navigation.generateBaseNavigation(repositoryPath: repositoryURL.path)
        countingExtractor.reset()

        try write("func checkout() { print(\"changed\") }\n", to: sourcePath)
        let coordinator = WorkGraphAutoSyncCoordinator(navigationService: navigation)
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [WorkGraphAutoSyncCoordinator.Result] = []

        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                let result = try? coordinator.ensureCurrent(repositoryPath: self.repositoryURL.path)
                lock.lock()
                if let result { results.append(result) }
                lock.unlock()
                group.leave()
            }
        }
        group.wait()

        XCTAssertEqual(results.count, 4)
        XCTAssertTrue(results.allSatisfy { $0 == .rebuilt })
        XCTAssertEqual(countingExtractor.extractionCount, 1)
    }

    func testRemovesDeletedSourceFromExistingNavigation() throws {
        let sourcePath = "Sources/App/Checkout.swift"
        try write("func checkout() {}\n", to: sourcePath)
        let navigation = ProjectNavigationService()
        _ = try navigation.generateBaseNavigation(repositoryPath: repositoryURL.path)

        try FileManager.default.removeItem(at: repositoryURL.appendingPathComponent(sourcePath))
        let coordinator = WorkGraphAutoSyncCoordinator(navigationService: navigation)
        XCTAssertEqual(
            try coordinator.ensureCurrent(repositoryPath: repositoryURL.path),
            .rebuilt
        )

        let databaseURL = URL(fileURLWithPath: ProjectNavigationService.workgraphPath(for: repositoryURL.path))
            .appendingPathComponent(WorkGraphStore.fileName)
        let files = try WorkGraphStore(databaseURL: databaseURL).indexedFiles()
        XCTAssertFalse(files.contains { $0.path == sourcePath })
    }

    func testFailedRebuildDoesNotExposeThePreviousSourceThroughInspection() throws {
        let sourcePath = "Sources/App/Checkout.swift"
        try write("func checkout() {}\n", to: sourcePath)
        _ = try ProjectNavigationService().generateBaseNavigation(repositoryPath: repositoryURL.path)
        try write("func checkout() { print(\"changed\") }\n", to: sourcePath)

        let failingNavigation = ProjectNavigationService(parserRuntime: FailingExtractor())
        let coordinator = WorkGraphAutoSyncCoordinator(navigationService: failingNavigation)
        XCTAssertThrowsError(
            try coordinator.ensureCurrent(repositoryPath: repositoryURL.path)
        )

        let inspection = WorkGraphInspectionService(
            navigationService: failingNavigation,
            syncCoordinator: coordinator
        )
        XCTAssertThrowsError(
            try inspection.node(
                repositoryPath: repositoryURL.path,
                request: .init(target: .path(sourcePath))
            )
        )
    }

    private func write(_ contents: String, to relativePath: String) throws {
        let url = repositoryURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
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

private final class CountingExtractor: WorkGraphLanguageExtractor {
    private let underlying: WorkGraphLanguageExtractor
    private let lock = NSLock()
    private var count = 0

    init(underlying: WorkGraphLanguageExtractor) {
        self.underlying = underlying
    }

    var supportedLanguages: Set<WorkGraphLanguage> {
        underlying.supportedLanguages
    }

    var extractionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func extract(file: WorkGraphSourceFile) throws -> WorkGraphExtraction {
        lock.lock()
        count += 1
        lock.unlock()
        return try underlying.extract(file: file)
    }

    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }
}

private struct FailingExtractor: WorkGraphLanguageExtractor {
    enum Failure: Error {
        case unavailable
    }

    var supportedLanguages: Set<WorkGraphLanguage> {
        Set(WorkGraphLanguage.allCases.filter(\.supportsSemanticExtraction))
    }

    func extract(file: WorkGraphSourceFile) throws -> WorkGraphExtraction {
        throw Failure.unavailable
    }
}
