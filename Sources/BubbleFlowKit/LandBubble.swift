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

public enum LandBubble {
    public struct Options {
        public var target: String?
        public var message: String?
        public init() {}
    }

    static func parse(_ arguments: [String], console: any Console) -> Options? {
        var options = Options()
        var scanner = ArgumentScanner(arguments)

        while let argument = scanner.peek {
            switch argument {
            case "--target":
                guard let value = scanner.takeValue(for: "--target") else {
                    console.err("ERROR: --target requires a value")
                    return nil
                }
                options.target = value
            case "-m", "--message":
                guard let value = scanner.takeValue(for: argument, allowLeadingDash: true) else {
                    console.err("ERROR: \(argument) requires a value")
                    return nil
                }
                options.message = value
            case let other:
                console.err("Unknown argument: \(other)")
                return nil
            }
        }
        return options
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

        let configuredTarget =
            if let requested = options.target { requested } else { await config.defaultLandTarget() }
        guard let target = configuredTarget else {
            error("No target: bubbleflow.targets is not set. Pass --target <branch> or run bubble-flow-setup.")
            return 1
        }

        // Dirty working tree
        // diff-index compares stat data, so a file that was merely re-stat'd
        // (touched, or checked out by another tool) reads as modified until the
        // index is refreshed.
        _ = await git.capture(["update-index", "-q", "--refresh"], config: [:])
        if await git.succeeds("diff-index", "--quiet", "HEAD", "--") == false {
            error("Working tree is dirty. Please commit or stash changes before landing.")
            return 1
        }

        let currentBranch = await git.capture(["rev-parse", "--abbrev-ref", "HEAD"], config: [:]).value
        if currentBranch.isEmpty || currentBranch == "HEAD" {
            error("Cannot determine current branch")
            return 1
        }

        // Ticket extraction uses the same pattern (and the same fallback) as
        // `verify-bubble --strict`, so the two never disagree.
        let pattern = await config.ticketPattern()
        if let complaint = BubbleFlowConfig.anchorComplaint(about: pattern) {
            error(complaint)
            console.err("It is searched for inside the branch name, so anchors match nothing.")
            return 1
        }
        guard let ticketRegex = try? Regex(pattern) else {
            error("Invalid bubbleflow.ticketPattern: \(pattern)")
            return 1
        }
        guard let match = currentBranch.firstMatch(of: ticketRegex) else {
            error("Could not extract ticket from branch name: \(currentBranch)")
            return 1
        }
        let ticket = String(currentBranch[match.range])

        if let complaint = BubbleFlowConfig.refComplaint(about: target, describedAs: "target") {
            error(complaint)
            return 1
        }

        // Must be a local branch. Any other revision -- a remote-tracking ref,
        // a tag, a sha -- checks out to a detached HEAD, and the land then
        // "succeeds" while moving no branch at all. `git land --target
        // origin/<branch>` in a stale clone is the easy way to hit this.
        guard await git.revisionExists("refs/heads/\(target)") else {
            if await git.revisionExists(target) {
                error(
                    "Target '\(target)' is not a local branch. Landing onto it would leave a detached HEAD.")
            } else {
                error("Target branch '\(target)' does not exist")
            }
            return 1
        }

        if await git.succeeds("merge-base", "--is-ancestor", target, "HEAD") == false {
            error(
                "Target '\(target)' is not an ancestor of the current branch. Please rebase onto '\(target)' first."
            )
            return 1
        }

        var message = options.message ?? ""
        if message.isEmpty {
            message = await git.capture(["log", "--format=%s", "-1", "HEAD"], config: [:]).value
            if message.isEmpty { message = "Merge \(ticket)" }
        }

        console.out("Checking out target branch: \(target)")
        // The trailing "--" ends option parsing for the pathspec that follows.
        // It is the branch having been validated as refs/heads/<target> above
        // that keeps a name beginning with "-" from being read as an option.
        guard await git.passthrough(["checkout", target, "--"], config: [:]) == 0 else { return 1 }

        let preMergeTip = await git.capture(["rev-parse", "HEAD"], config: [:]).value
        guard !preMergeTip.isEmpty else {
            error("Could not read the pre-merge tip of '\(target)'")
            return 1
        }

        // Back up the target's pre-merge tip — the only ref this land advances
        // (the feature branch itself is never rewritten).
        let backupTag = await uniqueTag(
            "backup/land-\(currentBranch)-\(backupTimestamp(now))", git: git)
        console.out("Creating backup tag: \(backupTag) (pre-merge \(target))")
        guard await git.passthrough(["tag", backupTag], config: [:]) == 0 else { return 1 }

        let mergeMessage = "Merge \(ticket): \(message)"
        console.out("Merging \(currentBranch) into \(target) with message: \(mergeMessage)")
        guard
            await git.passthrough(
                ["merge", "--no-ff", "-m", mergeMessage, "--", currentBranch], config: [:]
            ) == 0
        else {
            return 1
        }

        // `git merge` exits 0 without creating a commit when there is nothing to
        // merge ("Already up to date"). Without this check land announces
        // success, tells the user to push, and leaves a backup tag behind for a
        // branch it never advanced.
        let postMergeTip = await git.capture(["rev-parse", "HEAD"], config: [:]).value
        if postMergeTip == preMergeTip {
            error("Nothing to land: '\(currentBranch)' adds no commits to '\(target)'.")
            // Captured, not passed through: git's "Deleted tag" line would
            // otherwise follow the error and read like a consequence of it.
            _ = await git.capture(["tag", "-d", backupTag], config: [:])
            return 1
        }

        // Verify exactly the new merge commit: passing the base explicitly keeps
        // this from depending on bubbleflow.base or on the repo's alias state.
        console.out("Verifying the new bubble is empty...")
        var verify = VerifyBubble.Options()
        verify.ref = "HEAD"
        verify.base = "HEAD~1"
        if await VerifyBubble.run(options: verify, git: git, console: console) != 0 {
            error("New bubble failed verification. Resetting \(target) to its pre-merge state.")
            // Reset to the tip recorded before the merge rather than ORIG_HEAD,
            // which other git commands also write and which is only correct here
            // by coincidence.
            if await git.passthrough(["reset", "--hard", preMergeTip, "--"], config: [:]) == 0 {
                console.err(
                    "You are now on '\(target)' at its pre-merge commit. '\(currentBranch)' is unchanged.")
            } else {
                console.err("Could not reset '\(target)'. Recover with: git reset --hard \(backupTag)")
            }
            return 1
        }

        console.out("Bubble successfully landed!")
        console.out("To push the updated target branch:")
        console.out("git push origin \(target)")
        console.out("")
        console.out("If you want to clean up, you can remove the backup tag:")
        console.out("git tag -d \(backupTag)")
        return 0
    }
}
