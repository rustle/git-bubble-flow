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

@Suite("Alias quoting")
struct SetupTests {
    @Test("a plain path is left alone")
    func plain() {
        #expect(Setup.shellQuote("/usr/local/bin/git-bubble-flow") == "/usr/local/bin/git-bubble-flow")
    }

    @Test("a path with spaces survives the shell git runs aliases through")
    func spaces() {
        #expect(
            Setup.shellQuote("/Users/a b/bin/git-bubble-flow") == "'/Users/a b/bin/git-bubble-flow'")
    }
}

@Suite("C string decoding")
struct CStringTests {
    @Test("a sized buffer decodes every byte it holds")
    func decodesExactBytes() {
        let buffer = Array("abc".utf8).map { CChar(bitPattern: $0) }
        #expect(String(decoding: buffer[...]) == "abc")
    }

    @Test("an empty buffer decodes to an empty string")
    func empty() {
        #expect(String(decoding: [CChar]()[...]) == "")
    }

    @Test("invalid UTF-8 is repaired rather than trapping")
    func invalidUTF8() {
        let buffer: [CChar] = [CChar(bitPattern: 0xFF), 0x61]
        #expect(String(decoding: buffer[...]) == "\u{FFFD}a")
    }

    @Test("a symlink target longer than the first buffer is read whole")
    func readLinkGrowsPastTruncation() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("readlink-\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // readlink only signals truncation by filling the buffer exactly, so
        // hit that boundary on the first and second doublings as well as a
        // target past them. macOS caps a target at its 1024-byte PATH_MAX.
        for length in [255, 256, 512, 1000] {
            let target = String(repeating: "x", count: length)
            let link = dir.appendingPathComponent("link-\(length)").path
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
            #expect(Sys.readLink(link) == target)
        }
        #expect(Sys.readLink(dir.appendingPathComponent("missing").path) == nil)
    }

    @Test("the executable path is sized from the system's answer")
    func executablePath() {
        let path = Sys.executablePath()
        #expect(path?.isEmpty == false)
        #expect(path?.hasPrefix("/") == true)
        #expect(path?.utf8.contains(0) == false)
        #expect(path?.utf8.last != 0)
    }

    @Test("a libc pointer decodes through strlen")
    func nulTerminatedPointer() {
        #expect(Sys.environment("PATH") != nil)
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
