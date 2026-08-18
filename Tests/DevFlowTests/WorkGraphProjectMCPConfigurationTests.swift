import Foundation
import XCTest
@testable import DevFlow

final class WorkGraphProjectMCPConfigurationTests: XCTestCase {
    private var repositoryURL: URL!
    private var executableURL: URL!

    override func setUpWithError() throws {
        repositoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkGraphProjectMCPConfigurationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        executableURL = repositoryURL.appendingPathComponent("devflow-mcp")
        XCTAssertTrue(FileManager.default.createFile(atPath: executableURL.path, contents: Data("#!/bin/sh\n".utf8)))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    override func tearDownWithError() throws {
        if let repositoryURL {
            try? FileManager.default.removeItem(at: repositoryURL)
        }
        repositoryURL = nil
        executableURL = nil
    }

    func testInstallCreatesProjectConfigAndLocalGitExcludeAndRollbackRemovesOnlyItsFiles() throws {
        try createGitMetadata()

        let transaction = try WorkGraphProjectMCPConfiguration.install(
            repositoryPath: repositoryURL.path,
            executablePath: executableURL.path
        )
        let configURL = repositoryURL.appendingPathComponent(".cursor/mcp.json")
        let config = try json(at: configURL)
        let servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
        let server = try XCTUnwrap(servers[WorkGraphProjectMCPConfiguration.serverName] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, executableURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(server["args"] as? [String], [WorkGraphMCPServer.commandLineFlag])

        let excludeURL = repositoryURL.appendingPathComponent(".git/info/exclude")
        XCTAssertTrue(try String(contentsOf: excludeURL, encoding: .utf8).contains(".cursor/mcp.json"))

        try transaction.rollback()
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repositoryURL.appendingPathComponent(".cursor").path))
        XCTAssertFalse(try String(contentsOf: excludeURL, encoding: .utf8).contains(".cursor/mcp.json"))
    }

    func testInstallPreservesOtherServersAndIsIdempotent() throws {
        try createGitMetadata()
        let cursorURL = repositoryURL.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursorURL, withIntermediateDirectories: true)
        let configURL = cursorURL.appendingPathComponent("mcp.json")
        let existing = """
        {
          "customRoot": {"keep": true},
          "mcpServers": {
            "other": {"command": "other-tool", "args": ["--serve"]},
            "devflow-workgraph": {"env": {"KEEP": "yes"}, "command": "old", "args": ["old"]}
          }
        }
        """
        try existing.write(to: configURL, atomically: true, encoding: .utf8)

        _ = try WorkGraphProjectMCPConfiguration.install(
            repositoryPath: repositoryURL.path,
            executablePath: executableURL.path
        )
        let firstData = try Data(contentsOf: configURL)
        let first = try json(at: configURL)
        XCTAssertNotNil(first["customRoot"])
        let servers = try XCTUnwrap(first["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"])
        let managed = try XCTUnwrap(servers[WorkGraphProjectMCPConfiguration.serverName] as? [String: Any])
        XCTAssertEqual((managed["env"] as? [String: String])?["KEEP"], "yes")

        _ = try WorkGraphProjectMCPConfiguration.install(
            repositoryPath: repositoryURL.path,
            executablePath: executableURL.path
        )
        XCTAssertEqual(try Data(contentsOf: configURL), firstData)
    }

    func testRollbackDoesNotOverwriteAConcurrentConfigurationChange() throws {
        let transaction = try WorkGraphProjectMCPConfiguration.install(
            repositoryPath: repositoryURL.path,
            executablePath: executableURL.path
        )
        let configURL = repositoryURL.appendingPathComponent(".cursor/mcp.json")
        let concurrent = "{\"mcpServers\":{\"other\":{\"command\":\"other\"}}}\n"
        try concurrent.write(to: configURL, atomically: true, encoding: .utf8)

        try transaction.rollback()
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), concurrent)
    }

    func testRejectsUnsafePathsAndMalformedOrSymlinkedConfiguration() throws {
        XCTAssertThrowsError(
            try WorkGraphProjectMCPConfiguration.install(
                repositoryPath: "relative/repository",
                executablePath: executableURL.path
            )
        ) { error in
            XCTAssertEqual(error as? WorkGraphProjectMCPConfiguration.ConfigurationError, .invalidRepositoryPath)
        }

        let cursorURL = repositoryURL.appendingPathComponent(".cursor", isDirectory: true)
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        try FileManager.default.createSymbolicLink(at: cursorURL, withDestinationURL: outsideURL)
        XCTAssertThrowsError(
            try WorkGraphProjectMCPConfiguration.install(
                repositoryPath: repositoryURL.path,
                executablePath: executableURL.path
            )
        ) { error in
            guard case .symbolicLinkNotAllowed = error as? WorkGraphProjectMCPConfiguration.ConfigurationError else {
                return XCTFail("Expected symlink rejection, got \(error)")
            }
        }

        try FileManager.default.removeItem(at: cursorURL)
        try FileManager.default.createDirectory(at: cursorURL, withIntermediateDirectories: true)
        let configURL = cursorURL.appendingPathComponent("mcp.json")
        let malformed = Data("not-json".utf8)
        try malformed.write(to: configURL)
        XCTAssertThrowsError(
            try WorkGraphProjectMCPConfiguration.install(
                repositoryPath: repositoryURL.path,
                executablePath: executableURL.path
            )
        ) { error in
            XCTAssertEqual(error as? WorkGraphProjectMCPConfiguration.ConfigurationError, .invalidConfiguration)
        }
        XCTAssertEqual(try Data(contentsOf: configURL), malformed)
    }

    func testConfigWriteIsRolledBackWhenGitExcludeIsUnsafe() throws {
        try createGitMetadata()
        let excludeURL = repositoryURL.appendingPathComponent(".git/info/exclude")
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("exclude-target-\(UUID().uuidString)")
        try "do not modify".write(to: outsideURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        try FileManager.default.removeItem(at: excludeURL)
        try FileManager.default.createSymbolicLink(at: excludeURL, withDestinationURL: outsideURL)

        XCTAssertThrowsError(
            try WorkGraphProjectMCPConfiguration.install(
                repositoryPath: repositoryURL.path,
                executablePath: executableURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repositoryURL.appendingPathComponent(".cursor/mcp.json").path
            )
        )
        XCTAssertEqual(try String(contentsOf: outsideURL, encoding: .utf8), "do not modify")
    }

    private func createGitMetadata() throws {
        try FileManager.default.createDirectory(
            at: repositoryURL.appendingPathComponent(".git/info", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "# local excludes\n".write(
            to: repositoryURL.appendingPathComponent(".git/info/exclude"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func json(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

