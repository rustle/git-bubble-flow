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

extension StringProtocol {
    /// Foundation's `trimmingCharacters(in: .whitespacesAndNewlines)`, using the
    /// stdlib's Unicode-aware whitespace definition.
    ///
    /// The stdlib offers `trimmingPrefix(while:)` (SE-0357) but no suffix
    /// counterpart, so this is the shape swift-nio and swift-foundation use:
    /// locate the first and last kept characters and return that one slice,
    /// rather than shaving an end at a time. No copy is made. Callers that
    /// need a `String` wrap the result.
    func trimmedWhitespace() -> SubSequence {
        guard let start = firstIndex(where: { !$0.isWhitespace }) else { return self[endIndex...] }
        // `start` exists, so a last non-whitespace character does too.
        let end = index(after: lastIndex(where: { !$0.isWhitespace })!)
        return self[start..<end]
    }

    /// Zero-pads a non-negative integer, replacing `String(format: "%0Nd")`.
    static func padded(_ value: Int, width: Int) -> String {
        var digits = String(value)
        while digits.count < width { digits = "0" + digits }
        return digits
    }
}
