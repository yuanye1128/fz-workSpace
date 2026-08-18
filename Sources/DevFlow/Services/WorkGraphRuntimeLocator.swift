import Foundation

/// Resolves only the runtime that ships with DevFlow. This deliberately does
/// not consult PATH or any developer-tool installation on the user's machine.
enum WorkGraphRuntimeLocator {
    static func bundledRuntime() -> WorkGraphParserProcessRuntime? {
        #if SWIFT_PACKAGE
        let bundles = [Bundle.module, Bundle.main]
        #else
        let bundles = [Bundle.main]
        #endif
        return bundles.lazy.compactMap(runtime(in:)).first
    }

    private static func runtime(in bundle: Bundle) -> WorkGraphParserProcessRuntime? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let candidates = [
            resourceURL.appendingPathComponent("WorkGraphRuntime", isDirectory: true),
            resourceURL.appendingPathComponent("Resources/WorkGraphRuntime", isDirectory: true)
        ]
        return candidates.lazy.compactMap(runtime(at:)).first
    }

    static func runtime(at directoryURL: URL) -> WorkGraphParserProcessRuntime? {
        let nodeURL = directoryURL.appendingPathComponent(nodeExecutableName)
        let scriptURL = directoryURL.appendingPathComponent("workgraph-parser.cjs")
        guard FileManager.default.isExecutableFile(atPath: nodeURL.path),
              FileManager.default.isReadableFile(atPath: scriptURL.path) else {
            return nil
        }
        return WorkGraphParserProcessRuntime(
            helperExecutableURL: nodeURL,
            helperArguments: [scriptURL.path]
        )
    }

    private static var nodeExecutableName: String {
        #if arch(arm64)
        "node-arm64"
        #elseif arch(x86_64)
        "node-x86_64"
        #else
        "node-unsupported"
        #endif
    }
}
