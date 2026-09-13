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
        executablePath: String
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

        // Checked before anything is written: a refusal half-way through would
        // leave the repository configured but alias-less.
        if CLI.Command.forShim(CLI.basename(executablePath)) != nil {
            console.err("ERROR: Refusing to write aliases pointing at '\(executablePath)'.")
            console.err("Run bubble-flow-setup through an installed git-bubble-flow binary.")
            return 1
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

        console.out("Creating Git aliases...")

        // The leading '!' makes git run the value as a shell command. Without
        // it git treats the value as a subcommand name and every alias fails.
        // The absolute path means the aliases do not depend on PATH.
        let quoted = shellQuote(executablePath)
        let aliases: [(String, String)] = [
            ("alias.land", "!\(quoted) land"),
            ("alias.verify-bubble", "!\(quoted) verify"),
            ("alias.rebase-bubble", "!\(quoted) rebase"),
            ("alias.bubble-absorb", "!\(quoted) absorb"),
        ]
        for (key, value) in aliases {
            guard await git.passthrough(["config", key, value], config: [:]) == 0 else { return 1 }
        }

        console.out("Bubble-flow setup complete!")
        console.out("")
        console.out("Configuration applied:")
        for (key, value) in applied { console.out("- \(key) = \(value)") }
        console.out("")
        console.out("Git aliases created:")
        console.out("- git land → git-bubble-flow land")
        console.out("- git verify-bubble → git-bubble-flow verify")
        console.out("- git rebase-bubble → git-bubble-flow rebase")
        console.out("- git bubble-absorb → git-bubble-flow absorb")
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

    /// Git runs an alias body through a shell, so the path must survive it.
    ///
    /// The test is an allowlist rather than a list of characters to escape: a
    /// deny-list silently passes through every metacharacter nobody thought of
    /// ($, `, ;, newline, glob characters), and the result is a broken or
    /// dangerous alias written into the user's config.
    static func shellQuote(_ path: String) -> String {
        let isSafe: (Character) -> Bool = { character in
            character.isASCII
                && (character.isLetter || character.isNumber
                    || character == "/" || character == "." || character == "_" || character == "-")
        }
        guard path.allSatisfy(isSafe) else {
            return "'" + path.replacing("'", with: "'\\''") + "'"
        }
        return path
    }
}
