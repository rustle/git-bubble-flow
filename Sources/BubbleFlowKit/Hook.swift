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

#if canImport(System)
import System
#else
import SystemPackage
#endif

/// Runs a repository-configured command, such as `stack.preflight`, through the
/// shell with the parent's stdio, and returns its exit status.
public typealias HookRunner =
    @Sendable (_ command: String, _ directory: String, _ environment: [String: String]) async -> Int32

public enum Hook {
    /// The command is the repository's own configuration, run in its own
    /// checkout, the same trust git extends to an alias beginning with `!`.
    public static let shell: HookRunner = { command, directory, environment in
        // Resolved against PATH for the same reason git is: a bare name would
        // resolve against the repository being worked in.
        guard let sh = Git.resolve(program: "sh", path: Sys.environment("PATH") ?? "") else { return 127 }
        var overrides: [Environment.Key: String?] = [:]
        for (key, value) in environment { overrides[Environment.Key(stringLiteral: key)] = value }
        do {
            let result = try await Subprocess.run(
                .path(FilePath(sh)),
                arguments: ["-c", command],
                environment: .inherit.updating(overrides),
                workingDirectory: FilePath(directory),
                input: .currentStandardInput,
                output: .currentStandardOutput,
                error: .currentStandardError
            )
            switch result.terminationStatus {
            case .exited(let code): return code
            #if !os(Windows)
            case .signaled(let signal): return 128 + signal
            #endif
            }
        } catch {
            return 127
        }
    }
}
