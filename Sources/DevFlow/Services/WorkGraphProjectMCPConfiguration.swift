import Foundation

/// Installs the DevFlow WorkGraph MCP entry in one repository's Cursor
/// project configuration. It never touches user-level Cursor/Codex settings.
///
/// The returned transaction is intentionally held by the caller until the
/// external client has been launched. If launching fails, `rollback()` restores
/// only files that still contain the bytes written by this transaction.
enum WorkGraphProjectMCPConfiguration {
    static let directoryName = ".cursor"
    static let fileName = "mcp.json"
    static let serverName = "devflow-workgraph"
    static let configRelativePath = ".cursor/mcp.json"

    enum ConfigurationError: LocalizedError, Equatable {
        case invalidRepositoryPath
        case repositoryNotFound
        case invalidExecutablePath
        case executableNotFound
        case symbolicLinkNotAllowed(String)
        case cursorDirectoryUnavailable
        case invalidConfiguration
        case cannotWriteConfiguration(String)

        var errorDescription: String? {
            switch self {
            case .invalidRepositoryPath:
                return "仓库路径必须是绝对路径。"
            case .repositoryNotFound:
                return "仓库目录不存在或不可用。"
            case .invalidExecutablePath:
                return "WorkGraph MCP 可执行文件路径无效。"
            case .executableNotFound:
                return "找不到可执行的 WorkGraph MCP 程序。"
            case let .symbolicLinkNotAllowed(path):
                return "为避免写入仓库外部路径，不允许使用符号链接：\(path)"
            case .cursorDirectoryUnavailable:
                return "无法使用仓库内的 .cursor 目录。"
            case .invalidConfiguration:
                return "仓库内的 .cursor/mcp.json 不是可维护的 JSON 配置。"
            case let .cannotWriteConfiguration(message):
                return "无法写入项目 MCP 配置：\(message)"
            }
        }
    }

    /// A reversible set of local file changes made for one Cursor launch.
    final class Transaction {
        fileprivate struct Change {
            let url: URL
            let originalData: Data?
            let originalPermissions: NSNumber?
            let writtenData: Data
        }

        private let fileManager: FileManager
        private let changes: [Change]
        private let createdCursorDirectory: URL?
        private var didRollback = false

        fileprivate init(
            fileManager: FileManager,
            changes: [Change],
            createdCursorDirectory: URL?
        ) {
            self.fileManager = fileManager
            self.changes = changes
            self.createdCursorDirectory = createdCursorDirectory
        }

        /// Restores only unchanged files. A concurrent edit is left untouched
        /// instead of being overwritten during launch failure cleanup.
        func rollback() throws {
            guard !didRollback else { return }
            didRollback = true

            for change in changes.reversed() {
                guard !Self.isSymbolicLink(change.url, fileManager: fileManager),
                      Self.readData(at: change.url, fileManager: fileManager) == change.writtenData else {
                    continue
                }
                do {
                    if let originalData = change.originalData {
                        try originalData.write(to: change.url, options: .atomic)
                        if let originalPermissions = change.originalPermissions {
                            try fileManager.setAttributes(
                                [.posixPermissions: originalPermissions],
                                ofItemAtPath: change.url.path
                            )
                        }
                    } else if fileManager.fileExists(atPath: change.url.path) {
                        try fileManager.removeItem(at: change.url)
                    }
                } catch {
                    throw ConfigurationError.cannotWriteConfiguration(error.localizedDescription)
                }
            }

            if let createdCursorDirectory,
               fileManager.fileExists(atPath: createdCursorDirectory.path),
               !Self.isSymbolicLink(createdCursorDirectory, fileManager: fileManager),
               let contents = try? fileManager.contentsOfDirectory(atPath: createdCursorDirectory.path),
               contents.isEmpty {
                try? fileManager.removeItem(at: createdCursorDirectory)
            }
        }

        fileprivate static func readData(at url: URL, fileManager: FileManager) -> Data? {
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try? Data(contentsOf: url)
        }

        fileprivate static func isSymbolicLink(_ url: URL, fileManager: FileManager) -> Bool {
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let type = attributes[.type] as? FileAttributeType else {
                return false
            }
            return type == .typeSymbolicLink
        }
    }

    /// Adds or updates the managed server entry and a local Git exclude rule.
    /// Existing servers and unknown JSON fields are preserved. The operation is
    /// idempotent and does not rewrite unchanged files.
    static func install(
        repositoryPath rawRepositoryPath: String,
        executablePath rawExecutablePath: String,
        fileManager: FileManager = .default
    ) throws -> Transaction {
        let repositoryURL = try validatedRepositoryURL(rawRepositoryPath, fileManager: fileManager)
        let executablePath = try validatedExecutablePath(rawExecutablePath, fileManager: fileManager)
        let cursorDirectoryURL = repositoryURL.appendingPathComponent(directoryName, isDirectory: true)
        let configURL = cursorDirectoryURL.appendingPathComponent(fileName)

        let createdCursorDirectory: URL?
        if fileManager.fileExists(atPath: cursorDirectoryURL.path) {
            guard !Transaction.isSymbolicLink(cursorDirectoryURL, fileManager: fileManager) else {
                throw ConfigurationError.symbolicLinkNotAllowed(cursorDirectoryURL.path)
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: cursorDirectoryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw ConfigurationError.cursorDirectoryUnavailable
            }
            createdCursorDirectory = nil
        } else {
            do {
                try fileManager.createDirectory(at: cursorDirectoryURL, withIntermediateDirectories: false)
            } catch {
                throw ConfigurationError.cannotWriteConfiguration(error.localizedDescription)
            }
            createdCursorDirectory = cursorDirectoryURL
        }

        var changes: [Transaction.Change] = []
        do {
            let existingConfiguration = try readJSONObject(at: configURL, fileManager: fileManager)
            var root = existingConfiguration.object ?? [:]
            var servers: [String: Any]
            if let rawServers = root["mcpServers"] {
                guard let existingServers = rawServers as? [String: Any] else {
                    throw ConfigurationError.invalidConfiguration
                }
                servers = existingServers
            } else {
                servers = [:]
            }

            var managedServer: [String: Any]
            if let existingServer = servers[serverName] {
                guard let preservedServer = existingServer as? [String: Any] else {
                    throw ConfigurationError.invalidConfiguration
                }
                managedServer = preservedServer
            } else {
                managedServer = [:]
            }
            managedServer["command"] = executablePath
            managedServer["args"] = [WorkGraphMCPServer.commandLineFlag]
            servers[serverName] = managedServer
            root["mcpServers"] = servers

            guard JSONSerialization.isValidJSONObject(root) else {
                throw ConfigurationError.invalidConfiguration
            }
            var generatedData = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            generatedData.append(0x0A)

            let originalConfigurationData = Transaction.readData(at: configURL, fileManager: fileManager)
            let originalConfigurationPermissions = try filePermissions(at: configURL, fileManager: fileManager)
            if originalConfigurationData != generatedData {
                try writeAtomically(
                    generatedData,
                    to: configURL,
                    preservingPermissions: originalConfigurationPermissions,
                    fileManager: fileManager
                )
                changes.append(
                    .init(
                        url: configURL,
                        originalData: originalConfigurationData,
                        originalPermissions: originalConfigurationPermissions,
                        writtenData: generatedData
                    )
                )
            }

            if let excludeURL = try gitExcludeURL(for: repositoryURL, fileManager: fileManager) {
                guard !Transaction.isSymbolicLink(excludeURL, fileManager: fileManager) else {
                    throw ConfigurationError.symbolicLinkNotAllowed(excludeURL.path)
                }
                let originalExcludeData = Transaction.readData(at: excludeURL, fileManager: fileManager)
                let originalExcludePermissions = try filePermissions(at: excludeURL, fileManager: fileManager)
                if let generatedExcludeData = try excludingMCPConfig(
                    at: excludeURL,
                    originalData: originalExcludeData,
                    fileManager: fileManager
                ) {
                    try writeAtomically(
                        generatedExcludeData,
                        to: excludeURL,
                        preservingPermissions: originalExcludePermissions,
                        fileManager: fileManager
                    )
                    changes.append(
                        .init(
                            url: excludeURL,
                            originalData: originalExcludeData,
                            originalPermissions: originalExcludePermissions,
                            writtenData: generatedExcludeData
                        )
                    )
                }
            }

            return Transaction(
                fileManager: fileManager,
                changes: changes,
                createdCursorDirectory: createdCursorDirectory
            )
        } catch let error as ConfigurationError {
            try? Transaction(
                fileManager: fileManager,
                changes: changes,
                createdCursorDirectory: createdCursorDirectory
            ).rollback()
            if let createdCursorDirectory {
                try? removeEmptyDirectory(createdCursorDirectory, fileManager: fileManager)
            }
            throw error
        } catch {
            try? Transaction(
                fileManager: fileManager,
                changes: changes,
                createdCursorDirectory: createdCursorDirectory
            ).rollback()
            if let createdCursorDirectory {
                try? removeEmptyDirectory(createdCursorDirectory, fileManager: fileManager)
            }
            throw ConfigurationError.cannotWriteConfiguration(error.localizedDescription)
        }
    }

    private struct ExistingJSONObject {
        var object: [String: Any]?
    }

    private static func readJSONObject(
        at url: URL,
        fileManager: FileManager
    ) throws -> ExistingJSONObject {
        guard fileManager.fileExists(atPath: url.path) else {
            return ExistingJSONObject(object: nil)
        }
        guard !Transaction.isSymbolicLink(url, fileManager: fileManager) else {
            throw ConfigurationError.symbolicLinkNotAllowed(url.path)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ConfigurationError.invalidConfiguration
        }
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConfigurationError.invalidConfiguration
            }
            return ExistingJSONObject(object: object)
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.invalidConfiguration
        }
    }

    private static func validatedRepositoryURL(
        _ rawPath: String,
        fileManager: FileManager
    ) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { throw ConfigurationError.invalidRepositoryPath }
        let url = URL(fileURLWithPath: trimmed, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConfigurationError.repositoryNotFound
        }
        return url
    }

    private static func validatedExecutablePath(
        _ rawPath: String,
        fileManager: FileManager
    ) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { throw ConfigurationError.invalidExecutablePath }
        let url = URL(fileURLWithPath: trimmed).standardizedFileURL.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: url.path) else { throw ConfigurationError.executableNotFound }
        guard fileManager.isExecutableFile(atPath: url.path) else { throw ConfigurationError.invalidExecutablePath }
        return url.path
    }

    private static func filePermissions(
        at url: URL,
        fileManager: FileManager
    ) throws -> NSNumber? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return attributes[.posixPermissions] as? NSNumber
    }

    private static func writeAtomically(
        _ data: Data,
        to url: URL,
        preservingPermissions permissions: NSNumber?,
        fileManager: FileManager
    ) throws {
        do {
            try data.write(to: url, options: .atomic)
            if let permissions {
                try fileManager.setAttributes(
                    [.posixPermissions: permissions],
                    ofItemAtPath: url.path
                )
            }
        } catch {
            throw ConfigurationError.cannotWriteConfiguration(error.localizedDescription)
        }
    }

    private static func removeEmptyDirectory(_ url: URL, fileManager: FileManager) throws {
        guard !Transaction.isSymbolicLink(url, fileManager: fileManager),
              let contents = try? fileManager.contentsOfDirectory(atPath: url.path),
              contents.isEmpty else { return }
        try fileManager.removeItem(at: url)
    }

    private static func excludingMCPConfig(
        at url: URL,
        originalData: Data?,
        fileManager: FileManager
    ) throws -> Data? {
        let existing = originalData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let excluded = existing.split(whereSeparator: \.isNewline).contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            return line == configRelativePath
                || line == "/\(configRelativePath)"
                || line == ".cursor/"
                || line == "/.cursor/"
                || line == ".cursor"
                || line == "/.cursor"
        }
        guard !excluded else { return nil }
        let suffix = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        return Data((existing + suffix + "\(configRelativePath)\n").utf8)
    }

    private static func gitExcludeURL(
        for repositoryURL: URL,
        fileManager: FileManager
    ) throws -> URL? {
        let dotGitURL = repositoryURL.appendingPathComponent(".git", isDirectory: true)
        guard fileManager.fileExists(atPath: dotGitURL.path) else { return nil }
        guard !Transaction.isSymbolicLink(dotGitURL, fileManager: fileManager) else {
            throw ConfigurationError.symbolicLinkNotAllowed(dotGitURL.path)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory) else { return nil }
        let gitDirectory: URL
        if isDirectory.boolValue {
            gitDirectory = dotGitURL
        } else {
            guard let content = try? String(contentsOf: dotGitURL, encoding: .utf8),
                  let line = content.split(separator: "\n").first,
                  line.hasPrefix("gitdir:") else { return nil }
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            gitDirectory = URL(fileURLWithPath: path, relativeTo: repositoryURL).standardizedFileURL
        }

        let infoDirectory = gitDirectory.appendingPathComponent("info", isDirectory: true)
        if !fileManager.fileExists(atPath: infoDirectory.path) {
            try fileManager.createDirectory(at: infoDirectory, withIntermediateDirectories: true)
        }
        guard !Transaction.isSymbolicLink(infoDirectory, fileManager: fileManager) else {
            throw ConfigurationError.symbolicLinkNotAllowed(infoDirectory.path)
        }
        return infoDirectory.appendingPathComponent("exclude")
    }
}
