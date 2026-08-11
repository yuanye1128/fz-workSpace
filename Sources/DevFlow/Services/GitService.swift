import Foundation

struct RepositoryValidation: Sendable {
    var isGitRepository: Bool
    var isClean: Bool
    var currentBranch: String
    var remoteURL: String
    var message: String
}

struct PullResult: Sendable {
    var hadRemoteBranch: Bool
    var conflicts: [String]
    var output: String
}

final class GitService: @unchecked Sendable {
    private let runner = ProcessRunner()

    func validateRepository(path: String) async -> RepositoryValidation {
        do {
            let inside = try await git(["rev-parse", "--is-inside-work-tree"], at: path)
            guard inside.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
                return RepositoryValidation(isGitRepository: false, isClean: false, currentBranch: "", remoteURL: "", message: "所选目录不是 Git 仓库")
            }
            let status = try await git(["status", "--porcelain"], at: path)
            let branch = try await git(["branch", "--show-current"], at: path)
            let remote = try? await git(["remote", "get-url", "origin"], at: path)
            let isClean = status.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return RepositoryValidation(
                isGitRepository: true,
                isClean: isClean,
                currentBranch: branch.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                remoteURL: remote?.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                message: isClean ? "仓库状态正常" : "仓库存在未提交改动，为避免覆盖已阻止任务"
            )
        } catch {
            return RepositoryValidation(isGitRepository: false, isClean: false, currentBranch: "", remoteURL: "", message: error.localizedDescription)
        }
    }

    func checkoutBranch(_ branch: String, at path: String) async throws {
        let exists = try await git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], at: path, allowFailure: true)
        if exists.exitCode == 0 {
            _ = try await git(["checkout", branch], at: path)
        } else {
            _ = try await git(["checkout", "-b", branch], at: path)
        }
    }

    func changedFiles(at path: String) async throws -> [String] {
        let result = try await git(["status", "--porcelain"], at: path)
        return result.standardOutput
            .split(separator: "\n")
            .map { line -> String in
                let trimmed: Substring = line.dropFirst(min(3, line.count))
                return String(trimmed)
            }
            .filter { !$0.isEmpty }
    }

    func diff(at path: String) async throws -> String {
        let unstaged = try await git(["diff", "--no-ext-diff", "--unified=3"], at: path)
        let staged = try await git(["diff", "--cached", "--no-ext-diff", "--unified=3"], at: path)
        return [unstaged.standardOutput, staged.standardOutput].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func commit(message: String, at path: String) async throws -> String {
        _ = try await git(["add", "-A"], at: path)
        let commit = try await git(["commit", "-m", message], at: path)
        guard commit.exitCode == 0 else {
            throw ProcessRunnerError.failed(command: "git commit", code: commit.exitCode, message: commit.standardError)
        }
        let hash = try await git(["rev-parse", "HEAD"], at: path)
        return hash.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func pullLatest(remote: String, branch: String, at path: String) async throws -> PullResult {
        let remoteBranch = try await git(["ls-remote", "--exit-code", "--heads", remote, branch], at: path, allowFailure: true)
        guard remoteBranch.exitCode == 0 else {
            return PullResult(hadRemoteBranch: false, conflicts: [], output: "远程尚不存在 \(branch)，跳过拉取并将在 push 时创建。")
        }

        let result = try await git(["pull", "--rebase", remote, branch], at: path, allowFailure: true)
        let conflicts = try await unresolvedConflicts(at: path)
        if !conflicts.isEmpty {
            return PullResult(hadRemoteBranch: true, conflicts: conflicts, output: result.standardOutput + result.standardError)
        }
        guard result.exitCode == 0 else {
            throw ProcessRunnerError.failed(command: "git pull --rebase", code: result.exitCode, message: result.standardError)
        }
        return PullResult(hadRemoteBranch: true, conflicts: [], output: result.standardOutput)
    }

    func push(remote: String, branch: String, at path: String) async throws {
        let result = try await git(["push", "--set-upstream", remote, branch], at: path, allowFailure: true)
        guard result.exitCode == 0 else {
            throw ProcessRunnerError.failed(command: "git push", code: result.exitCode, message: result.standardError)
        }
    }

    func restoreUncommittedChanges(at path: String) async throws {
        _ = try await git(["restore", "--staged", "--worktree", "."], at: path, allowFailure: true)
        _ = try await git(["clean", "-fd"], at: path, allowFailure: true)
    }

    private func unresolvedConflicts(at path: String) async throws -> [String] {
        let result = try await git(["diff", "--name-only", "--diff-filter=U"], at: path, allowFailure: true)
        return result.standardOutput.split(separator: "\n").map(String.init)
    }

    private func git(_ arguments: [String], at path: String, allowFailure: Bool = false) async throws -> ProcessResult {
        let result = try await runner.run(command: "git", arguments: arguments, workingDirectory: path)
        if !allowFailure && result.exitCode != 0 {
            throw ProcessRunnerError.failed(command: "git \(arguments.joined(separator: " "))", code: result.exitCode, message: result.standardError)
        }
        return result
    }
}
