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

/// Everything a stopped restack needs to pick up where it left off.
///
/// Stored the way the manifest is, as a commit message over the empty tree, on
/// the local-only ref `refs/stack-restack/<name>`. Each save is a child of the
/// previous one, so the ref's history is the restack's journal.
struct RestackState: Equatable {
    static let formatVersion = 1

    static func ref(for name: String) -> String { "refs/stack-restack/\(name)" }

    struct Bubble: Equatable {
        var oldMerge: String
        var oldFirstParent: String
        var oldSecondParent: String
        /// What gets replayed: the old second parent, or the sub-branch's tip
        /// when `--from` accepted commits added to it since it landed.
        var content: String
        var label: String
        var branch: String?
    }

    struct Pending: Equatable {
        var branch: String
        var tip: String
        /// The bubble it forks from, or nil when it forks from the old base.
        var forkIndex: Int?
    }

    struct Built: Equatable {
        var secondParent: String
        var merge: String
    }

    /// A branch's position before the restack, on the remote and locally.
    /// Nil where the branch does not exist.
    struct Tip: Equatable {
        var branch: String
        var remote: String?
        var local: String?
    }

    enum Stage: Equatable {
        /// Replaying bubble `index` onto its new previous merge.
        case rebase(Int)
        /// Running the gate on bubble `index`, already replayed.
        case gate(Int)
        /// Replaying pending branch `index` onto the new umbrella.
        case pending(Int)
        case publish
    }

    var name: String
    /// The manifest commit holding our lock, which publish leases against.
    var lockedManifest: String
    var worktree: String
    var oldBase: String
    var newBase: String
    var bubbles: [Bubble] = []
    var pending: [Pending] = []
    var tips: [Tip] = []
    var built: [Built] = []
    var rebuiltPending: [String] = []
    var stage: Stage

    func encoded() -> String {
        var lines = ["restack \(name)", ""]
        lines.append("format \(Self.formatVersion)")
        lines.append("manifest \(lockedManifest)")
        lines.append("worktree \(worktree)")
        lines.append("old-base \(oldBase)")
        lines.append("new-base \(newBase)")
        for bubble in bubbles {
            lines.append(
                "bubble \(bubble.oldMerge) \(bubble.oldFirstParent) \(bubble.oldSecondParent) "
                    + "\(bubble.content) \(bubble.label) \(bubble.branch ?? "-")")
        }
        for entry in pending {
            lines.append("pending \(entry.branch) \(entry.tip) \(entry.forkIndex.map(String.init) ?? "-")")
        }
        for tip in tips {
            lines.append("tip \(tip.branch) \(tip.remote ?? "-") \(tip.local ?? "-")")
        }
        for entry in built { lines.append("built \(entry.secondParent) \(entry.merge)") }
        for sha in rebuiltPending { lines.append("rebuilt-pending \(sha)") }
        switch stage {
        case .rebase(let index): lines.append("stage rebase \(index)")
        case .gate(let index): lines.append("stage gate \(index)")
        case .pending(let index): lines.append("stage pending \(index)")
        case .publish: lines.append("stage publish")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ text: String) throws(ParseError) -> RestackState {
        func fail(_ line: Substring) -> ParseError { ParseError(description: "malformed restack state: \(line)") }
        func optional(_ value: String) -> String? { value == "-" ? nil : value }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let subject = lines.first, subject.hasPrefix("restack ") else {
            throw ParseError(description: "not a restack state")
        }
        var state = RestackState(
            name: String(subject.dropFirst("restack ".count)), lockedManifest: "", worktree: "",
            oldBase: "", newBase: "", stage: .publish)
        var format: Int?
        var stage: Stage?

        for line in lines.dropFirst() where !line.trimmedWhitespace().isEmpty {
            let words = line.split(separator: " ").map(String.init)
            let values = Array(words.dropFirst())
            switch words[0] {
            case "format": format = values.first.flatMap { Int($0) }
            case "manifest" where values.count == 1: state.lockedManifest = values[0]
            // A path may contain spaces.
            case "worktree": state.worktree = String(line.dropFirst("worktree ".count))
            case "old-base" where values.count == 1: state.oldBase = values[0]
            case "new-base" where values.count == 1: state.newBase = values[0]
            case "bubble" where values.count == 6:
                state.bubbles.append(
                    Bubble(
                        oldMerge: values[0], oldFirstParent: values[1], oldSecondParent: values[2],
                        content: values[3], label: values[4], branch: optional(values[5])))
            case "pending" where values.count == 3:
                let forkIndex: Int?
                if values[2] == "-" {
                    forkIndex = nil
                } else if let index = Int(values[2]) {
                    forkIndex = index
                } else {
                    throw fail(line)
                }
                state.pending.append(Pending(branch: values[0], tip: values[1], forkIndex: forkIndex))
            case "tip" where values.count == 3:
                state.tips.append(Tip(branch: values[0], remote: optional(values[1]), local: optional(values[2])))
            case "built" where values.count == 2:
                state.built.append(Built(secondParent: values[0], merge: values[1]))
            case "rebuilt-pending" where values.count == 1:
                state.rebuiltPending.append(values[0])
            case "stage":
                switch (values.first, values.count == 2 ? Int(values[1]) : nil) {
                case ("rebase", let index?): stage = .rebase(index)
                case ("gate", let index?): stage = .gate(index)
                case ("pending", let index?): stage = .pending(index)
                case ("publish", nil) where values.count == 1: stage = .publish
                default: throw fail(line)
                }
            default:
                throw fail(line)
            }
        }
        guard format == formatVersion, let stage, !state.lockedManifest.isEmpty, !state.worktree.isEmpty,
            !state.oldBase.isEmpty, !state.newBase.isEmpty
        else {
            throw ParseError(description: "incomplete restack state")
        }
        state.stage = stage
        return state
    }
}
