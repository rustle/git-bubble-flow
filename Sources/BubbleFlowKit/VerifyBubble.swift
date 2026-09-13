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

/// A bubble is an empty merge commit whose second parent reaches one or more
/// logical commits or nested bubbles. Verification walks the first-parent line
/// of the requested range and, for every merge on it, checks the merge is
/// empty and then walks the bubble's own contents the same way.
public enum VerifyBubble {
    public static let usage = "Usage: git-verify-bubble [<ref>] [--base <ref>] [--strict]"

    public struct Options {
        public var ref: String = "HEAD"
        public var base: String?
        public var strict = false
        public init() {}
    }

    /// Parses the shell script's argument grammar. Returns nil after writing the
    /// script's own diagnostic, meaning "exit 1".
    static func parse(_ arguments: [String], console: any Console) -> Options? {
        var options = Options()
        var seenRef: String?
        var scanner = ArgumentScanner(arguments)

        while let argument = scanner.peek {
            switch argument {
            case "--base":
                guard let value = scanner.takeValue(for: "--base") else {
                    console.err("FATAL: --base requires a value")
                    return nil
                }
                options.base = value
            case "--strict":
                options.strict = true
                scanner.advance()
            case let other where other.hasPrefix("-"):
                console.err("FATAL: Unknown option: \(other)")
                console.err(usage)
                return nil
            case let other:
                // Exactly one positional <ref> is allowed. Silently keeping
                // only the last one would let callers believe a range was
                // checked when it wasn't.
                if let existing = seenRef {
                    console.err(
                        "FATAL: Multiple refs given ('\(existing)', '\(other)'). Pass one <ref> and use --base for the base."
                    )
                    return nil
                }
                seenRef = other
                scanner.advance()
            }
        }

        if let seenRef { options.ref = seenRef }
        return options
    }

    public static func run(
        arguments: [String],
        git: any GitRunning,
        console: any Console
    ) async -> Int32 {
        guard let options = parse(arguments, console: console) else { return 1 }
        return await run(options: options, git: git, console: console)
    }

    public static func run(
        options: Options,
        git: any GitRunning,
        console: any Console
    ) async -> Int32 {
        let config = BubbleFlowConfig(git: git)
        // `??` takes an autoclosure, which cannot carry an `await`.
        let configuredBase = if let requested = options.base { requested } else { await config.base() }
        guard let base = configuredBase else {
            console.err("FATAL: No base: bubbleflow.base is not set. Pass --base <ref> or run bubble-flow-setup.")
            return 1
        }
        let ticketPattern = await config.ticketPattern()
        let ref = options.ref

        for (value, what) in [(ref, "reference"), (base, "base reference")] {
            if let complaint = BubbleFlowConfig.refComplaint(about: value, describedAs: what) {
                console.err("FATAL: \(complaint)")
                return 1
            }
        }

        guard await git.revisionExists(ref) else {
            console.err("FATAL: Invalid reference: \(ref)")
            return 1
        }

        // The base was previously passed straight to `git merge-base`, where an
        // option-shaped value is parsed as an option: `merge-base --octopus
        // <ref>` prints <ref> itself, making the range empty and the gate pass
        // having checked nothing.
        guard await git.revisionExists(base) else {
            console.err("FATAL: Invalid base reference: \(base)")
            return 1
        }

        let mergeBaseResult = await git.capture(["merge-base", base, ref], config: [:])
        let mergeBase = mergeBaseResult.value
        guard mergeBaseResult.succeeded, !mergeBase.isEmpty else {
            let detail = mergeBaseResult.standardError.trimmedWhitespace()
            if !detail.isEmpty { console.err(String(detail)) }
            console.err("FATAL: Could not determine merge base between \(base) and \(ref)")
            return 1
        }

        console.out("Verifying bubbles from merge base \(mergeBase) to \(ref)")

        if let complaint = BubbleFlowConfig.anchorComplaint(about: ticketPattern) {
            console.err("FATAL: \(complaint)")
            console.err("It is embedded in a larger pattern, so anchors match nothing.")
            return 1
        }

        var walker = Walker(git: git, console: console)
        if options.strict {
            guard let strictSubject = try? Regex("^Merge (?:\(ticketPattern)):") else {
                console.err("FATAL: Invalid bubbleflow.ticketPattern: \(ticketPattern)")
                return 1
            }
            walker.strictSubject = strictSubject
        }

        guard await walker.walk(from: mergeBase, to: ref, label: "", depth: 0) else { return 1 }

        if walker.invalidBubbles > 0 {
            console.err("Validation failed: \(walker.invalidBubbles) invalid bubble(s) found")
            return 1
        }
        if walker.strictViolations > 0 {
            console.err("Validation failed: \(walker.strictViolations) strict-mode violation(s) found")
            return 1
        }
        if walker.bubblesChecked == 0 {
            // Distinguish "nothing in range" from "commits, but no merges":
            // the second used to be reported as a passing bubble count.
            if walker.commitsWalked == 0 {
                console.out("No bubbles found to verify")
            } else {
                console.out(
                    "No bubbles found to verify (\(walker.commitsWalked) non-merge commit(s) on the first-parent line)"
                )
            }
            return 0
        }
        console.out(
            "All validations passed for \(walker.bubblesChecked) bubble(s) across \(walker.commitsWalked) first-parent commit(s)"
        )
        return 0
    }

    /// The recursive walk and the tallies it accumulates across every depth.
    struct Walker {
        let git: any GitRunning
        let console: any Console
        /// Set only under --strict.
        var strictSubject: Regex<AnyRegexOutput>?

        /// Commits directly on the verified range, outside any bubble.
        var commitsWalked = 0
        /// Bubbles at every depth.
        var bubblesChecked = 0
        var invalidBubbles = 0
        var strictViolations = 0

        /// Walks the first-parent line of `base..ref`. At depth 0 that line is
        /// the history under verification. Inside a bubble it is the bubble's
        /// contents, where a non-merge commit is a logical commit and a merge
        /// is a nested bubble. Returns false on a fatal condition.
        mutating func walk(from base: String, to ref: String, label: String, depth: Int) async -> Bool {
            let listing = await git.capture(
                ["rev-list", "--first-parent", "\(base)..\(ref)"], config: [:])
            guard listing.succeeded else {
                // Without this the empty output of a failed walk is
                // indistinguishable from "no commits in range", and verify
                // passes vacuously.
                let detail = listing.standardError.trimmedWhitespace()
                if !detail.isEmpty { console.err(String(detail)) }
                console.err("FATAL: Could not list the first-parent history of \(ref)")
                return false
            }

            let indent = String(repeating: "  ", count: depth)
            var bubblesOnThisLine = 0

            for commit in listing.lines {
                if depth == 0 { commitsWalked += 1 }

                let subject = await git.capture(["log", "--format=%s", "-1", commit], config: [:]).value
                // `git rev-list --max-count=1 --parents` prints the commit
                // followed by its parents, so the word count is 1 + parents.
                let words = await git.capture(
                    ["rev-list", "--max-count=1", "--parents", commit], config: [:]
                )
                .value
                .split(whereSeparator: \.isWhitespace)
                let parentCount = max(words.count - 1, 0)

                if parentCount > 2 {
                    console.err(
                        "FATAL: Octopus merge detected with \(parentCount) parents: \(commit) (\(subject))")
                    return false
                }

                guard parentCount == 2 else {
                    // A non-merge commit directly on the verified range, outside
                    // any bubble, is what --strict forbids. Inside a bubble it is
                    // simply a logical commit.
                    if depth == 0, strictSubject != nil {
                        console.err(
                            "STRICT: Non-merge commit found on first-parent line: \(commit) (\(subject))")
                        strictViolations += 1
                    }
                    continue
                }

                bubblesChecked += 1
                bubblesOnThisLine += 1
                let bubbleLabel = label.isEmpty ? "\(bubblesOnThisLine)" : "\(label).\(bubblesOnThisLine)"

                let commitTree = await git.capture(["rev-parse", "\(commit)^{tree}"], config: [:]).value
                let secondParentTree = await git.capture(["rev-parse", "\(commit)^2^{tree}"], config: [:])
                    .value

                if commitTree == secondParentTree {
                    console.out("\(indent)\u{2713} Bubble \(bubbleLabel): \(commit) (\(subject))")
                } else {
                    console.err("\(indent)FATAL: Non-empty bubble \(bubbleLabel): \(commit) (\(subject))")
                    console.err("\(indent)  Commit tree: \(commitTree)")
                    console.err("\(indent)  Parent2 tree: \(secondParentTree)")
                    invalidBubbles += 1
                }

                if let strictSubject, subject.firstMatch(of: strictSubject) == nil {
                    console.err(
                        "\(indent)STRICT: Subject line doesn't match 'Merge <TICKET>: ' convention: \(subject)")
                    strictViolations += 1
                }

                // The bubble's contents: everything its second parent reaches
                // that its first parent does not.
                guard
                    await walk(from: "\(commit)^1", to: "\(commit)^2", label: bubbleLabel, depth: depth + 1)
                else { return false }
            }
            return true
        }
    }
}
