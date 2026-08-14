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

struct MergeResult: Sendable {
    var success: Bool
    var conflicts: [String]
    var output: String
    var mergedCommitHash: String?
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
                message: isClean ? "仓库状态正常" : "仓库存在未提交改动（将保留并继续）"
            )
        } catch {
            return RepositoryValidation(isGitRepository: false, isClean: false, currentBranch: "", remoteURL: "", message: error.localizedDescription)
        }
    }

    func currentBranch(at path: String) async throws -> String {
        let result = try await git(["branch", "--show-current"], at: path)
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func checkoutBranch(_ branch: String, at path: String) async throws {
        let exists = try await git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], at: path, allowFailure: true)
        if exists.exitCode == 0 {
            _ = try await git(["checkout", branch], at: path)
        } else {
            _ = try await git(["checkout", "-b", branch], at: path)
        }
    }

    /// 在独立 worktree 上创建任务分支；不会切换主仓库当前分支。
    func createTaskWorktree(
        repositoryPath: String,
        targetBranch: String,
        taskBranch: String,
        worktreePath: String
    ) async throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: worktreePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await ensureLocalBranch(targetBranch, at: repositoryPath)
        let result = try await git(
            ["worktree", "add", "-b", taskBranch, worktreePath, targetBranch],
            at: repositoryPath,
            allowFailure: true
        )
        guard result.exitCode == 0 else {
            throw ProcessRunnerError.failed(
                command: "git worktree add",
                code: result.exitCode,
                message: result.standardError.isEmpty ? result.standardOutput : result.standardError
            )
        }
    }

    /// 为 merge 创建临时 worktree（新分支指向目标分支 tip），避免占用目标分支 checkout。
    func createMergeWorktree(
        repositoryPath: String,
        targetBranch: String,
        mergeBranch: String,
        worktreePath: String
    ) async throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: worktreePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await ensureLocalBranch(targetBranch, at: repositoryPath)
        let result = try await git(
            ["worktree", "add", "-b", mergeBranch, worktreePath, targetBranch],
            at: repositoryPath,
            allowFailure: true
        )
        guard result.exitCode == 0 else {
            throw ProcessRunnerError.failed(
                command: "git worktree add (merge)",
                code: result.exitCode,
                message: result.standardError.isEmpty ? result.standardOutput : result.standardError
            )
        }
    }

    func removeWorktree(worktreePath: String, repositoryPath: String, force: Bool = true) async throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(worktreePath)
        _ = try await git(args, at: repositoryPath, allowFailure: true)
        if FileManager.default.fileExists(atPath: worktreePath) {
            try? FileManager.default.removeItem(atPath: worktreePath)
            _ = try await git(["worktree", "prune"], at: repositoryPath, allowFailure: true)
        }
    }

    func deleteBranch(_ branch: String, at repositoryPath: String, force: Bool = true) async throws {
        var args = ["branch"]
        args.append(force ? "-D" : "-d")
        args.append(branch)
        _ = try await git(args, at: repositoryPath, allowFailure: true)
    }

    /// 将 sourceBranch 的改动 squash 进当前检出，并生成单条 commit（线性历史，无 Merge 节点）。
    func squashMergeBranch(
        _ sourceBranch: String,
        intoCheckoutAt path: String,
        message: String
    ) async throws -> MergeResult {
        let result = try await git(
            ["merge", "--squash", sourceBranch],
            at: path,
            allowFailure: true
        )
        let conflicts = try await unresolvedConflicts(at: path)
        if !conflicts.isEmpty {
            return MergeResult(
                success: false,
                conflicts: conflicts,
                output: result.standardOutput + result.standardError,
                mergedCommitHash: nil
            )
        }
        if result.exitCode != 0 {
            return MergeResult(
                success: false,
                conflicts: [],
                output: result.standardOutput + result.standardError,
                mergedCommitHash: nil
            )
        }

        let status = try await git(["status", "--porcelain"], at: path, allowFailure: true)
        let dirty = !status.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if dirty {
            let commit = try await git(["commit", "-m", message], at: path, allowFailure: true)
            if commit.exitCode != 0 {
                return MergeResult(
                    success: false,
                    conflicts: [],
                    output: commit.standardOutput + commit.standardError,
                    mergedCommitHash: nil
                )
            }
        }

        let hash = try await git(["rev-parse", "HEAD"], at: path)
        return MergeResult(
            success: true,
            conflicts: [],
            output: result.standardOutput,
            mergedCommitHash: hash.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// 将 path 当前 HEAD 推送到远程的目标分支（不要求本地检出该目标分支）。
    func pushHEAD(toRemoteBranch branch: String, remote: String, at path: String) async throws {
        let result = try await git(
            ["push", remote, "HEAD:refs/heads/\(branch)"],
            at: path,
            allowFailure: true
        )
        guard result.exitCode == 0 else {
            throw ProcessRunnerError.failed(
                command: "git push HEAD:\(branch)",
                code: result.exitCode,
                message: result.standardError.isEmpty ? result.standardOutput : result.standardError
            )
        }
    }

    /// 在不影响主工作区 checkout 的前提下，尽量更新本地目标分支指针。
    func updateLocalBranchRef(_ branch: String, to commitHash: String, at repositoryPath: String) async throws {
        let current = try await currentBranch(at: repositoryPath)
        if current == branch {
            // 目标分支正被主工作区占用：不强制移动，避免打乱用户当前工作区。
            return
        }
        _ = try await git(["update-ref", "refs/heads/\(branch)", commitHash], at: repositoryPath, allowFailure: true)
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

    private func ensureLocalBranch(_ branch: String, at repositoryPath: String) async throws {
        let local = try await git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], at: repositoryPath, allowFailure: true)
        if local.exitCode == 0 { return }

        let remote = try await git(["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(branch)"], at: repositoryPath, allowFailure: true)
        if remote.exitCode == 0 {
            _ = try await git(["branch", "--track", branch, "origin/\(branch)"], at: repositoryPath)
            return
        }

        throw ProcessRunnerError.failed(
            command: "git show-ref \(branch)",
            code: 1,
            message: "本地与 origin 均不存在分支 \(branch)，无法创建 worktree"
        )
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
