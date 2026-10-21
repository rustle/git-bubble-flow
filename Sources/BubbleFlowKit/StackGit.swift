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

/// The git operations the stack commands share: reading and writing manifest
/// commits, compare-and-swap pushes, and the small history queries restack is
/// built from.
struct StackGit {
    /// git knows the empty tree without it being in the object database, so a
    /// commit can point at it in any repository.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    let git: any GitRunning

    func sha(_ rev: String) async -> String? {
        let result = await git.capture(["rev-parse", "--quiet", "--verify", "\(rev)^{commit}"], config: [:])
        return result.succeeded && !result.value.isEmpty ? result.value : nil
    }

    func parents(of commit: String) async -> [String] {
        let result = await git.capture(["rev-list", "--parents", "-n", "1", commit], config: [:])
        return Array(result.value.split(separator: " ").dropFirst().map(String.init))
    }

    func isAncestor(_ ancestor: String, of descendant: String) async -> Bool {
        await git.succeeds("merge-base", "--is-ancestor", ancestor, descendant)
    }

    func mergeBase(_ a: String, _ b: String) async -> String? {
        let result = await git.capture(["merge-base", a, b], config: [:])
        return result.succeeded && !result.value.isEmpty ? result.value : nil
    }

    /// Oldest first.
    func firstParentChain(from base: String, to tip: String) async -> [String]? {
        let result = await git.capture(
            ["rev-list", "--first-parent", "--reverse", "\(base)..\(tip)"], config: [:])
        return result.succeeded ? result.lines : nil
    }

    func subject(of commit: String) async -> String {
        await git.capture(["log", "-1", "--format=%s", commit], config: [:]).value
    }

    func message(of commit: String) async -> String? {
        let result = await git.capture(["log", "-1", "--format=%B", commit], config: [:])
        return result.succeeded ? result.standardOutput : nil
    }

    /// Who is acting, as recorded in a lock or a note.
    func identity() async -> String {
        let email = await git.configValue("user.email", default: "")
        if !email.isEmpty { return email }
        let name = await git.configValue("user.name", default: "")
        return name.isEmpty ? "unknown" : name
    }

    /// A commit holding `message` over the empty tree.
    func recordCommit(message: String, parent: String?) async -> String? {
        var arguments = ["commit-tree", Self.emptyTree]
        if let parent { arguments += ["-p", parent] }
        arguments += ["-m", message]
        let result = await git.capture(arguments, config: [:])
        return result.succeeded && !result.value.isEmpty ? result.value : nil
    }

    func readManifest(at commit: String) async -> Result<StackManifest, StackManifest.ParseError> {
        guard let text = await message(of: commit) else {
            return .failure(StackManifest.ParseError(description: "could not read manifest commit \(commit)"))
        }
        do {
            return .success(try StackManifest.parse(text))
        } catch {
            return .failure(error)
        }
    }

    /// What the remote's manifest ref points at: `.some(nil)` when the remote
    /// has none, and nil when the remote could not be asked.
    func remoteManifest(remote: String, name: String) async -> String?? {
        let ref = StackManifest.ref(for: name)
        let result = await git.capture(["ls-remote", "--end-of-options", remote, ref], config: [:])
        guard result.succeeded else { return nil }
        let match = result.lines.first { $0.hasSuffix("\t\(ref)") }
        return .some(match.map { String($0.prefix { $0 != "\t" }) })
    }

    /// Mirrors the remote's manifest into the local ref of the same name.
    func fetchManifest(remote: String, name: String) async -> Bool {
        let ref = StackManifest.ref(for: name)
        return await git.capture(
            ["fetch", "--quiet", "--end-of-options", remote, "+\(ref):\(ref)"], config: [:]
        ).succeeded
    }

    struct Update {
        var ref: String
        var new: String
        /// What the remote must still hold: a sha, or nil for "must not exist".
        var expected: String?
    }

    /// One atomic push with an explicit lease per ref. Either every ref moves or
    /// none does, and none moves if the remote no longer holds what was read.
    func push(remote: String, updates: [Update]) async -> GitResult {
        var arguments = ["push", "--atomic", "--porcelain"]
        for update in updates {
            arguments.append("--force-with-lease=\(update.ref):\(update.expected ?? "")")
        }
        arguments += ["--end-of-options", remote]
        arguments += updates.map { "\($0.new):\($0.ref)" }
        return await git.capture(arguments, config: [:])
    }

    /// The absolute directory shared by every worktree of the repository.
    func commonDirectory() async -> String? {
        let result = await git.capture(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], config: [:])
        return result.succeeded && !result.value.isEmpty ? result.value : nil
    }

    /// True while a rebase is stopped in the worktree at `path`.
    func rebaseInProgress(worktree path: String) async -> Bool {
        let gitDir = await WorktreeGit(path: path, git: git).capture(
            ["rev-parse", "--absolute-git-dir"], config: [:])
        guard gitDir.succeeded else { return false }
        return Sys.pathExists("\(gitDir.value)/rebase-merge") || Sys.pathExists("\(gitDir.value)/rebase-apply")
    }

    /// The label a bubble's subject carries, as `land` writes it.
    static func label(fromSubject subject: String) -> String? {
        guard let match = subject.firstMatch(of: /^Merge ([^:\s]+):/) else { return nil }
        return String(match.1)
    }
}
