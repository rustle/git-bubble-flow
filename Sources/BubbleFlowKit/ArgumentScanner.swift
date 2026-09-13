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

/// A left-to-right argument scanner matching the `while [[ $# -gt 0 ]]` loops in
/// the shell scripts, including their exit codes. ArgumentParser would give
/// different diagnostics and a different exit status (64), which the conformance
/// suite checks against.
public struct ArgumentScanner {
    private let arguments: [String]
    private var index = 0

    public init(_ arguments: [String]) { self.arguments = arguments }

    public var isAtEnd: Bool { index >= arguments.count }
    public var peek: String? { isAtEnd ? nil : arguments[index] }
    /// Everything not yet consumed — used to forward the tail to `git absorb`.
    public var rest: [String] { Array(arguments[index...]) }

    public mutating func advance() { index += 1 }

    public mutating func take() -> String? {
        guard let value = peek else { return nil }
        index += 1
        return value
    }

    /// Consumes `--flag value`, returning nil when the value is missing.
    ///
    /// `allowLeadingDash` is false for flags whose value is a ref or branch,
    /// so `--base --strict` reports a missing value instead of silently eating
    /// the next flag. It stays true for free text such as a commit message.
    public mutating func takeValue(for flag: String, allowLeadingDash: Bool = false) -> String? {
        advance()
        guard let value = take() else { return nil }
        if !allowLeadingDash, value.hasPrefix("-") { return nil }
        return value
    }
}
