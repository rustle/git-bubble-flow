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

/// The shared record of one stack: its base, its umbrella, the bubbles in
/// order, and what the last restack rewrote.
///
/// It lives in the *message* of a commit on `refs/stack/<name>`, whose tree is
/// empty. A message can be written with `git commit-tree -m` and read back with
/// `git log`, so no file or stdin ever has to be fed to git, and the format is
/// plain lines rather than JSON so it parses without Foundation. Each update is
/// a child of the previous manifest commit, which makes the ref's history the
/// history of every generation.
public struct StackManifest: Equatable, Sendable {
    public static let formatVersion = 1

    public struct Bubble: Equatable, Sendable {
        /// The bubble's merge commit on the umbrella, as of this generation.
        public var merge: String
        /// The label from its `Merge <LABEL>: ...` subject.
        public var label: String
        /// The sub-branch the bubble was landed from, when one is tracked.
        public var branch: String?

        public init(merge: String, label: String, branch: String?) {
            self.merge = merge
            self.label = label
            self.branch = branch
        }
    }

    public struct Lock: Equatable, Sendable {
        public var since: Int
        public var by: String

        public init(since: Int, by: String) {
            self.since = since
            self.by = by
        }
    }

    public struct Rewrite: Equatable, Sendable {
        public var old: String
        public var new: String

        public init(old: String, new: String) {
            self.old = old
            self.new = new
        }
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public var name: String
    public var remote: String
    /// The base branch's name on the remote, not a remote-tracking ref.
    public var base: String
    public var umbrella: String
    public var generation: Int
    public var bubbles: [Bubble]
    /// Unlanded branches built on the umbrella, rebased along with it.
    public var pending: [String]
    public var lock: Lock?
    /// Old→new commit pairs written by the restack that produced this
    /// generation. Empty for any other kind of update.
    public var rewrites: [Rewrite]
    /// Free-text lines recording why this update happened, such as a broken
    /// lock. Not carried into the next generation.
    public var notes: [String]

    public init(
        name: String,
        remote: String,
        base: String,
        umbrella: String,
        generation: Int = 0,
        bubbles: [Bubble] = [],
        pending: [String] = [],
        lock: Lock? = nil,
        rewrites: [Rewrite] = [],
        notes: [String] = []
    ) {
        self.name = name
        self.remote = remote
        self.base = base
        self.umbrella = umbrella
        self.generation = generation
        self.bubbles = bubbles
        self.pending = pending
        self.lock = lock
        self.rewrites = rewrites
        self.notes = notes
    }

    public static func ref(for name: String) -> String { "refs/stack/\(name)" }

    /// The commit message. The subject is for people reading `git log`; every
    /// field is in the body.
    public func encoded() -> String {
        var lines = ["stack \(name) generation \(generation)", ""]
        lines.append("format \(Self.formatVersion)")
        lines.append("remote \(remote)")
        lines.append("base \(base)")
        lines.append("umbrella \(umbrella)")
        lines.append("generation \(generation)")
        if let lock { lines.append("lock \(lock.since) \(lock.by)") }
        for bubble in bubbles {
            lines.append("bubble \(bubble.merge) \(bubble.label) \(bubble.branch ?? "-")")
        }
        for branch in pending { lines.append("pending \(branch)") }
        for rewrite in rewrites { lines.append("rewrite \(rewrite.old) \(rewrite.new)") }
        for note in notes { lines.append("note \(note)") }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func parse(_ text: String) throws(ParseError) -> StackManifest {
        func fail(_ message: String) -> ParseError { ParseError(description: message) }

        var name: String?
        var remote: String?
        var base: String?
        var umbrella: String?
        var generation: Int?
        var format: Int?
        var manifest = StackManifest(name: "", remote: "", base: "", umbrella: "")

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let subject = lines.first else { throw fail("the manifest is empty") }
        let subjectWords = subject.split(separator: " ")
        guard subjectWords.count >= 2, subjectWords[0] == "stack" else {
            throw fail("not a stack manifest: \(subject)")
        }
        name = String(subjectWords[1])

        for line in lines.dropFirst() where !line.trimmedWhitespace().isEmpty {
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let key = words.first else { continue }
            let values = Array(words.dropFirst())
            func one() throws(ParseError) -> String {
                guard values.count == 1 else { throw fail("malformed '\(key)' line: \(line)") }
                return values[0]
            }
            switch key {
            case "format":
                guard let value = Int(try one()) else { throw fail("malformed format: \(line)") }
                format = value
            case "remote": remote = try one()
            case "base": base = try one()
            case "umbrella": umbrella = try one()
            case "generation":
                guard let value = Int(try one()), value >= 0 else {
                    throw fail("malformed generation: \(line)")
                }
                generation = value
            case "lock":
                guard values.count >= 2, let since = Int(values[0]) else {
                    throw fail("malformed lock: \(line)")
                }
                manifest.lock = Lock(since: since, by: values.dropFirst().joined(separator: " "))
            case "bubble":
                guard values.count == 3 else { throw fail("malformed bubble: \(line)") }
                manifest.bubbles.append(
                    Bubble(merge: values[0], label: values[1], branch: values[2] == "-" ? nil : values[2]))
            case "pending":
                manifest.pending.append(try one())
            case "rewrite":
                guard values.count == 2 else { throw fail("malformed rewrite: \(line)") }
                manifest.rewrites.append(Rewrite(old: values[0], new: values[1]))
            case "note":
                // Free text: keep the original spacing after the key.
                manifest.notes.append(String(line.dropFirst("note ".count)))
            default:
                // A field added by a newer version. Ignored, so an older tool
                // can still read the parts it understands.
                continue
            }
        }

        guard let format else { throw fail("the manifest has no format line") }
        guard format <= formatVersion else {
            throw fail("manifest format \(format) is newer than this tool understands (\(formatVersion))")
        }
        guard let name, let remote, let base, let umbrella, let generation else {
            throw fail("the manifest is missing one of remote, base, umbrella or generation")
        }
        manifest.name = name
        manifest.remote = remote
        manifest.base = base
        manifest.umbrella = umbrella
        manifest.generation = generation
        return manifest
    }

    /// The bubble whose label or branch is `name`.
    public func bubbleIndex(named name: String) -> Int? {
        bubbles.firstIndex { $0.label == name || $0.branch == name }
    }
}
