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

/// Multi-call dispatch, busybox style: one binary, and symlinks named after the
/// git subcommands select a mode. Keeps `git verify-bubble` working through
/// git's PATH-based subcommand discovery with no wrapper scripts to install.
public enum CLI {
    public static let version = "0.2.0"

    public enum Command: String, CaseIterable, Sendable {
        case verify
        case land
        case rebase
        case absorb
        case stack
        case setup

        /// The name a symlink must have for git to find it as a subcommand.
        public var shimName: String {
            switch self {
            case .verify: "git-verify-bubble"
            case .land: "git-land-bubble"
            case .rebase: "git-rebase-bubble"
            case .absorb: "git-bubble-absorb"
            case .stack: "git-stack-bubble"
            case .setup: "bubble-flow-setup"
            }
        }

        /// The bare subcommand, or the git-facing name without its `git-`.
        static func named(_ name: String) -> Command? {
            if let direct = Command(rawValue: name) { return direct }
            return allCases.first { $0.shimName == "git-\(name)" }
        }

        static func forShim(_ basename: String) -> Command? {
            allCases.first { $0.shimName == basename }
        }
    }

    static func basename(_ path: String) -> String {
        var name = String(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? "")
        if name.hasSuffix(".exe") { name = String(name.dropLast(4)) }
        return name
    }

    public static func run(
        argv: [String],
        git injectedGit: (any GitRunning)? = nil,
        console: any Console = StandardConsole()
    ) async -> Int32 {
        let argv0 = argv.first ?? "git-bubble-flow"
        var rest = Array(argv.dropFirst())

        let command: Command
        if let shimCommand = Command.forShim(basename(argv0)) {
            command = shimCommand
        } else {
            guard let first = rest.first else {
                printUsage(console: console)
                return 1
            }
            switch first {
            case "-h", "--help", "help":
                printUsage(console: console)
                return 0
            case "--version", "version":
                console.out("git-bubble-flow \(version)")
                return 0
            default:
                guard let resolved = Command.named(first) else {
                    console.err("FATAL: Unknown command: \(first)")
                    printUsage(console: console)
                    return 1
                }
                command = resolved
                rest = Array(rest.dropFirst())
            }
        }

        // Resolved only once a real command is selected, so --help and
        // --version still work on a machine without git.
        let git: any GitRunning
        if let injectedGit {
            git = injectedGit
        } else if let located = Git.locate() {
            git = located
        } else {
            console.err("FATAL: git not found on PATH.")
            console.err("Set GIT_BUBBLE_FLOW_GIT to its absolute path, or add git to PATH.")
            return 1
        }

        switch command {
        case .verify:
            return await VerifyBubble.run(arguments: rest, git: git, console: console)
        case .land:
            return await LandBubble.run(arguments: rest, git: git, console: console)
        case .rebase:
            return await RebaseBubble.run(arguments: rest, git: git, console: console)
        case .absorb:
            return await BubbleAbsorb.run(arguments: rest, git: git, console: console)
        case .stack:
            return await StackBubble.run(arguments: rest, git: git, console: console)
        case .setup:
            return await Setup.run(arguments: rest, git: git, console: console)
        }
    }

    static func printUsage(console: any Console) {
        console.out(
            """
            git-bubble-flow \(version) — ADR-009 semi-linear git-flow tooling

            A bubble is an empty merge commit whose second parent reaches one or
            more logical commits or nested bubbles.

            USAGE
              git-bubble-flow <command> [options]

            COMMANDS
              verify [<ref>] [--base <ref>] [--strict]
                  Check that every merge on the first-parent line is an empty bubble
                  (merge tree == second-parent tree), recursing into each bubble's
                  contents. --strict also fails on merge subjects that are not
                  'Merge <TICKET>: ...' and on non-merge commits sitting directly
                  on the verified range, outside any bubble.

              land [--target <branch>] [-m <summary>] [--strict]
                  Land the current branch into <branch> with --no-ff, after tagging
                  the target's pre-merge tip, then verify exactly the new bubble.
                  Never pushes, and never rebases for you. When another worktree
                  already holds <branch>, the merge happens there and you stay on
                  your own branch. The merge subject is 'Merge <TICKET>: ...' when
                  the branch name carries a ticket and 'Merge <branch>: ...' when
                  it does not. --strict requires the ticket, matching what
                  verify --strict expects of the subject.

              rebase [--bubble <branch>] [--onto <base>]
                  Move a bubble branch (default: the current one) with
                  --rebase-merges --update-refs and rerere, tagging first and
                  verifying afterwards.

              absorb [--base <ref>] [<git-absorb args>...]
                  Run git-absorb down to the merge-base of HEAD and the
                  configured base.

              stack init <name> --umbrella <branch> [--base <branch>]
                    [--remote <remote>] [--pending <branch>]...
                  Publish refs/stack/<name>, the shared record of an umbrella
                  branch whose first-parent line is its base followed only by
                  bubbles, each landed from a sub-branch.

              stack show [--stack <name>]
                  Fetch and print the stack's manifest.

              stack restack [--stack <name>] [--from <bubble>] [--keep-base]
              stack restack --continue | --abort | --break-lock
                  Take the stack's lock, rebuild the umbrella one bubble at a
                  time onto its base in a worktree of its own, then publish
                  every moved branch and the manifest in one atomic push with
                  explicit leases. Stops on a conflict for --continue. --from
                  takes commits added to a sub-branch since it landed.

              stack sync [--stack <name>] [--dry-run] [<branch>...]
                  Bring local branches onto the stack as last published:
                  stack branches follow the remote, and a branch built on a
                  commit a restack rewrote is replayed onto its new
                  equivalent. Never pushes.

              stack route [--stack <name>] [--to <bubble>] [-m <message>]
                    [--dry-run] [--no-restack]
                  Send each hunk staged on the umbrella to the bubble whose
                  lines it changes, fold it in with bubble-absorb, then
                  restack from the earliest bubble touched.

              stack new <branch> [--stack <name>]
                  Start a branch at the umbrella's tip and publish it as
                  pending in the manifest.

              setup [--base <branch>]
                  Write the bubbleflow.* config keys and the 'git land' alias
                  into the current repository. The base defaults to the branch
                  HEAD is on; no branch name is built in. The other
                  commands need no alias: git finds their symlinks on PATH.

            Each command is also reachable through a symlink named for its git
            subcommand (git-verify-bubble, git-land-bubble, git-rebase-bubble,
            git-bubble-absorb, git-stack-bubble, bubble-flow-setup).
            """)
    }
}
