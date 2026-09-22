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

public enum Setup {
    public static func run(
        arguments: [String],
        git: any GitRunning,
        console: any Console,
        searchPath: String = Sys.environment("PATH") ?? ""
    ) async -> Int32 {
        var requestedBase: String?
        var scanner = ArgumentScanner(arguments)
        while let argument = scanner.peek {
            switch argument {
            case "--base":
                guard let value = scanner.takeValue(for: "--base") else {
                    console.err("ERROR: --base requires a value")
                    return 1
                }
                requestedBase = value
            case let other:
                console.err("Unknown argument: \(other)")
                return 1
            }
        }

        guard await git.succeeds("rev-parse", "--git-dir") else {
            console.err("ERROR: Not inside a Git repository")
            return 1
        }

        // No branch name is built in. Without --base, the branch HEAD points
        // at is the base. symbolic-ref answers even before the first commit.
        let base: String
        if let requestedBase {
            base = requestedBase
        } else {
            let head = await git.capture(["symbolic-ref", "--short", "HEAD"], config: [:])
            guard head.succeeded, !head.value.isEmpty else {
                console.err("ERROR: HEAD is detached, so there is no branch to use as the base.")
                console.err("Pass one explicitly: bubble-flow-setup --base <branch>")
                return 1
            }
            base = head.value
        }
        if let complaint = BubbleFlowConfig.refComplaint(about: base, describedAs: "base") {
            console.err("ERROR: \(complaint)")
            return 1
        }

        // A warning rather than a refusal. Nothing written below depends on
        // PATH being right at this moment, and PATH here is not necessarily
        // PATH at the time the commands are used.
        //
        // Git.resolve ignores relative PATH entries on purpose, so an install
        // reachable only through one is reported as missing. That is why the
        // wording says "absolute".
        let missing = [CLI.Command.land, .verify, .rebase, .absorb]
            .map(\.shimName)
            .filter { Git.resolve(program: $0, path: searchPath) == nil }
        if !missing.isEmpty {
            console.err("WARNING: not on an absolute PATH entry: \(missing.joined(separator: ", "))")
            console.err("The commands they back will not run until their directory is on PATH.")
        }

        console.out("Setting up bubble-flow in this repository...")
        console.out("Configuring Git settings...")

        // Scoped to this repo, and deliberately not a global merge.ff=false,
        // which would change `git pull` everywhere.
        let settings: [(String, String)] = [
            ("pull.ff", "only"),
            ("rerere.enabled", "true"),
            ("rerere.autoUpdate", "true"),
            ("bubbleflow.targets", base),
            ("bubbleflow.ticketPattern", BubbleFlowConfig.defaultTicketPattern),
            ("bubbleflow.base", base),
        ]
        // Never clobber a value the repository already set: re-running setup
        // used to reset a customised ticket pattern back to the default.
        var applied: [(String, String)] = []
        for (key, value) in settings {
            // --local on purpose: a plain --get also reads global and system
            // config, so a user's global rerere.enabled=false would suppress the
            // repository-level write and silently disable rerere here.
            let existing = await git.capture(["config", "--local", "--get", key], config: [:])
            if existing.succeeded, !existing.value.trimmedWhitespace().isEmpty {
                applied.append((key, "\(existing.value)  (kept, already set)"))
                continue
            }
            guard await git.passthrough(["config", key, value], config: [:]) == 0 else { return 1 }
            applied.append((key, value))
        }

        console.out("Creating the Git alias...")

        // A bare subcommand, not a '!' shell body naming a path. Git expands
        // `git land` to this value and then finds `git-land-bubble` on PATH
        // itself. Writing a path instead would name the versioned directory a
        // `brew upgrade` deletes, breaking every configured repository.
        //
        // `land` is the only name that needs an alias at all. The other three
        // shims are already called `git-<subcommand>`, which is exactly how
        // git discovers an external subcommand.
        guard await git.passthrough(["config", "alias.land", "land-bubble"], config: [:]) == 0 else {
            return 1
        }

        console.out("Bubble-flow setup complete!")
        console.out("")
        console.out("Configuration applied:")
        for (key, value) in applied { console.out("- \(key) = \(value)") }
        console.out("")
        console.out("Git alias created:")
        console.out("- git land → git-land-bubble")
        console.out("")
        console.out("Found on PATH, needing no alias:")
        console.out("- git verify-bubble, git rebase-bubble, git bubble-absorb")
        console.out("")
        console.out("To customize settings, use:")
        console.out("git config bubbleflow.base <branch-name>")
        console.out("git config bubbleflow.ticketPattern <pattern>")
        console.out("")
        console.out("Examples:")
        console.out("git land -m \"Feature implementation\"")
        console.out("git rebase-bubble --onto origin/\(base)")
        console.out("git verify-bubble --strict")
        return 0
    }
}
