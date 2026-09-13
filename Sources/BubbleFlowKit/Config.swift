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

/// The `bubbleflow.*` keys. No branch name is built in: a base or target that
/// is not configured and not passed on the command line is an error at the
/// call site, never a guess.
public struct BubbleFlowConfig {
    /// Matches what a repo that never ran `setup` gets, and what `--strict`
    /// checks against, so the two never disagree.
    public static let defaultTicketPattern = "[A-Z]+-[0-9]+"

    private let git: any GitRunning

    public init(git: any GitRunning) { self.git = git }

    /// `git config` happily stores an empty value. Treating one as configured
    /// yields an empty ticket pattern or branch name, which downstream turns
    /// into a malformed merge subject rather than an error.
    private func value(_ key: String) async -> String? {
        let configured = await git.configValue(key, default: "")
        return configured.trimmedWhitespace().isEmpty ? nil : configured
    }

    /// Rejects a ref or branch name that git would parse as an option.
    ///
    /// `git check-ref-format` accepts names beginning with "-", a hostile
    /// repository can serve them, and `git clone` creates them verbatim. Since
    /// git parses options after positionals, such a name in an argument
    /// position becomes an option, and `git fetch <remote> --upload-pack=<path>`
    /// executes <path>. Nothing here ever needs such a name, so it is refused at
    /// the boundary rather than escaped at each of a dozen call sites.
    public static func refComplaint(about value: String, describedAs what: String) -> String? {
        if value.isEmpty { return "\(what) is empty" }
        if value.hasPrefix("-") { return "\(what) must not begin with '-': \(value)" }
        return nil
    }

    /// Rejects an anchored pattern, which the two consumers cannot agree on.
    ///
    /// `verify --strict` embeds the pattern in `^Merge (?:<pattern>):`, while
    /// `land` searches for it anywhere inside a branch name. A leading `^` or
    /// trailing `$` therefore makes one of them match nothing at all, silently.
    /// Only the two realistic spellings are rejected, so a `$` inside a
    /// character class still works.
    public static func anchorComplaint(about pattern: String) -> String? {
        guard pattern.hasPrefix("^") || pattern.hasSuffix("$") else { return nil }
        return "bubbleflow.ticketPattern must not be anchored: \(pattern)"
    }

    public func ticketPattern() async -> String {
        await value("bubbleflow.ticketPattern") ?? Self.defaultTicketPattern
    }

    /// The branch bubbles are verified against, rebased onto, and absorbed
    /// down to. Nil when `bubbleflow.base` is unset.
    public func base() async -> String? {
        await value("bubbleflow.base")
    }

    /// `bubbleflow.targets` is a space-separated list. Land uses the first.
    /// Nil when unset.
    public func defaultLandTarget() async -> String? {
        guard let targets = await value("bubbleflow.targets") else { return nil }
        return targets.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init)
    }
}
