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

/// An editor would block a run with no terminal, and wait for nothing when
/// there is one: the autosquash todo and every message are used as they are.
private let noEditor = ["core.editor": "true", "sequence.editor": "true"]

/// Adds config to every git call, including the ones git-absorb makes itself:
/// git hands `-c` settings down to the commands it runs.
private struct ConfiguredGit: GitRunning {
    let git: any GitRunning
    let config: [String: String]

    func capture(_ arguments: [String], config extra: [String: String]) async -> GitResult {
        await git.capture(arguments, config: config.merging(extra) { $1 })
    }

    func passthrough(_ arguments: [String], config extra: [String: String]) async -> Int32 {
        await git.passthrough(arguments, config: config.merging(extra) { $1 })
    }
}

/// `git stack-bubble route`: sends fixes staged on the umbrella to the bubbles
/// whose lines they change.
///
/// Engineers test on the umbrella and fix what they find there, but a commit
/// on the umbrella is outside every bubble. Route blames each staged hunk to
/// the bubble that wrote those lines, folds it into that bubble's sub-branch
/// with `bubble-absorb`, and restacks from the earliest bubble it touched.
enum Route {
    struct Options: Equatable {
        var stack: String?
        var to: String?
        var message: String?
        var dryRun = false
        var restack = true
    }

    static func parse(_ arguments: [String], console: any Console) -> Options? {
        var options = Options()
        var scanner = ArgumentScanner(arguments)
        while let argument = scanner.peek {
            switch argument {
            case "--stack", "--to":
                guard let value = scanner.takeValue(for: argument) else {
                    console.err("ERROR: \(argument) requires a value")
                    return nil
                }
                if argument == "--stack" { options.stack = value } else { options.to = value }
            case "-m", "--message":
                guard let value = scanner.takeValue(for: argument, allowLeadingDash: true) else {
                    console.err("ERROR: \(argument) requires a value")
                    return nil
                }
                options.message = value
            case "--dry-run", "-n":
                options.dryRun = true
                scanner.advance()
            case "--no-restack":
                options.restack = false
                scanner.advance()
            case let other:
                console.err("Unknown argument: \(other)")
                return nil
            }
        }
        return options
    }

    // MARK: - The staged diff

    struct Hunk: Equatable {
        var oldStart: Int
        var oldCount: Int
        /// The `@@` line and the body, verbatim.
        var lines: [String]
    }

    struct FileDiff: Equatable {
        var path: String
        /// From `diff --git` up to the first hunk, verbatim.
        var header: [String]
        var hunks: [Hunk] = []
        var isNew = false
        var isBinary = false
    }

    /// Splits `git diff -U0` output into files and hunks.
    static func parseDiff(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        func finish() {
            if let current { files.append(current) }
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                finish()
                current = FileDiff(path: "", header: [line])
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("@@ "), let header = hunkHeader(line) {
                current!.hunks.append(Hunk(oldStart: header.start, oldCount: header.count, lines: [line]))
                continue
            }
            if let last = current!.hunks.indices.last {
                if line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix(" ") || line.hasPrefix("\\") {
                    current!.hunks[last].lines.append(line)
                }
                continue
            }
            current!.header.append(line)
            if line == "--- /dev/null" { current!.isNew = true }
            if line.hasPrefix("Binary files ") || line == "GIT binary patch" { current!.isBinary = true }
            if line.hasPrefix("+++ b/") {
                current!.path = trimmedPath(line.dropFirst("+++ b/".count))
            } else if line.hasPrefix("--- a/"), current!.path.isEmpty {
                current!.path = trimmedPath(line.dropFirst("--- a/".count))
            }
        }
        finish()
        return files
    }

    /// git appends a tab to a `---`/`+++` path containing a space.
    static func trimmedPath(_ path: Substring) -> String {
        String(path.hasSuffix("\t") ? path.dropLast() : path)
    }

    /// `@@ -start[,count] +... @@`
    static func hunkHeader(_ line: String) -> (start: Int, count: Int)? {
        guard let match = line.firstMatch(of: /^@@ -([0-9]+)(?:,([0-9]+))? \+/) else { return nil }
        guard let start = Int(match.1) else { return nil }
        let count = match.2.flatMap { Int($0) } ?? 1
        return (start, count)
    }

    /// A patch holding only `hunks` of `file`, in file order.
    ///
    /// Each hunk's new-side start is recomputed from the hunks kept before it:
    /// `apply --unidiff-zero` has no context to search by and places a hunk at
    /// that start, which in the full diff counts lines the dropped hunks added.
    static func patch(_ file: FileDiff, hunks: [Hunk]) -> [String] {
        var offset = 0
        var lines = file.header
        for hunk in hunks.sorted(by: { $0.oldStart < $1.oldStart }) {
            let added = hunk.lines.dropFirst().filter { $0.hasPrefix("+") }.count
            var newStart = hunk.oldStart + offset
            if hunk.oldCount == 0 { newStart += 1 }
            if added == 0 { newStart -= 1 }
            offset += added - hunk.oldCount
            lines.append(renumbered(hunk.lines[0], newStart: newStart))
            lines += hunk.lines.dropFirst()
        }
        return lines
    }

    /// `header` with the start of its `+start[,count]` range replaced.
    static func renumbered(_ header: String, newStart: Int) -> String {
        header.replacing(/^(@@ -[0-9,]+ \+)[0-9]+/) { "\($0.1)\(newStart)" }
    }

    // MARK: - run

    struct Bubble {
        var label: String
        var branch: String?
        var firstParent: String
        var secondParent: String
        var commits: Set<String>
    }

    static func run(
        arguments: [String], git: any GitRunning, console: any Console, hooks: @escaping HookRunner, now: Int
    ) async -> Int32 {
        guard let options = parse(arguments, console: console) else { return 1 }
        guard let name = await StackBubble.resolveName(options.stack, git: git, console: console) else { return 1 }
        func error(_ message: String) { console.err("ERROR: \(message)") }
        let stack = StackGit(git: git)

        if await stack.sha(RestackState.ref(for: name)) != nil {
            error("A restack of '\(name)' is in progress here. Finish or abort it first.")
            return 1
        }
        let remote = await StackBubble.remote(for: name, git: git)
        guard await git.passthrough(["fetch", "--quiet", "--end-of-options", remote], config: [:]) == 0 else {
            return 1
        }
        guard
            let (manifest, _) = await StackBubble.fetchManifest(name: name, remote: remote, git: git, console: console)
        else { return 1 }
        if let lock = manifest.lock {
            error("'\(name)' is being restacked by \(lock.by). Route once it is published.")
            return 1
        }

        let current = await git.capture(["symbolic-ref", "--quiet", "--short", "HEAD"], config: [:]).value
        guard current == manifest.umbrella else {
            error("Route works on fixes staged on the umbrella. Check out '\(manifest.umbrella)' first.")
            return 1
        }
        guard let umbrellaTip = await stack.sha("HEAD"),
            umbrellaTip == (await stack.sha("refs/remotes/\(remote)/\(manifest.umbrella)"))
        else {
            error("'\(manifest.umbrella)' differs from '\(remote)/\(manifest.umbrella)'. Sync it first.")
            return 1
        }
        guard let bubbles = await loadBubbles(manifest, remote: remote, tip: umbrellaTip, git: git, console: console)
        else { return 1 }

        let diff = await git.capture(
            ["-c", "core.quotePath=false", "diff", "--cached", "--no-renames", "--no-ext-diff", "--no-color", "-U0"],
            config: [:])
        let files = parseDiff(diff.standardOutput)
        guard diff.succeeded, !files.isEmpty else {
            error("Nothing is staged. Stage the fix with 'git add', then route it.")
            return 1
        }

        // Every hunk to one bubble, or a reason it cannot be placed.
        var forced: Int?
        if let to = options.to {
            guard let index = bubbles.firstIndex(where: { $0.label == to || $0.branch == to }) else {
                error("No bubble labelled or landed from '\(to)'.")
                return 1
            }
            forced = index
        }
        var routed: [Int: [(file: FileDiff, hunks: [Hunk])]] = [:]
        var unplaced: [String] = []
        for file in files {
            if let forced {
                routed[forced, default: []].append((file, file.hunks))
                continue
            }
            if file.isNew || file.isBinary || file.hunks.isEmpty {
                unplaced.append("\(file.path): \(file.isNew ? "a new file" : "no lines to blame")")
                continue
            }
            var byBubble: [Int: [Hunk]] = [:]
            for hunk in file.hunks {
                let lines = blameLines(for: hunk)
                let commits = await blame(file.path, lines: lines, at: umbrellaTip, git: git)
                let owners = Set(commits.map { commit in bubbles.firstIndex { $0.commits.contains(commit) } })
                let header = hunk.lines.first ?? ""
                if owners.contains(nil) || owners.isEmpty {
                    unplaced.append("\(file.path) \(header): lines from outside every bubble")
                } else if owners.count > 1 {
                    let labels = owners.compactMap { $0 }.sorted().map { bubbles[$0].label }
                    unplaced.append("\(file.path) \(header): spans \(labels.joined(separator: " and "))")
                } else if let owner = owners.first.flatMap({ $0 }) {
                    byBubble[owner, default: []].append(hunk)
                    console.out("\(file.path) \(header) → \(bubbles[owner].label)")
                }
            }
            for (owner, hunks) in byBubble { routed[owner, default: []].append((file, hunks)) }
        }
        if let forced { console.out("All staged changes → \(bubbles[forced].label)") }

        guard unplaced.isEmpty else {
            error("Some staged changes have no single bubble to go to:")
            for reason in unplaced { console.err("  \(reason)") }
            console.err("Route them one bubble at a time with '--to <bubble>', or unstage them.")
            return 1
        }
        let targets = routed.keys.sorted()
        for index in targets where bubbles[index].branch == nil {
            error("Bubble \(bubbles[index].label) has no sub-branch to fold the fix into.")
            return 1
        }
        if options.dryRun { return 0 }

        guard let common = await stack.commonDirectory() else {
            error("Could not locate the repository's git directory.")
            return 1
        }
        let scratch = "\(common)/stack-bubble/route-\(name)"
        let umbrellaTree = "\(scratch)/umbrella"
        let bubbleTree = "\(scratch)/bubble"
        func cleanUp() async {
            for path in [umbrellaTree, bubbleTree] {
                _ = await git.capture(["worktree", "remove", "--force", path], config: [:])
            }
            _ = await git.capture(["worktree", "prune"], config: [:])
        }
        await cleanUp()
        guard Sys.makeDirectory("\(common)/stack-bubble"), Sys.makeDirectory(scratch),
            await git.capture(["worktree", "add", "--detach", "--quiet", umbrellaTree, umbrellaTip], config: [:])
                .succeeded
        else {
            error("Could not create a worktree to route in under \(scratch).")
            await cleanUp()
            return 1
        }

        var newTips: [(index: Int, old: String?, new: String)] = []
        var foldedOver: [String: String] = [:]
        for index in targets {
            let bubble = bubbles[index]
            guard let branch = bubble.branch else { continue }
            let local = await stack.sha("refs/heads/\(branch)")
            let remoteTip = await stack.sha("refs/remotes/\(remote)/\(branch)")
            guard let tip = local ?? remoteTip,
                await stack.isAncestor(bubble.firstParent, of: tip)
            else {
                error("Sub-branch '\(branch)' of bubble \(bubble.label) is missing or no longer sits on its bubble.")
                await cleanUp()
                return 1
            }
            // Restack takes this tip as the bubble's content, so it must hold
            // everything the bubble and the remote sub-branch already have.
            var stale = !(await stack.isAncestor(bubble.secondParent, of: tip))
            if !stale, let remoteTip { stale = !(await stack.isAncestor(remoteTip, of: tip)) }
            if stale {
                error("Sub-branch '\(branch)' is behind bubble \(bubble.label) or '\(remote)/\(branch)'.")
                console.err("Run 'git stack-bubble sync \(branch)' first.")
                await cleanUp()
                return 1
            }
            guard
                let fixed = await fold(
                    routed[index] ?? [], into: bubble, at: tip, umbrellaTip: umbrellaTip,
                    message: options.message ?? "Fix \(bubble.label) from \(manifest.umbrella)",
                    umbrellaTree: umbrellaTree, bubbleTree: bubbleTree, patchPath: "\(scratch)/patch",
                    git: git, console: console)
            else {
                await cleanUp()
                return 1
            }
            newTips.append((index, local, fixed))
            if let remoteTip { foldedOver[branch] = remoteTip }
        }
        await cleanUp()

        // Nothing outside the scratch worktrees has changed until here.
        let backupPrefix = "backup/route-\(name)-\(backupTimestamp(now))"
        let worktrees = await Worktree.list(git: git)
        for entry in newTips {
            guard let branch = bubbles[entry.index].branch else { continue }
            if let old = entry.old {
                guard
                    await stack.moveLocal(
                        branch, from: old, to: entry.new, backup: "\(backupPrefix)/\(branch)", worktrees: worktrees,
                        console: console)
                else { return 1 }
            } else {
                _ = await git.capture(["branch", "--end-of-options", branch, entry.new], config: [:])
            }
            console.out("\(branch) now carries its fix at \(String(entry.new.prefix(12))).")
        }

        // The fix lives in the sub-branches now. Stashed rather than dropped,
        // so it can be compared against what the restack produces.
        let stashed = await git.capture(
            ["stash", "push", "--staged", "--quiet", "-m", "stack-bubble route: routed into \(targets.map { bubbles[$0].label }.joined(separator: ", "))"],
            config: [:])
        if stashed.succeeded {
            console.out("The staged fix is in 'git stash list' as a reference; drop it once the restack looks right.")
        } else {
            console.out("Could not stash the staged fix. Unstage it before the umbrella moves: git restore --staged .")
        }

        let earliest = bubbles[targets[0]].label
        guard options.restack else {
            console.out("Publish with: git stack-bubble restack --from \(earliest) --keep-base")
            return 0
        }
        console.out("")
        console.out("Restacking from \(earliest)...")
        var restack = Restack.Options()
        restack.from = earliest
        restack.keepBase = true
        restack.rewrittenOver = foldedOver
        return await Restack.Context(name: name, git: git, console: console, hooks: hooks, now: now).start(restack)
    }

    /// The stack's bubbles as the umbrella has them now, with the commits
    /// each one contains.
    static func loadBubbles(
        _ manifest: StackManifest, remote: String, tip: String, git: any GitRunning, console: any Console
    ) async -> [Bubble]? {
        let stack = StackGit(git: git)
        guard let first = manifest.bubbles.first,
            let base = await stack.parents(of: first.merge).first,
            let chain = await stack.firstParentChain(from: base, to: tip),
            Array(chain.prefix(manifest.bubbles.count)) == manifest.bubbles.map(\.merge)
        else {
            console.err("ERROR: The umbrella does not start with the stack's bubbles. Sync it first.")
            return nil
        }
        guard
            let adopted = await StackBubble.discoverBubbles(
                Array(chain.dropFirst(manifest.bubbles.count)), remote: remote, umbrella: manifest.umbrella,
                base: manifest.base, git: git, console: console)
        else { return nil }
        var bubbles: [Bubble] = []
        for bubble in manifest.bubbles + adopted {
            let parents = await stack.parents(of: bubble.merge)
            guard parents.count == 2 else { return nil }
            let commits = await git.capture(["rev-list", "\(parents[0])..\(parents[1])"], config: [:]).lines
            bubbles.append(
                Bubble(
                    label: bubble.label, branch: bubble.branch, firstParent: parents[0], secondParent: parents[1],
                    commits: Set(commits)))
        }
        return bubbles
    }

    /// The old-file lines that say who owns a hunk: the lines it changes, or
    /// for a pure addition the lines either side of where it goes.
    static func blameLines(for hunk: Hunk) -> [Int] {
        if hunk.oldCount > 0 { return Array(hunk.oldStart..<(hunk.oldStart + hunk.oldCount)) }
        return [hunk.oldStart, hunk.oldStart + 1].filter { $0 >= 1 }
    }

    static func blame(_ path: String, lines: [Int], at commit: String, git: any GitRunning) async -> [String] {
        var commits: [String] = []
        for line in lines {
            // One line at a time: a context line past the end of the file is
            // an error for that line only.
            let result = await git.capture(
                ["blame", "--porcelain", "-L", "\(line),+1", commit, "--", path], config: [:])
            guard result.succeeded, let first = result.lines.first,
                let sha = first.split(separator: " ").first, sha.count == 40
            else { continue }
            commits.append(String(sha))
        }
        return commits
    }

    /// Folds one bubble's hunks into its sub-branch and returns the new tip.
    ///
    /// The hunks are made into a commit on the umbrella's own tree first, and
    /// that commit is cherry-picked onto the sub-branch, so the three-way merge
    /// absorbs every line later bubbles shifted. bubble-absorb then turns what
    /// it can into fixups of the commits that wrote those lines, with the
    /// bubble's previous merge as the floor, and anything left is committed.
    static func fold(
        _ changes: [(file: FileDiff, hunks: [Hunk])], into bubble: Bubble, at tip: String, umbrellaTip: String,
        message: String, umbrellaTree: String, bubbleTree: String, patchPath: String,
        git: any GitRunning, console: any Console
    ) async -> String? {
        func error(_ text: String) -> String? {
            console.err("ERROR: \(text)")
            return nil
        }
        let onUmbrella = WorktreeGit(path: umbrellaTree, git: git)
        let text = changes.flatMap { patch($0.file, hunks: $0.hunks) }.joined(separator: "\n") + "\n"
        guard Sys.writeFile(patchPath, text) else { return error("Could not write \(patchPath).") }
        guard await onUmbrella.capture(["reset", "--hard", "--quiet", umbrellaTip], config: [:]).succeeded,
            await onUmbrella.capture(["apply", "--unidiff-zero", "--index", patchPath], config: [:]).succeeded,
            let tree = await onUmbrella.capture(["write-tree"], config: [:]).value.nonEmpty,
            let fix = await git.capture(["commit-tree", tree, "-p", umbrellaTip, "-m", message], config: [:]).value
                .nonEmpty
        else { return error("Could not separate the fix for \(bubble.label) from the rest.") }

        if !Sys.pathExists(bubbleTree) {
            guard
                await git.capture(["worktree", "add", "--detach", "--quiet", bubbleTree, tip], config: [:]).succeeded
            else { return error("Could not create a worktree for \(bubble.label).") }
        }
        let onBubble = WorktreeGit(path: bubbleTree, git: git)
        guard await onBubble.capture(["checkout", "--quiet", "--force", "--detach", tip], config: [:]).succeeded
        else { return error("Could not check out \(bubble.label)'s sub-branch.") }
        guard await onBubble.capture(["cherry-pick", "--no-commit", fix], config: [:]).succeeded else {
            _ = await onBubble.capture(["cherry-pick", "--abort"], config: [:])
            _ = await onBubble.capture(["reset", "--hard", "--quiet"], config: [:])
            return error("The fix for \(bubble.label) does not apply to its sub-branch. Nothing was changed.")
        }

        console.out("Folding the fix into \(bubble.label)...")
        let absorbed = await BubbleAbsorb.run(
            // The scratch worktree is detached so that no branch moves before
            // every bubble's fix has been folded.
            arguments: ["--base", bubble.firstParent, "--force-author", "--force-detach"],
            git: ConfiguredGit(git: onBubble, config: noEditor), console: console)
        // git-absorb reports success even when its autosquash rebase fails,
        // which leaves the fixups as commits of their own.
        let leftover = await onBubble.capture(
            ["log", "--format=%s", "--grep=^fixup! ", "\(bubble.firstParent)..HEAD"], config: [:])
        guard absorbed == 0, leftover.succeeded, leftover.lines.isEmpty else {
            return error("git-absorb could not fold the fix into \(bubble.label). Nothing was changed.")
        }
        if await onBubble.succeeds("diff", "--cached", "--quiet") == false {
            guard await onBubble.capture(["commit", "--quiet", "-m", message], config: [:]).succeeded else {
                return error("Could not commit the part of the fix git-absorb left for \(bubble.label).")
            }
        }
        guard let head = await onBubble.capture(["rev-parse", "HEAD"], config: [:]).value.nonEmpty, head != tip
        else { return error("Folding the fix into \(bubble.label) changed nothing.") }
        return head
    }
}
