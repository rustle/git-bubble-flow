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

@testable import BubbleFlowKit

/// A GitRunning that answers from a lookup table, so command logic can be
/// tested without a repository on disk.
///
/// Every mutable field lives in one `Sendable` struct behind a
/// `ManagedCriticalState`, so this type satisfies `Sendable` outright. Nothing
/// here is `@unchecked`: the only unsafety is inside the vendored lock, which
/// is upstream code that has been audited for it.
final class StubGit: GitRunning {
    private struct State: Sendable {
        /// Keyed by the joined argument list.
        var responses: [String: GitResult] = [:]
        var fallback = GitResult(status: 1, standardOutput: "", standardError: "")
        var captured: [[String]] = []
        var passedThrough: [[String]] = []
    }

    private let state = ManagedCriticalState(State())

    var fallback: GitResult {
        get { state.withCriticalRegion { $0.fallback } }
        set { state.withCriticalRegion { $0.fallback = newValue } }
    }

    var captured: [[String]] { state.withCriticalRegion { $0.captured } }
    var passedThrough: [[String]] { state.withCriticalRegion { $0.passedThrough } }

    func stub(_ arguments: [String], stdout: String = "", status: Int32 = 0) {
        state.withCriticalRegion {
            $0.responses[arguments.joined(separator: " ")] = GitResult(
                status: status, standardOutput: stdout, standardError: ""
            )
        }
    }

    func capture(_ arguments: [String], config: [String: String]) async -> GitResult {
        state.withCriticalRegion { state in
            state.captured.append(arguments)
            return state.responses[arguments.joined(separator: " ")] ?? state.fallback
        }
    }

    func passthrough(_ arguments: [String], config: [String: String]) async -> Int32 {
        state.withCriticalRegion { state in
            state.passedThrough.append(arguments)
            return state.responses[arguments.joined(separator: " ")]?.status ?? 0
        }
    }
}
