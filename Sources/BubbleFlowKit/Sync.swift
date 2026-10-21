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

/// `git stack-bubble sync`: brings local branches onto a stack someone else
/// restacked.
///
/// `git pull --rebase` decides what to replay from the remote-tracking ref's
/// reflog, which is wrong after a missed generation or a background fetch.
/// Sync decides from the old→new pairs every restack publishes instead: a
/// branch's commits are the ones above its nearest rewritten ancestor, and they
/// go onto that ancestor's newest equivalent.
enum Sync {
    struct Options: Equatable {
        var stack: String?
        var dryRun = false
        var branches: [String] = []
    }

    static func parse(_ arguments: [String], console: any Console) -> Options? {
        var options = Options()
        var scanner = ArgumentScanner(arguments)
        while let argument = scanner.peek {
            switch argument {
            case "--stack":
                guard let value = scanner.takeValue(for: argument) else {
                    console.err("ERROR: --stack requires a value")
                    return nil
                }
                options.stack = value
            case "--dry-run", "-n":
                options.dryRun = true
                scanner.advance()
            case let other where other.hasPrefix("-"):
                console.err("Unknown argument: \(other)")
                return nil
            case let other:
                options.branches.append(other)
                scanner.advance()
            }
        }
        return options
    }

    /// What sync will do to one branch.
    enum Action: Equatable {
        /// No commits of its own: it simply moves.
        case move(to: String)
        /// Its own commits, `from..tip`, are replayed onto `onto`.
        case replay(from: String, onto: String)
    }

    /// Follows old→new pairs to the newest equivalent of `commit`, across as
    /// many generations as were missed.
    static func resolve(_ commit: String, in map: [String: String]) -> String {
        var current = commit
        var steps = 0
        while let next = map[current], steps <= map.count {
            current = next
            steps += 1
        }
        return current
    }

    static func run(
        arguments: [String], git: any GitRunning, console: any Console, now: Int
    ) async -> Int32 {
        guard let options = parse(arguments, console: console) else { return 1 }
        guard let name = await StackBubble.resolveName(options.stack, git: git, console: console) else { return 1 }
        func error(_ message: String) { console.err("ERROR: \(message)") }
        for branch in options.branches {
            if let complaint = BubbleFlowConfig.refComplaint(about: branch, describedAs: "branch") {
                error(complaint)
                return 1
            }
        }
        let stack = StackGit(git: git)

        if await stack.sha(RestackState.ref(for: name)) != nil {
            error("A restack of '\(name)' is in progress here. Finish or abort it first.")
            return 1
        }
        let remote = await StackBubble.remote(for: name, git: git)
        console.out("Fetching \(remote)...")
        guard await git.passthrough(["fetch", "--quiet", "--end-of-options", remote], config: [:]) == 0 else {
            return 1
        }
        guard
            let (manifest, manifestSHA) = await StackBubble.fetchManifest(
                name: name, remote: remote, git: git, console: console)
        else { return 1 }
        if let lock = manifest.lock {
            error("'\(name)' is being restacked by \(lock.by) (since \(backupTimestamp(lock.since))).")
            console.err("Sync once it is published.")
            return 1
        }
        guard let baseTip = await stack.sha("refs/remotes/\(remote)/\(manifest.base)") else {
            error("'\(remote)/\(manifest.base)' does not exist.")
            return 1
        }

        let map = await stack.rewriteHistory(at: manifestSHA)
        let stackBranches = Set([manifest.umbrella] + manifest.bubbles.compactMap(\.branch) + manifest.pending)

        let candidates: [String]
        if options.branches.isEmpty {
            candidates = await git.capture(
                ["for-each-ref", "--format=%(refname:strip=2)", "refs/heads/"], config: [:]
            ).lines
        } else {
            candidates = options.branches
        }

        var plan: [(branch: String, tip: String, action: Action)] = []
        var refused: [String] = []
        for branch in candidates {
            guard let tip = await stack.sha("refs/heads/\(branch)") else {
                if !options.branches.isEmpty {
                    error("'\(branch)' is not a local branch.")
                    refused.append(branch)
                }
                continue
            }
            let upstream =
                stackBranches.contains(branch) ? await stack.sha("refs/remotes/\(remote)/\(branch)") : nil
            let action = await decide(
                branch: branch, tip: tip, upstream: upstream, base: baseTip, map: map, stack: stack,
                console: console, named: !options.branches.isEmpty)
            switch action {
            case .some(.some(let action)): plan.append((branch, tip, action))
            case .some(.none): continue
            case .none: refused.append(branch)
            }
        }

        if plan.isEmpty {
            console.out(refused.isEmpty ? "Everything is already on generation \(manifest.generation)." : "")
            return refused.isEmpty ? 0 : 1
        }
        for entry in plan {
            switch entry.action {
            case .move(let target):
                console.out("\(entry.branch): move to \(String(target.prefix(12)))")
            case .replay(let from, let onto):
                let count = await git.capture(["rev-list", "--count", "\(from)..\(entry.tip)"], config: [:]).value
                console.out("\(entry.branch): replay \(count) commit(s) onto \(String(onto.prefix(12)))")
            }
        }
        if options.dryRun { return refused.isEmpty ? 0 : 1 }

        guard let common = await stack.commonDirectory() else {
            error("Could not locate the repository's git directory.")
            return 1
        }
        let scratch = "\(common)/stack-bubble/sync-\(name)"
        let scratchGit = WorktreeGit(path: scratch, git: git)
        var scratchReady = false
        let backupPrefix = "backup/sync-\(name)-\(backupTimestamp(now))"
        let worktrees = await Worktree.list(git: git)

        for entry in plan {
            let target: String
            switch entry.action {
            case .move(let to):
                target = to
            case .replay(let from, let onto):
                if !scratchReady {
                    _ = await git.capture(["worktree", "remove", "--force", scratch], config: [:])
                    _ = await git.capture(["worktree", "prune"], config: [:])
                    let added = await git.capture(
                        ["worktree", "add", "--detach", "--quiet", scratch, onto], config: [:])
                    guard added.succeeded else {
                        console.err(String(added.standardError.trimmedWhitespace()))
                        error("Could not create a worktree to replay in at \(scratch).")
                        return 1
                    }
                    scratchReady = true
                }
                let replayed = await scratchGit.capture(
                    ["rebase", "--rebase-merges", "--onto", onto, from, entry.tip],
                    config: Restack.Context.rebaseConfig)
                guard replayed.succeeded,
                    let head = await scratchGit.capture(["rev-parse", "HEAD"], config: [:]).value.nonEmpty
                else {
                    _ = await scratchGit.capture(["rebase", "--abort"], config: [:])
                    console.out("\(entry.branch): conflicts on the new stack, so it was left as it is.")
                    console.out("  Replay it yourself: git rebase --rebase-merges --onto \(onto) \(from) \(entry.branch)")
                    refused.append(entry.branch)
                    continue
                }
                target = head
            }
            guard
                await stack.moveLocal(
                    entry.branch, from: entry.tip, to: target, backup: "\(backupPrefix)/\(entry.branch)",
                    worktrees: worktrees, console: console)
            else {
                refused.append(entry.branch)
                continue
            }
            if case .replay(let from, let onto) = entry.action {
                console.out("")
                console.out("== \(entry.branch)")
                _ = await git.passthrough(["range-diff", "\(from)..\(entry.tip)", "\(onto)..\(target)"], config: [:])
            }
        }
        if scratchReady {
            _ = await git.capture(["worktree", "remove", "--force", scratch], config: [:])
        }

        console.out("")
        console.out("Synced to generation \(manifest.generation). Previous positions are under \(backupPrefix)/.")
        if !refused.isEmpty {
            console.out("Not synced: \(refused.joined(separator: ", "))")
            return 1
        }
        return 0
    }

    /// The action for one branch: `.some(nil)` when it needs none, and nil
    /// when it cannot be synced, after saying why.
    ///
    /// A stack branch (one the manifest names) follows its remote-tracking
    /// ref. Any other branch follows the stack only if it is built on a commit
    /// a restack rewrote; one that is not was never on the stack and is left
    /// alone.
    static func decide(
        branch: String, tip: String, upstream: String?, base: String, map: [String: String],
        stack: StackGit, console: any Console, named: Bool
    ) async -> Action?? {
        if let upstream {
            // isAncestor is true for equal commits too.
            if await stack.isAncestor(upstream, of: tip) {
                return .some(nil)  // Current, or ahead with commits to push.
            }
            if await stack.isAncestor(tip, of: upstream) {
                return .some(.move(to: upstream))
            }
        }

        // The nearest rewritten ancestor. Listing only what the base lacks
        // keeps the walk to the stack's own commits, and topological order
        // puts the nearest first.
        let walk = await stack.git.capture(
            ["rev-list", "--topo-order", tip, "--not", base], config: [:])
        guard let fork = walk.lines.first(where: { map[$0] != nil }) else {
            if upstream != nil {
                console.out(
                    "\(branch): has commits of its own on a history no generation of the stack rewrote, "
                        + "so it was left as it is.")
                return nil
            }
            if named { console.out("\(branch): not built on the stack; nothing to do.") }
            return .some(nil)
        }
        let newFork = resolve(fork, in: map)
        let onto: String
        if let upstream, await stack.isAncestor(newFork, of: upstream) {
            onto = upstream
        } else {
            onto = newFork
        }
        if fork == tip { return .some(.move(to: onto)) }
        return .some(.replay(from: fork, onto: onto))
    }
}
