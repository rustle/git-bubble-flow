// Copyright 2026 Doug Russell
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// One entry of `git worktree list --porcelain`.
public struct Worktree: Sendable, Equatable {
    public var path: String
    public var head: String?
    /// The full ref, `refs/heads/<name>`. Nil for a detached or bare entry.
    public var branch: String?
    public var isBare = false
    public var isDetached = false
    /// Present when the entry carries the attribute. The string is git's
    /// reason, which is often empty.
    public var lockedReason: String?
    public var prunableReason: String?

    public var isLocked: Bool { lockedReason != nil }
    public var isPrunable: Bool { prunableReason != nil }

    public init(path: String) { self.path = path }

    /// Every worktree of the current repository, or an empty list when git
    /// cannot say.
    ///
    /// The `-z` form is asked for first because the line-based one cannot
    /// represent a path containing a newline -- git's own documentation says so
    /// -- and a truncated path would name the wrong directory. Falling back
    /// keeps a git too old for `-z` (pre-2.36) working, where the worst case is
    /// the checkout below failing with git's own message.
    public static func list(git: any GitRunning) async -> [Worktree] {
        let zeroTerminated = await git.capture(["worktree", "list", "--porcelain", "-z"], config: [:])
        if zeroTerminated.succeeded {
            return parse(zeroTerminated.standardOutput, separator: "\0")
        }
        let lineBased = await git.capture(["worktree", "list", "--porcelain"], config: [:])
        guard lineBased.succeeded else { return [] }
        return parse(lineBased.standardOutput, separator: "\n")
    }

    /// The worktree that has `branch` checked out, if any.
    ///
    /// git allows a branch to be checked out in at most one worktree, so the
    /// first match is the only one. A bare entry has no branch and so never
    /// matches.
    public static func holding(branch: String, git: any GitRunning) async -> Worktree? {
        await list(git: git).first { $0.branch == "refs/heads/\(branch)" }
    }

    /// Both porcelain forms are the same grammar over a different separator:
    /// `<key>[ <value>]` records, an empty entry ending each record.
    static func parse(_ output: String, separator: Character) -> [Worktree] {
        var worktrees: [Worktree] = []
        var current: Worktree?

        for field in output.split(separator: separator, omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let finished = current { worktrees.append(finished) }
                current = nil
                continue
            }
            // Split once: a path may contain spaces, and a lock reason is free
            // text.
            let key: Substring
            let value: Substring
            if let space = field.firstIndex(of: " ") {
                key = field[field.startIndex..<space]
                value = field[field.index(after: space)...]
            } else {
                key = field
                value = ""
            }

            switch key {
            case "worktree":
                if let finished = current { worktrees.append(finished) }
                current = Worktree(path: String(value))
            case "HEAD": current?.head = String(value)
            case "branch": current?.branch = String(value)
            case "bare": current?.isBare = true
            case "detached": current?.isDetached = true
            case "locked": current?.lockedReason = String(value)
            case "prunable": current?.prunableReason = String(value)
            default: continue  // An attribute added by a newer git.
            }
        }
        if let finished = current { worktrees.append(finished) }
        return worktrees
    }
}

/// A `GitRunning` aimed at another worktree of the same repository.
///
/// `-C` alone is not enough, and gets this wrong silently. git exports `GIT_DIR`
/// to `!` aliases -- which is how `git land` runs -- pointing at the *invoking*
/// worktree, and an inherited `GIT_DIR` beats the directory git was told to run
/// in. `git -C ../feature merge` would merge into the current branch instead.
/// The explicit `--git-dir`/`--work-tree` override the environment.
///
/// `<path>/.git` is a gitfile in a linked worktree and a directory in the main
/// one. git resolves both.
struct WorktreeGit: GitRunning {
    let path: String
    let git: any GitRunning

    private var redirect: [String] {
        ["-C", path, "--git-dir=\(path)/.git", "--work-tree=\(path)"]
    }

    func capture(_ arguments: [String], config: [String: String]) async -> GitResult {
        await git.capture(redirect + arguments, config: config)
    }

    func passthrough(_ arguments: [String], config: [String: String]) async -> Int32 {
        await git.passthrough(redirect + arguments, config: config)
    }
}
