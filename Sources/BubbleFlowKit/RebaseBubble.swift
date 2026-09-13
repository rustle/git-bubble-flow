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

public enum RebaseBubble {
    public struct Options {
        public var bubble: String?
        public var onto: String?
        public init() {}
    }

    static func parse(_ arguments: [String], console: any Console) -> Options? {
        var options = Options()
        var scanner = ArgumentScanner(arguments)

        while let argument = scanner.peek {
            switch argument {
            case "--bubble":
                guard let value = scanner.takeValue(for: "--bubble") else {
                    console.err("ERROR: --bubble requires a value")
                    return nil
                }
                options.bubble = value
            case "--onto":
                guard let value = scanner.takeValue(for: "--onto") else {
                    console.err("ERROR: --onto requires a value")
                    return nil
                }
                options.onto = value
            case let other:
                console.err("Unknown argument: \(other)")
                return nil
            }
        }
        return options
    }

    /// The base resolved to the one rev used for validation, fetch, rebase, and
    /// the pre/post subject comparison.
    struct ResolvedBase {
        var remote: String?
        var remoteBranch: String?
        var rebaseTarget: String
    }

    /// A local branch may be checked out in another worktree and may lag its
    /// remote, so prefer the remote-tracking ref when one exists. A base that
    /// is already a remote-tracking ref is used as-is.
    static func resolveBase(_ base: String, git: any GitRunning) async -> ResolvedBase? {
        if await git.revisionExists("refs/remotes/\(base)") {
            // Split using the configured remote names, longest first: a remote
            // may itself contain a slash, and so may a branch.
            let remotes = await git.capture(["remote"], config: [:]).lines
                .sorted { $0.count > $1.count }
            let remote = remotes.first { base == $0 || base.hasPrefix("\($0)/") }
            let remoteBranch = remote.map { String(base.dropFirst($0.count + 1)) }
            // A component git would parse as an option is never a ref the user
            // meant. Refuse rather than try to escape it downstream.
            if [remote, remoteBranch, base].compactMap({ $0 }).contains(where: { $0.hasPrefix("-") }) {
                return nil
            }
            return ResolvedBase(remote: remote, remoteBranch: remoteBranch, rebaseTarget: base)
        }
        if await git.revisionExists("refs/remotes/origin/\(base)") {
            return ResolvedBase(remote: "origin", remoteBranch: base, rebaseTarget: "origin/\(base)")
        }
        if await git.revisionExists(base) {
            return ResolvedBase(remote: nil, remoteBranch: nil, rebaseTarget: base)
        }
        return nil
    }

    public static func run(
        arguments: [String],
        git: any GitRunning,
        console: any Console,
        now: Int = Sys.now()
    ) async -> Int32 {
        guard let options = parse(arguments, console: console) else { return 1 }

        let config = BubbleFlowConfig(git: git)

        func error(_ message: String) { console.err("ERROR: \(message)") }

        // diff-index compares stat data, so a file that was merely re-stat'd
        // (touched, or checked out by another tool) reads as modified until the
        // index is refreshed.
        _ = await git.capture(["update-index", "-q", "--refresh"], config: [:])
        if await git.succeeds("diff-index", "--quiet", "HEAD", "--") == false {
            error("Working tree is dirty. Please commit or stash changes before rebasing.")
            return 1
        }

        let currentBranch = await git.capture(["rev-parse", "--abbrev-ref", "HEAD"], config: [:]).value
        if currentBranch.isEmpty || currentBranch == "HEAD" {
            error("Cannot determine current branch")
            return 1
        }

        // Any branch tip can be a bubble, so the current branch is the default.
        let bubble = options.bubble ?? currentBranch
        let configuredBase = if let requested = options.onto { requested } else { await config.base() }
        guard let base = configuredBase else {
            error("No base: bubbleflow.base is not set. Pass --onto <base> or run bubble-flow-setup.")
            return 1
        }

        // Must be a local branch: any other revision rebases onto a detached
        // HEAD and reports success while moving nothing.
        for (value, what) in [(bubble, "bubble"), (base, "base")] {
            if let complaint = BubbleFlowConfig.refComplaint(about: value, describedAs: what) {
                error(complaint)
                return 1
            }
        }

        guard await git.revisionExists("refs/heads/\(bubble)") else {
            error("Bubble branch '\(bubble)' does not exist")
            return 1
        }

        guard let resolved = await resolveBase(base, git: git) else {
            if base.split(separator: "/").contains(where: { $0.hasPrefix("-") }) {
                error(
                    "Base '\(base)' has a component beginning with '-', which git would read as an option.")
            } else {
                error("Base branch '\(base)' does not exist")
            }
            return 1
        }
        let rebaseTarget = resolved.rebaseTarget

        if currentBranch != bubble {
            console.out("Switching to bubble branch: \(bubble)")
            guard await git.passthrough(["checkout", bubble, "--"], config: [:]) == 0 else { return 1 }
        }

        if let remote = resolved.remote, let remoteBranch = resolved.remoteBranch {
            console.out("Fetching \(remoteBranch) from \(remote)")
            // --end-of-options is load-bearing, not decoration. Ref names may
            // begin with "-" (git check-ref-format accepts
            // refs/remotes/origin/--upload-pack=x), and git parses options after
            // positionals, so a branch name in that position would otherwise be
            // read as an option. `git fetch origin --upload-pack=<path>` runs
            // <path>.
            guard
                await git.passthrough(
                    ["fetch", "--end-of-options", remote, remoteBranch], config: [:]
                ) == 0
            else { return 1 }
        }

        let backupTag = await uniqueTag("backup/rebase-bubble-\(backupTimestamp(now))", git: git)
        console.out("Creating backup tag: \(backupTag)")
        guard await git.passthrough(["tag", backupTag], config: [:]) == 0 else { return 1 }

        console.out("Capturing pre-rebase first-parent subjects...")
        let preSubjects = await firstParentSubjects(from: rebaseTarget, to: bubble, git: git)
        if preSubjects.isEmpty {
            console.out("No subjects found in first-parent history")
        }

        console.out("Rebasing bubble branch onto \(rebaseTarget)...")
        console.out("This may take some time as it processes merges...")

        // --rebase-merges re-performs each merge, nested bubbles included, so
        // rerere is what keeps a repeated conflict from having to be resolved
        // twice.
        let rebaseStatus = await git.passthrough(
            ["rebase", "--rebase-merges", "--update-refs", rebaseTarget],
            config: ["rerere.enabled": "true", "rerere.autoUpdate": "true"]
        )
        if rebaseStatus != 0 {
            error(
                "Rebase stopped (likely conflicts). Resolve and 'git rebase --continue', or 'git rebase --abort' to undo."
            )
            console.err("")
            console.err(
                "Full restore: 'git rebase --abort' first, then if needed: git reset --hard \(backupTag)")
            console.err(
                "After the rebase finishes, the script's post-checks did NOT run — verify manually:")
            console.err("  git verify-bubble --base \(rebaseTarget) \(bubble)")
            return 1
        }

        console.out("Verifying rebase results...")
        var verify = VerifyBubble.Options()
        verify.ref = bubble
        verify.base = rebaseTarget
        if await VerifyBubble.run(options: verify, git: git, console: console) != 0 {
            error(
                "Rebase verification failed. The branch has NOT been reset — it is still in its rebased state."
            )
            console.out("")
            console.out("To restore the bubble branch itself, run:")
            console.out("  git reset --hard \(backupTag)")
            console.out("That does NOT restore nested bubble branches: --update-refs moved them")
            console.out("too, and they must be reset individually from the reflog.")
            return 1
        }

        if !preSubjects.isEmpty {
            console.out("Checking bubble subject lists match...")
            let postSubjects = await firstParentSubjects(from: rebaseTarget, to: bubble, git: git)
            // Deliberately not guarded on postSubjects being non-empty: losing
            // every bubble is the case that most needs reporting.
            if preSubjects != postSubjects {
                console.out("WARNING: Bubble subject list changed during rebase")
                console.out("This might require manual inspection")
            }
        }

        console.out("Bubble rebase completed successfully!")
        console.out("")
        console.out("Rebase details:")
        console.out("- Original state backed up to: \(backupTag)")
        console.out("- Bubble branch \(bubble) now rebased onto \(rebaseTarget)")
        console.out("")
        console.out("If you need to recover from this rebase, run:")
        console.out("git reset --hard \(backupTag)")
        return 0
    }

    private static func firstParentSubjects(from base: String, to ref: String, git: any GitRunning)
        async -> [String]
    {
        let result = await git.capture(
            ["log", "--format=%s", "--first-parent", "\(base)..\(ref)"], config: [:])
        guard result.succeeded else { return [] }
        return result.lines.filter { !$0.isEmpty }
    }
}
