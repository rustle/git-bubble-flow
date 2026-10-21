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

import Foundation
import Testing

@testable import BubbleFlowKit

@Suite("Backup tag timestamps")
struct TimestampTests {
    @Test("matches `date +%Y%m%d-%H%M%S`")
    func format() {
        #expect(backupTimestamp(1_700_000_000, utc: true) == "20231114-221320")
    }

    @Test("pads every field to a fixed width")
    func padding() {
        // 2001-02-03 04:05:06 UTC
        #expect(backupTimestamp(981_173_106, utc: true) == "20010203-040506")
    }
}

@Suite("Multi-call dispatch")
struct MultiCallTests {
    @Test("each shim name selects its command", arguments: CLI.Command.allCases)
    func shimRoundTrip(command: CLI.Command) {
        #expect(CLI.Command.forShim(command.shimName) == command)
    }

    @Test("a .exe suffix is stripped before matching")
    func windowsBasename() {
        #expect(CLI.basename("C:/tools/git-land-bubble.exe") == "git-land-bubble")
    }

    @Test("subcommand aliases resolve")
    func aliases() {
        #expect(CLI.Command.named("verify-bubble") == .verify)
        #expect(CLI.Command.named("rebase-bubble") == .rebase)
        #expect(CLI.Command.named("bubble-absorb") == .absorb)
        #expect(CLI.Command.named("land-bubble") == .land)
        #expect(CLI.Command.named("nonsense") == nil)
    }
}

@Suite("verify-bubble argument parsing")
struct VerifyParsingTests {
    @Test("defaults to HEAD with no base override")
    func defaults() throws {
        let options = try #require(VerifyBubble.parse([], console: RecordingConsole()))
        #expect(options.ref == "HEAD")
        #expect(options.base == nil)
        #expect(options.strict == false)
    }

    @Test("a second positional ref is an error, not a silent overwrite")
    func multipleRefs() {
        let console = RecordingConsole()
        #expect(VerifyBubble.parse(["a", "b"], console: console) == nil)
        #expect(console.combined.contains("Multiple refs given ('a', 'b')"))
    }

    @Test("unknown options are rejected with the usage line")
    func unknownOption() {
        let console = RecordingConsole()
        #expect(VerifyBubble.parse(["--nope"], console: console) == nil)
        #expect(console.combined.contains("FATAL: Unknown option: --nope"))
        #expect(console.combined.contains(VerifyBubble.usage))
    }
}

@Suite("Configuration")
struct ConfigTests {
    @Test("bubbleflow.targets contributes only its first word")
    func firstTarget() async {
        let git = StubGit()
        git.stub(
            ["config", "--default", "", "--get", "bubbleflow.targets"],
            stdout: "release next trunk\n")
        #expect(await BubbleFlowConfig(git: git).defaultLandTarget() == "release")
    }

    @Test("no branch name is built in: an unset base or target is nil")
    func noBuiltInBranch() async {
        let git = StubGit()
        git.fallback = GitResult(status: 1, standardOutput: "", standardError: "")
        let config = BubbleFlowConfig(git: git)
        #expect(await config.base() == nil)
        #expect(await config.defaultLandTarget() == nil)
        #expect(await config.ticketPattern() == BubbleFlowConfig.defaultTicketPattern)
    }

    @Test("a blank configured value reads as unset")
    func blankValue() async {
        let git = StubGit()
        git.stub(["config", "--default", "", "--get", "bubbleflow.base"], stdout: "  \n")
        #expect(await BubbleFlowConfig(git: git).base() == nil)
    }
}

@Suite("Rebase base resolution")
struct BaseResolutionTests {
    @Test("a remote-tracking base is used as-is and split into remote + branch")
    func remoteTracking() async throws {
        let git = StubGit()
        git.stub(["rev-parse", "--quiet", "--verify", "refs/remotes/origin/main"])
        git.stub(["remote"], stdout: "origin\n")
        let resolved = try #require(await RebaseBubble.resolveBase("origin/main", git: git))
        #expect(resolved.remote == "origin")
        #expect(resolved.remoteBranch == "main")
        #expect(resolved.rebaseTarget == "origin/main")
    }

    @Test("a branch name containing a slash keeps its slashes")
    func branchWithSlash() async throws {
        let git = StubGit()
        git.stub(["rev-parse", "--quiet", "--verify", "refs/remotes/origin/feature/x"])
        git.stub(["remote"], stdout: "origin\n")
        let resolved = try #require(await RebaseBubble.resolveBase("origin/feature/x", git: git))
        #expect(resolved.remote == "origin")
        #expect(resolved.remoteBranch == "feature/x")
    }

    @Test("a remote whose own name contains a slash is split correctly")
    func remoteWithSlash() async throws {
        // Splitting at the first slash would have called the remote "team".
        let git = StubGit()
        git.stub(["rev-parse", "--quiet", "--verify", "refs/remotes/team/fork/main"])
        git.stub(["remote"], stdout: "origin\nteam/fork\n")
        let resolved = try #require(await RebaseBubble.resolveBase("team/fork/main", git: git))
        #expect(resolved.remote == "team/fork")
        #expect(resolved.remoteBranch == "main")
    }

    @Test("a local branch prefers its remote-tracking ref")
    func prefersRemote() async throws {
        let git = StubGit()
        git.stub(["rev-parse", "--quiet", "--verify", "refs/remotes/origin/staging"])
        let resolved = try #require(await RebaseBubble.resolveBase("staging", git: git))
        #expect(resolved.remote == "origin")
        #expect(resolved.rebaseTarget == "origin/staging")
    }

    @Test("a purely local base is not fetched")
    func localOnly() async throws {
        let git = StubGit()
        git.stub(["rev-parse", "--quiet", "--verify", "my-bubble"])
        let resolved = try #require(await RebaseBubble.resolveBase("my-bubble", git: git))
        #expect(resolved.remote == nil)
        #expect(resolved.rebaseTarget == "my-bubble")
    }

    @Test("an unknown base resolves to nothing")
    func unknown() async {
        #expect(await RebaseBubble.resolveBase("ghost", git: StubGit()) == nil)
    }
}

@Suite("Setup")
struct SetupTests {
    /// A directory holding executables with the given names, for the PATH the
    /// shim check reads.
    private func makeShims(_ names: [String]) throws -> String {
        let directory = "/tmp/bf-setup-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for name in names {
            let path = "\(directory)/\(name)"
            try "#!/bin/sh\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        return directory
    }

    /// StubGit answers status 1 by default, so any key left out of `configured`
    /// reads as unset and setup takes its first-run path for it.
    private func runSetup(
        _ arguments: [String] = [],
        head: String = "main",
        configured: [String: String] = [:],
        searchPath: String = ""
    ) async -> (Int32, StubGit, RecordingConsole) {
        let git = StubGit()
        let console = RecordingConsole()
        git.stub(["rev-parse", "--git-dir"])
        git.stub(["symbolic-ref", "--short", "HEAD"], stdout: "\(head)\n")
        for (key, value) in configured {
            git.stub(["config", "--local", "--get", key], stdout: "\(value)\n")
        }
        let status = await Setup.run(
            arguments: arguments, git: git, console: console, searchPath: searchPath)
        return (status, git, console)
    }

    @Test("the only alias written is land, and it names a subcommand")
    func writesOneBareAlias() async throws {
        let directory = try makeShims(CLI.Command.allCases.map(\.shimName))
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (status, git, _) = await runSetup(searchPath: directory)

        #expect(status == 0)
        let aliasWrites = git.passedThrough.filter { $0.count >= 2 && $0[1].hasPrefix("alias.") }
        // A path here is what `brew upgrade` would invalidate, and the three
        // other commands are reached through git's own PATH discovery.
        #expect(aliasWrites == [["config", "alias.land", "land-bubble"]])
    }

    @Test("shims missing from PATH are a warning, not a refusal")
    func warnsWhenShimsAreMissing() async {
        let (status, git, console) = await runSetup(searchPath: "/nonexistent")

        #expect(status == 0)
        #expect(console.stderr.contains { $0.contains("git-land-bubble") })
        // The warning must not cost the user their configuration.
        #expect(git.passedThrough.contains(["config", "alias.land", "land-bubble"]))
    }

    @Test("an explicit --base overrides a configured base")
    func explicitBaseWins() async {
        // Keeping it would silently drop what the user typed, with nothing but
        // a "(kept, already set)" line to say so.
        let (status, git, _) = await runSetup(
            ["--base", "develop"],
            head: "some-feature",
            configured: ["bubbleflow.base": "main", "bubbleflow.targets": "main"])

        #expect(status == 0)
        #expect(git.passedThrough.contains(["config", "bubbleflow.base", "develop"]))
        // targets has to move with it. land reads targets while verify and
        // rebase read base, so moving one alone leaves land merging into main.
        #expect(git.passedThrough.contains(["config", "bubbleflow.targets", "develop"]))
    }

    @Test("without --base a configured base is kept, and the examples quote it")
    func keptBaseIsQuoted() async {
        let (status, git, console) = await runSetup(
            head: "some-feature",
            configured: ["bubbleflow.base": "main", "bubbleflow.targets": "main"])

        #expect(status == 0)
        #expect(!git.passedThrough.contains { $0.count > 1 && $0[1] == "bubbleflow.base" })
        // The closing examples used to interpolate the branch HEAD is on, so
        // they contradicted the configuration printed a few lines above.
        #expect(console.stdout.contains("git rebase-bubble --onto origin/main"))
        #expect(!console.stdout.contains { $0.contains("some-feature") })
    }

    @Test("a custom ticket pattern still survives a re-run")
    func customPatternKept() async {
        let (status, git, _) = await runSetup(
            configured: ["bubbleflow.ticketPattern": "CUSTOM-[0-9]+"])

        #expect(status == 0)
        #expect(!git.passedThrough.contains { $0.count > 1 && $0[1] == "bubbleflow.ticketPattern" })
    }

    @Test("a PATH holding every shim warns about nothing")
    func silentWhenShimsResolve() async throws {
        let directory = try makeShims(CLI.Command.allCases.map(\.shimName))
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (status, _, console) = await runSetup(searchPath: directory)

        #expect(status == 0)
        #expect(console.stderr.isEmpty)
    }
}

@Suite("C string decoding")
struct CStringTests {
    @Test("a libc pointer decodes through strlen")
    func nulTerminatedPointer() {
        // getenv is the only remaining source of such a pointer. Multi-byte
        // content exercises the decode rather than just the lookup.
        let name = "BF_DECODE_PROBE_\(UUID().uuidString.prefix(8))"
        setenv(name, "héllo wörld/ünicode", 1)
        defer { unsetenv(name) }
        #expect(Sys.environment(name) == "héllo wörld/ünicode")
    }

    @Test("an absent variable is nil rather than empty")
    func missingVariable() {
        #expect(Sys.environment("BF_DECODE_PROBE_DEFINITELY_UNSET") == nil)
    }

    @Test("a variable set to the empty string decodes to an empty string")
    func emptyVariable() {
        let name = "BF_DECODE_EMPTY_\(UUID().uuidString.prefix(8))"
        setenv(name, "", 1)
        defer { unsetenv(name) }
        #expect(Sys.environment(name) == "")
    }
}

@Suite("PATH resolution")
struct ResolveTests {
    /// Builds a directory holding an executable of the given name.
    private func makeExecutable(named name: String) throws -> (directory: String, path: String) {
        let directory = "/tmp/bf-resolve-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = "\(directory)/\(name)"
        try "#!/bin/sh\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return (directory, path)
    }

    @Test("an absolute program name is accepted when it is executable")
    func absolutePath() throws {
        let made = try makeExecutable(named: "pretend-git")
        defer { try? FileManager.default.removeItem(atPath: made.directory) }
        #expect(Git.resolve(program: made.path, path: "/nowhere") == made.path)
    }

    @Test("an absolute program name that does not exist resolves to nothing")
    func absolutePathMissing() {
        #expect(Git.resolve(program: "/nonexistent/git", path: "/usr/bin") == nil)
    }

    @Test("a bare name is found on an absolute PATH entry")
    func onPath() throws {
        let made = try makeExecutable(named: "pretend-git")
        defer { try? FileManager.default.removeItem(atPath: made.directory) }
        #expect(Git.resolve(program: "pretend-git", path: made.directory) == made.path)
    }

    @Test("an unresolvable name yields nil rather than the bare name")
    func failsClosed() {
        // Returning "git" here would reach posix_spawn as a relative path and
        // execute a `git` sitting in the current directory.
        #expect(Git.resolve(program: "definitely-not-on-path-xyz", path: "/usr/bin:/bin") == nil)
    }

    @Test("relative PATH entries are never searched")
    func skipsRelativePathEntries() throws {
        let made = try makeExecutable(named: "pretend-git")
        defer { try? FileManager.default.removeItem(atPath: made.directory) }
        // A relative entry would make the process's current directory a search
        // path, so a committed binary in a cloned repo could win.
        let relative = String(made.directory.dropFirst())
        #expect(Git.resolve(program: "pretend-git", path: relative) == nil)
        #expect(Git.resolve(program: "pretend-git", path: "bin:.:..") == nil)
    }

    @Test("an empty PATH resolves nothing")
    func emptyPath() {
        #expect(Git.resolve(program: "git", path: "") == nil)
    }

    @Test("absolute-path detection")
    func absoluteDetection() {
        #expect(Git.isAbsolute("/usr/bin"))
        #expect(Git.isAbsolute("bin") == false)
        #expect(Git.isAbsolute(".") == false)
        #expect(Git.isAbsolute("") == false)
    }
}

@Suite("Worktree listing")
struct WorktreeTests {
    /// The shape `git worktree list --porcelain` emits, one record per entry.
    private let porcelain = """
        worktree /repo/main
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/develop

        worktree /repo/with space/feature
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/PROJ-100-feature

        worktree /repo/detached
        HEAD 3333333333333333333333333333333333333333
        detached

        worktree /repo/bare
        bare

        worktree /repo/locked
        HEAD 4444444444444444444444444444444444444444
        branch refs/heads/PROJ-102-locked
        locked on removable media

        worktree /repo/gone
        HEAD 5555555555555555555555555555555555555555
        branch refs/heads/PROJ-103-gone
        prunable gitdir file points to non-existent location

        """

    @Test("every entry and attribute is read back")
    func parsesAllEntries() {
        let worktrees = Worktree.parse(porcelain, separator: "\n")
        #expect(worktrees.count == 6)
        #expect(worktrees[0].branch == "refs/heads/develop")
        // A path may contain spaces, so only the first space separates the key.
        #expect(worktrees[1].path == "/repo/with space/feature")
        #expect(worktrees[2].isDetached)
        #expect(worktrees[2].branch == nil)
        #expect(worktrees[3].isBare)
        #expect(worktrees[4].lockedReason == "on removable media")
        #expect(worktrees[5].isPrunable)
        #expect(worktrees[0].isLocked == false)
        #expect(worktrees[0].isPrunable == false)
    }

    @Test("the NUL-separated form parses identically")
    func parsesZeroTerminated() {
        // `-z` is what list() asks for first, because the line-based form cannot
        // represent a path containing a newline.
        let zeroTerminated = porcelain.replacing("\n", with: "\0")
        #expect(
            Worktree.parse(zeroTerminated, separator: "\0") == Worktree.parse(porcelain, separator: "\n"))
    }

    @Test("a path containing a newline survives the NUL form")
    func newlineInPath() {
        let worktrees = Worktree.parse(
            "worktree /repo/two\nlines\0HEAD 1111111\0branch refs/heads/x\0\0", separator: "\0")
        #expect(worktrees.count == 1)
        #expect(worktrees[0].path == "/repo/two\nlines")
    }

    @Test("an attribute from a newer git is ignored rather than fatal")
    func unknownAttribute() {
        let worktrees = Worktree.parse(
            "worktree /repo/main\nbranch refs/heads/develop\nsomething-new value\n\n", separator: "\n")
        #expect(worktrees.count == 1)
        #expect(worktrees[0].branch == "refs/heads/develop")
    }

    @Test("a trailing record with no blank line after it is still returned")
    func unterminatedRecord() {
        let worktrees = Worktree.parse(
            "worktree /repo/main\nbranch refs/heads/develop", separator: "\n")
        #expect(worktrees.count == 1)
    }

    @Test("empty output is no worktrees, not one empty one")
    func emptyOutput() {
        #expect(Worktree.parse("", separator: "\n").isEmpty)
    }
}

@Suite("Worktree redirection")
struct WorktreeGitTests {
    @Test("every command names the worktree's own git dir and work tree")
    func redirectsBothStreams() async {
        let stub = StubGit()
        let redirected = WorktreeGit(path: "/repo/feature", git: stub)

        _ = await redirected.capture(["rev-parse", "HEAD"], config: [:])
        _ = await redirected.passthrough(["merge", "--no-ff"], config: [:])

        // -C alone would be silently wrong: git exports GIT_DIR to `!` aliases,
        // which is how `git land` runs, and the inherited value beats -C. The
        // explicit overrides are what make the redirect hold.
        let expectedPrefix = [
            "-C", "/repo/feature", "--git-dir=/repo/feature/.git", "--work-tree=/repo/feature",
        ]
        #expect(stub.captured.first == expectedPrefix + ["rev-parse", "HEAD"])
        #expect(stub.passedThrough.first == expectedPrefix + ["merge", "--no-ff"])
    }

    @Test("config overrides still reach git alongside the redirect")
    func keepsConfigOverrides() async {
        let stub = StubGit()
        let redirected = WorktreeGit(path: "/repo/feature", git: stub)
        _ = await redirected.capture(["status"], config: ["core.hooksPath": "/dev/null"])
        // The runner assembles `-c` overrides itself, so the redirect must not
        // swallow them.
        #expect(stub.captured.first?.last == "status")
    }
}

@Suite("Git output limit")
struct GitOutputLimitTests {
    private struct SpawnFailure: Error {}

    @Test("a git that will not run is still 127")
    func spawnFailureKeepsItsStatus() {
        // The limit case took a new status. This one must not move with it,
        // because callers already read 127 as "git is not usable here".
        #expect(Git.status(for: SpawnFailure()) == 127)
        #expect(Git.isOutputLimit(SpawnFailure()) == false)
    }

    @Test("a spawn failure reports the underlying error, not a limit message")
    func spawnFailureDiagnostic() {
        let text = Git.diagnostic(for: SpawnFailure(), arguments: ["rev-list"], limit: 64)
        #expect(text.contains("SpawnFailure"))
        #expect(text.contains("produced more than") == false)
    }

    @Test("output past the limit is distinguishable from a failure to spawn")
    func overLimitIsItsOwnStatus() async throws {
        // A real over-limit run rather than a synthesised error: SubprocessError
        // has no public initialiser, so the only honest way to produce one is to
        // run something that overflows. `--version` needs no repository.
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let executable = try #require(Git.resolve(program: "git", path: path))
        let tiny = Git(executable: executable, outputLimit: 4)
        let result = await tiny.capture(["--version"], config: [:])

        #expect(result.status == Git.outputLimitStatus)
        #expect(result.status != 127)
        #expect(result.succeeded == false)
        // The subcommand has to survive into the message: it is what tells the
        // reader which call flooded.
        #expect(result.standardError.contains("git --version"))
        #expect(result.standardError.contains("4 bytes"))
        #expect(result.standardOutput.isEmpty)
    }

    @Test("output inside the limit is unaffected")
    func underLimitStillWorks() async throws {
        let git = try #require(Git.locate(), "git must be on PATH for this test")
        let result = await git.capture(["--version"], config: [:])
        #expect(result.succeeded)
        #expect(result.value.hasPrefix("git version"))
    }
}

@Suite("Whitespace trimming")
struct TrimmingTests {
    @Test("both ends are trimmed and the middle is untouched")
    func bothEnds() {
        #expect(" \t a b \n".trimmedWhitespace() == "a b")
    }

    @Test("Unicode whitespace counts, as it does for Character.isWhitespace")
    func unicode() {
        #expect("\u{00A0}\u{2003}x\u{3000}".trimmedWhitespace() == "x")
    }

    @Test("an all-whitespace or empty string trims to empty")
    func empty() {
        #expect("   \n".trimmedWhitespace().isEmpty)
        #expect("".trimmedWhitespace().isEmpty)
    }

    @Test("a substring trims in place without copying to a String")
    func substring() {
        let line: Substring = "  value  \n"
        #expect(line.trimmedWhitespace() == "value")
    }
}

@Suite("Stack manifest")
struct StackManifestTests {
    static let sample = StackManifest(
        name: "engine", remote: "origin", base: "develop", umbrella: "feature/engine", generation: 3,
        bubbles: [
            .init(merge: String(repeating: "a", count: 40), label: "ABC-1", branch: "ABC-1-part"),
            .init(merge: String(repeating: "b", count: 40), label: "ABC-2", branch: nil),
        ],
        pending: ["ABC-9-wip"],
        lock: .init(since: 1_700_000_000, by: "Some One"),
        rewrites: [.init(old: String(repeating: "c", count: 40), new: String(repeating: "d", count: 40))],
        notes: ["restacked  by someone"])

    @Test("survives a round trip through its commit message")
    func roundTrip() throws {
        #expect(try StackManifest.parse(Self.sample.encoded()) == Self.sample)
    }

    @Test("the subject names the stack and generation")
    func subject() {
        #expect(Self.sample.encoded().hasPrefix("stack engine generation 3\n\n"))
    }

    @Test("fields added by a newer version are ignored")
    func unknownField() throws {
        let text = Self.sample.encoded() + "owner someone\n"
        #expect(try StackManifest.parse(text) == Self.sample)
    }

    @Test("a newer format is refused rather than misread")
    func newerFormat() {
        let text = Self.sample.encoded().replacingOccurrences(of: "format 1", with: "format 2")
        #expect(throws: StackManifest.ParseError.self) { try StackManifest.parse(text) }
    }

    @Test("a commit that is not a manifest is refused")
    func notAManifest() {
        #expect(throws: StackManifest.ParseError.self) { try StackManifest.parse("Merge ABC-1: thing\n") }
    }

    @Test("a missing required field is refused")
    func missingField() {
        let text = Self.sample.encoded().replacingOccurrences(of: "umbrella feature/engine\n", with: "")
        #expect(throws: StackManifest.ParseError.self) { try StackManifest.parse(text) }
    }
}

@Suite("Restack state")
struct RestackStateTests {
    @Test("survives a round trip, including a worktree path with spaces")
    func roundTrip() throws {
        var state = RestackState(
            name: "engine", lockedManifest: "1111", worktree: "/repo with space/.git/stack-bubble/engine",
            oldBase: "2222", newBase: "3333", stage: .gate(1))
        state.bubbles = [
            .init(
                oldMerge: "a", oldFirstParent: "b", oldSecondParent: "c", content: "c", label: "ABC-1",
                branch: "ABC-1-part"),
            .init(oldMerge: "d", oldFirstParent: "a", oldSecondParent: "e", content: "f", label: "ABC-2", branch: nil),
        ]
        state.pending = [.init(branch: "wip", tip: "g", forkIndex: 1), .init(branch: "early", tip: "h", forkIndex: nil)]
        state.tips = [.init(branch: "ABC-1-part", remote: "c", local: nil)]
        state.built = [.init(secondParent: "c2", merge: "a2")]
        state.rebuiltPending = []
        #expect(try RestackState.parse(state.encoded()) == state)
    }

    @Test("every stage round-trips", arguments: [
        RestackState.Stage.rebase(0), .gate(2), .pending(1), .publish,
    ])
    func stages(stage: RestackState.Stage) throws {
        let state = RestackState(
            name: "s", lockedManifest: "1", worktree: "/w", oldBase: "2", newBase: "3", stage: stage)
        #expect(try RestackState.parse(state.encoded()).stage == stage)
    }
}

@Suite("stack-bubble")
struct StackBubbleTests {
    @Test("labels come from land's subject format")
    func label() {
        #expect(StackGit.label(fromSubject: "Merge ABC-12: part two") == "ABC-12")
        #expect(StackGit.label(fromSubject: "Merge feature/x: thing") == "feature/x")
        #expect(StackGit.label(fromSubject: "Merge branch 'x' into y") == nil)
    }

    @Test("stack names must be one ref component")
    func names() {
        let console = RecordingConsole()
        #expect(StackBubble.validName("engine", console: console))
        #expect(!StackBubble.validName("a/b", console: console))
        #expect(!StackBubble.validName("--upload-pack=x", console: console))
    }

    @Test("restack's modes are mutually exclusive")
    func exclusiveModes() {
        let console = RecordingConsole()
        #expect(Restack.parse(["--continue", "--abort"], console: console) == nil)
        #expect(console.combined.contains("cannot be combined"))
    }

    @Test("--from only applies when starting")
    func fromOnStart() throws {
        #expect(Restack.parse(["--continue", "--from", "ABC-1"], console: RecordingConsole()) == nil)
        let options = try #require(Restack.parse(["--from", "ABC-1", "--keep-base"], console: RecordingConsole()))
        #expect(options.from == "ABC-1")
        #expect(options.keepBase)
        #expect(options.mode == .start)
    }

    @Test("an unknown subcommand is rejected with usage")
    func unknownSubcommand() async {
        let console = RecordingConsole()
        #expect(await StackBubble.run(arguments: ["nope"], git: StubGit(), console: console) == 1)
        #expect(console.combined.contains("Unknown stack-bubble command: nope"))
    }
}
