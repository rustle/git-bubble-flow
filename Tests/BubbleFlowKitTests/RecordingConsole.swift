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

/// Collects both streams so tests can assert on what a command printed.
///
/// Synchronised through the same vendored lock as `StubGit`, so this is
/// `Sendable` without an `@unchecked` escape hatch.
final class RecordingConsole: Console {
    private struct Lines: Sendable {
        var out: [String] = []
        var err: [String] = []
    }

    private let lines = ManagedCriticalState(Lines())

    var stdout: [String] { lines.withCriticalRegion { $0.out } }
    var stderr: [String] { lines.withCriticalRegion { $0.err } }
    var combined: String { lines.withCriticalRegion { ($0.out + $0.err).joined(separator: "\n") } }

    func out(_ line: String) { lines.withCriticalRegion { $0.out.append(line) } }
    func err(_ line: String) { lines.withCriticalRegion { $0.err.append(line) } }
}
