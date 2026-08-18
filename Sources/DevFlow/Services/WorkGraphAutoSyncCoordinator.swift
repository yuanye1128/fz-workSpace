import Foundation

/// Coordinates silent refreshes of the derived WorkGraph cache.
///
/// Queries may arrive from several MCP clients at once. A single in-flight
/// generation is shared by all callers. Source metadata is checked on every
/// query so a just-written file can never be hidden behind a time throttle;
/// generation itself only runs after a change is detected. Source files are
/// never modified; only the disposable `.workgraph` cache is refreshed.
final class WorkGraphAutoSyncCoordinator: @unchecked Sendable {
    enum Result: Equatable {
        case unchanged
        case rebuilt
    }

    private final class Flight: @unchecked Sendable {
        let group = DispatchGroup()
        var result: Swift.Result<Result, Error>?

        init() {
            group.enter()
        }
    }

    private let navigationService: ProjectNavigationService
    private let automaticallyRebuild: Bool
    private let lock = NSLock()
    private var inFlight: [String: Flight] = [:]

    init(
        navigationService: ProjectNavigationService = .init(),
        automaticallyRebuild: Bool = true
    ) {
        self.navigationService = navigationService
        self.automaticallyRebuild = automaticallyRebuild
    }

    /// Ensures the persisted graph represents the current source tree.
    ///
    /// The first caller that detects a change performs the incremental rebuild.
    /// Concurrent callers wait for that same rebuild instead of launching
    /// duplicate parser processes. Normal Agent conversations remain quiet
    /// because unchanged metadata never starts a parser process and no status
    /// notification is emitted to the user.
    @discardableResult
    func ensureCurrent(repositoryPath rawRepositoryPath: String) throws -> Result {
        let repositoryPath = URL(fileURLWithPath: rawRepositoryPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        while true {
            lock.lock()
            if let existing = inFlight[repositoryPath] {
                lock.unlock()
                existing.group.wait()
                guard let result = existing.result else {
                    continue
                }
                return try result.get()
            }

            let flight = Flight()
            inFlight[repositoryPath] = flight
            lock.unlock()

            do {
                let result: Result
                let hasExistingNavigation: Bool
                switch navigationService.status(for: repositoryPath) {
                case .notGenerated:
                    // Generation remains an explicit user action for a new
                    // repository; automatic catch-up only repairs an index
                    // that already exists.
                    hasExistingNavigation = false
                case .current, .updateRecommended:
                    hasExistingNavigation = true
                }
                if hasExistingNavigation,
                   automaticallyRebuild,
                   navigationService.needsRebuild(repositoryPath: repositoryPath) {
                    _ = try navigationService.generateBaseNavigation(repositoryPath: repositoryPath)
                    result = .rebuilt
                } else {
                    result = .unchanged
                }
                finish(repositoryPath: repositoryPath, flight: flight, result: .success(result))
                return result
            } catch {
                finish(repositoryPath: repositoryPath, flight: flight, result: .failure(error))
                throw error
            }
        }
    }

    private func finish(
        repositoryPath: String,
        flight: Flight,
        result: Swift.Result<Result, Error>
    ) {
        lock.lock()
        flight.result = result
        inFlight.removeValue(forKey: repositoryPath)
        lock.unlock()
        flight.group.leave()
    }
}
