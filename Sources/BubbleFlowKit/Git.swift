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

import Subprocess

// FilePath comes from Apple's System on Darwin and from swift-system's
// SystemPackage elsewhere.
#if canImport(System)
import System
#else
import SystemPackage
#endif

public struct GitResult: Sendable {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String

    public init(status: Int32, standardOutput: String, standardError: String) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { status == 0 }

    /// stdout with one trailing newline stripped, matching `$(git ...)` in shell.
    public var value: String {
        standardOutput.hasSuffix("\n") ? String(standardOutput.dropLast()) : standardOutput
    }

    /// Non-empty lines of stdout, matching a `while read` loop over the output.
    public var lines: [String] {
        value.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

/// The seam that keeps a libgit2-backed implementation possible later: every
/// command talks to git only through this.
public protocol GitRunning: Sendable {
    /// Runs git with both streams captured.
    func capture(_ arguments: [String], config: [String: String]) async -> GitResult
    /// Runs git with the parent's stdio inherited, for commands that are
    /// interactive or whose progress output the user needs to see live.
    func passthrough(_ arguments: [String], config: [String: String]) async -> Int32
}

extension GitRunning {
    public func capture(_ arguments: String...) async -> GitResult {
        await capture(arguments, config: [:])
    }

    public func passthrough(_ arguments: String...) async -> Int32 {
        await passthrough(arguments, config: [:])
    }

    /// True when the command exits 0, like the shell's `if git ... >/dev/null`.
    public func succeeds(_ arguments: String...) async -> Bool {
        await capture(arguments, config: [:]).succeeded
    }

    /// `git rev-parse --quiet --verify <rev>` — does this rev resolve?
    public func revisionExists(_ rev: String) async -> Bool {
        await capture(["rev-parse", "--quiet", "--verify", rev], config: [:]).succeeded
    }

    /// `git config --default <fallback> --get <key>`
    public func configValue(_ key: String, default fallback: String) async -> String {
        let result = await capture(["config", "--default", fallback, "--get", key], config: [:])
        return result.succeeded ? result.value : fallback
    }
}

public struct Git: GitRunning {
    /// Subprocess throws when a stream exceeds its limit. git's plumbing output
    /// is small — a first-parent walk of a long bubble chain is a few hundred
    /// lines — so this is sized to be unreachable in practice rather than tuned.
    public static let defaultOutputLimit = 64 * 1024 * 1024

    /// Status for output past `outputLimit`. Deliberately not 127: that means
    /// "git would not run", and a git that ran and said too much is a different
    /// failure needing a different diagnosis. Deliberately not 128 either,
    /// which is git's own "fatal" and would be read as coming from git.
    public static let outputLimitStatus: Int32 = 125

    private let executable: String
    private let outputLimit: Int

    public init(executable: String, outputLimit: Int = Git.defaultOutputLimit) {
        self.executable = executable
        self.outputLimit = outputLimit
    }

    /// Finds git on PATH, or nil when it is not there. Callers must treat nil
    /// as fatal rather than falling back to a bare name.
    public static func locate(searchPath: String? = nil) -> Git? {
        let path = searchPath ?? Sys.environment("PATH") ?? ""
        let program = Sys.environment("GIT_BUBBLE_FLOW_GIT") ?? "git"
        guard let resolved = resolve(program: program, path: path) else { return nil }
        return Git(executable: resolved)
    }

    /// Resolves a program name against PATH, or nil when nothing matches.
    ///
    /// Returning nil rather than the bare name is load-bearing. A bare name
    /// reaches `posix_spawn` as a relative path, which resolves against the
    /// current directory — the repository the user is standing in — so a
    /// `git` committed to a hostile repository would run. For the same reason
    /// only absolute PATH entries are searched: `PATH=bin:/usr/bin` otherwise
    /// makes a committed `bin/git` win over the real one.
    static func resolve(program: String, path: String) -> String? {
        #if os(Windows)
        let looksLikeAPath = program.contains("/") || program.contains("\\")
        #else
        // A backslash is a legal character in a POSIX filename, not a separator.
        let looksLikeAPath = program.contains("/")
        #endif
        if looksLikeAPath {
            return Sys.isExecutableFile(program) ? program : nil
        }
        #if os(Windows)
        let separator: Character = ";"
        let suffixes = ["", ".exe", ".cmd", ".bat"]
        #else
        let separator: Character = ":"
        let suffixes = [""]
        #endif
        for directory in path.split(separator: separator, omittingEmptySubsequences: true) {
            guard isAbsolute(directory) else { continue }
            for suffix in suffixes {
                let candidate = "\(directory)/\(program)\(suffix)"
                if Sys.isExecutableFile(candidate) { return candidate }
            }
        }
        return nil
    }

    static func isAbsolute(_ path: some StringProtocol) -> Bool {
        #if os(Windows)
        if path.hasPrefix("\\\\") { return true }  // UNC
        var characters = path.makeIterator()
        guard let drive = characters.next(), drive.isLetter,
            characters.next() == ":"
        else { return false }
        let third = characters.next()
        return third == "\\" || third == "/"
        #else
        return path.hasPrefix("/")
        #endif
    }

    /// Sorted so a repeated run produces an identical command line.
    private func argumentList(_ arguments: [String], config: [String: String]) -> [String] {
        let overrides = config.sorted { $0.key < $1.key }.flatMap { ["-c", "\($0.key)=\($0.value)"] }
        return overrides + arguments
    }

    private static func exitCode(_ status: TerminationStatus) -> Int32 {
        switch status {
        case .exited(let code): return code
        #if !os(Windows)
        case .signaled(let signal): return 128 + signal  // the shell's convention
        #endif
        }
    }

    /// True when Subprocess gave up because a stream outgrew its limit, as
    /// opposed to failing to start git at all.
    static func isOutputLimit(_ error: some Error) -> Bool {
        (error as? SubprocessError)?.code == .outputLimitExceeded
    }

    /// Kept separate from `capture` so the mapping is testable without spawning.
    static func status(for error: some Error) -> Int32 {
        // 127 is the shell's "command not found", which is how the caller
        // already treats a git that will not run.
        isOutputLimit(error) ? outputLimitStatus : 127
    }

    static func diagnostic(for error: some Error, arguments: [String], limit: Int) -> String {
        guard isOutputLimit(error) else { return "\(error)" }
        // Name the subcommand: the caller prints this above its own FATAL line,
        // and "git rev-list" is the part that tells the reader where to look.
        let subcommand = arguments.first ?? "(none)"
        return """
            git \(subcommand) produced more than \(limit) bytes of output, \
            which is the most this tool will read.
            """
    }

    public func capture(_ arguments: [String], config: [String: String] = [:]) async -> GitResult {
        do {
            let result = try await Subprocess.run(
                .path(FilePath(executable)),
                arguments: Arguments(argumentList(arguments, config: config)),
                environment: .inherit,
                output: .string(limit: outputLimit),
                error: .string(limit: outputLimit)
            )
            return GitResult(
                status: Git.exitCode(result.terminationStatus),
                standardOutput: result.standardOutput,
                standardError: result.standardError
            )
        } catch {
            return GitResult(
                status: Git.status(for: error),
                standardOutput: "",
                standardError: Git.diagnostic(for: error, arguments: arguments, limit: outputLimit)
            )
        }
    }

    public func passthrough(_ arguments: [String], config: [String: String] = [:]) async -> Int32 {
        do {
            let result = try await Subprocess.run(
                .path(FilePath(executable)),
                arguments: Arguments(argumentList(arguments, config: config)),
                environment: .inherit,
                input: .currentStandardInput,
                output: .currentStandardOutput,
                error: .currentStandardError
            )
            return Git.exitCode(result.terminationStatus)
        } catch {
            return 127
        }
    }
}
