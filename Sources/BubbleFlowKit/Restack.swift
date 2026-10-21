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

/// `git stack-bubble restack`: rebuilds the umbrella one bubble at a time on a
/// new base, then publishes every moved branch and the manifest in one atomic
/// push.
///
/// All the rewriting happens on detached commits in a worktree of its own, so
/// no branch moves, locally or on the remote, until publish. A restack that
/// stops part-way therefore leaves nothing half-moved: `--continue` resumes it
/// and `--abort` throws the detached work away.
enum Restack {
    enum Mode: Equatable {
        case start
        case resume
        case abort
        case breakLock
    }

    struct Options: Equatable {
        var mode = Mode.start
        var stack: String?
        var from: String?
        var keepBase = false
    }

    static func parse(_ arguments: [String], console: any Console) -> Options? {
        var options = Options()
        var scanner = ArgumentScanner(arguments)
        func setMode(_ mode: Mode, _ flag: String) -> Bool {
            guard options.mode == .start else {
                console.err("ERROR: \(flag) cannot be combined with another mode")
                return false
            }
            options.mode = mode
            return true
        }
        while let argument = scanner.peek {
            switch argument {
            case "--stack", "--from":
                guard let value = scanner.takeValue(for: argument) else {
                    console.err("ERROR: \(argument) requires a value")
                    return nil
                }
                if argument == "--stack" { options.stack = value } else { options.from = value }
            case "--keep-base":
                options.keepBase = true
                scanner.advance()
            case "--continue":
                guard setMode(.resume, argument) else { return nil }
                scanner.advance()
            case "--abort":
                guard setMode(.abort, argument) else { return nil }
                scanner.advance()
            case "--break-lock":
                guard setMode(.breakLock, argument) else { return nil }
                scanner.advance()
            case let other:
                console.err("Unknown argument: \(other)")
                return nil
            }
        }
        if options.mode != .start, options.from != nil || options.keepBase {
            console.err("ERROR: --from and --keep-base only apply when starting a restack")
            return nil
        }
        return options
    }

    static func run(
        arguments: [String],
        git: any GitRunning,
        console: any Console,
        hooks: @escaping HookRunner,
        now: Int
    ) async -> Int32 {
        guard let options = parse(arguments, console: console) else { return 1 }
        guard let name = await StackBubble.resolveName(options.stack, git: git, console: console) else { return 1 }
        let context = Context(name: name, git: git, console: console, hooks: hooks, now: now)
        switch options.mode {
        case .start: return await context.start(options)
        case .resume: return await context.resume()
        case .abort: return await context.abort()
        case .breakLock: return await context.breakLock()
        }
    }

    struct Context {
        let name: String
        let git: any GitRunning
        let console: any Console
        let hooks: HookRunner
        let now: Int

        var stack: StackGit { StackGit(git: git) }
        var stateRef: String { RestackState.ref(for: name) }
        var manifestRef: String { StackManifest.ref(for: name) }

        func error(_ message: String) { console.err("ERROR: \(message)") }

        /// rerere records each resolution, so the same conflict met again in a
        /// later restack is replayed instead of resolved by hand.
        static let rebaseConfig = ["rerere.enabled": "true", "rerere.autoUpdate": "true"]

        // MARK: - start

        func start(_ options: Options) async -> Int32 {
            if await stack.sha(stateRef) != nil {
                error("A restack of '\(name)' is already in progress.")
                console.err("Run 'git stack-bubble restack --continue', or '--abort' to give it up.")
                return 1
            }

            let remote = await StackBubble.remote(for: name, git: git)
            console.out("Fetching \(remote)...")
            guard await git.passthrough(["fetch", "--quiet", "--end-of-options", remote], config: [:]) == 0 else {
                return 1
            }
            guard
                let (manifest, manifestSHA) = await StackBubble.fetchManifest(
                    name: name, remote: remote, git: git, console: console)
            else { return 1 }
            if let lock = manifest.lock {
                error("'\(name)' is locked: \(lock.by) has been restacking it since \(backupTimestamp(lock.since)).")
                console.err("If that restack is dead, release it with 'git stack-bubble restack --break-lock'.")
                return 1
            }

            guard let baseTip = await stack.sha("refs/remotes/\(remote)/\(manifest.base)") else {
                error("'\(remote)/\(manifest.base)' does not exist.")
                return 1
            }
            guard let umbrellaTip = await stack.sha("refs/remotes/\(remote)/\(manifest.umbrella)") else {
                error("'\(remote)/\(manifest.umbrella)' does not exist.")
                return 1
            }
            guard let umbrellaTipEntry = await tip(of: manifest.umbrella, remote: remote) else { return 1 }

            // Where the published umbrella starts. The first bubble's first
            // parent is exact. merge-base is only a fallback for a stack with
            // no bubbles yet, and is wrong once the base has absorbed the
            // umbrella, which a stack never does while it is open.
            let oldBase: String
            if let first = manifest.bubbles.first {
                guard let parent = await stack.parents(of: first.merge).first else {
                    error("Bubble \(first.label) (\(first.merge)) is missing from this clone.")
                    return 1
                }
                oldBase = parent
            } else {
                guard let forkPoint = await stack.mergeBase(baseTip, umbrellaTip) else {
                    error("'\(manifest.umbrella)' shares no history with '\(remote)/\(manifest.base)'.")
                    return 1
                }
                oldBase = forkPoint
            }
            guard await stack.isAncestor(oldBase, of: umbrellaTip),
                let chain = await stack.firstParentChain(from: oldBase, to: umbrellaTip),
                Array(chain.prefix(manifest.bubbles.count)) == manifest.bubbles.map(\.merge)
            else {
                error(
                    "'\(remote)/\(manifest.umbrella)' no longer starts with the bubbles of generation "
                        + "\(manifest.generation).")
                console.err("It was rewritten outside 'restack'. Compare it with \(manifestRef) before going on.")
                return 1
            }

            // Bubbles landed on the umbrella since the last generation join
            // the stack here.
            guard
                let adopted = await StackBubble.discoverBubbles(
                    Array(chain.dropFirst(manifest.bubbles.count)), remote: remote,
                    umbrella: manifest.umbrella, base: manifest.base, git: git, console: console)
            else { return 1 }
            if !adopted.isEmpty {
                console.out(
                    "Adding \(adopted.count) bubble(s) landed since generation \(manifest.generation): "
                        + adopted.map(\.label).joined(separator: ", "))
            }
            let bubbles = manifest.bubbles + adopted

            var verify = VerifyBubble.Options()
            verify.ref = umbrellaTip
            verify.base = oldBase
            guard await VerifyBubble.run(options: verify, git: git, console: console) == 0 else {
                error("'\(remote)/\(manifest.umbrella)' fails verification. Fix it before restacking.")
                return 1
            }

            var fromIndex: Int?
            if let from = options.from {
                guard let index = bubbles.firstIndex(where: { $0.label == from || $0.branch == from }) else {
                    error("No bubble labelled or landed from '\(from)'.")
                    return 1
                }
                fromIndex = index
            }

            var state = RestackState(
                name: name, lockedManifest: "", worktree: "", oldBase: oldBase,
                newBase: options.keepBase ? oldBase : baseTip, stage: .rebase(0))

            for (index, bubble) in bubbles.enumerated() {
                let parents = await stack.parents(of: bubble.merge)
                guard parents.count == 2 else {
                    error("Bubble \(bubble.label) (\(bubble.merge)) is not a merge.")
                    return 1
                }
                var content = parents[1]
                if let branch = bubble.branch {
                    guard let entry = await tip(of: branch, remote: remote) else { return 1 }
                    state.tips.append(entry)
                    if let moved = entry.remote ?? entry.local, moved != parents[1] {
                        if let fromIndex, index >= fromIndex, moved != parents[0],
                            await stack.isAncestor(parents[0], of: moved)
                        {
                            console.out("Taking '\(branch)' at \(String(moved.prefix(12))) as bubble \(bubble.label).")
                            content = moved
                        } else if await stack.isAncestor(parents[1], of: moved) {
                            error("'\(branch)' has commits that never landed in bubble \(bubble.label).")
                            console.err(
                                "Replaying it would change the bubble. Land them first, or pass "
                                    + "'--from \(bubble.label)' to take them.")
                            return 1
                        } else {
                            error("'\(branch)' no longer contains bubble \(bubble.label).")
                            console.err(
                                "If it was rewritten on purpose, pass '--from \(bubble.label)' to take it as is.")
                            return 1
                        }
                    }
                }
                state.bubbles.append(
                    RestackState.Bubble(
                        oldMerge: bubble.merge, oldFirstParent: parents[0], oldSecondParent: parents[1],
                        content: content, label: bubble.label, branch: bubble.branch))
            }
            state.tips.append(umbrellaTipEntry)
            if state.bubbles.isEmpty { state.stage = .pending(0) }

            let firstParents = [oldBase] + bubbles.map(\.merge)
            for branch in manifest.pending {
                guard let entry = await tip(of: branch, remote: remote) else { return 1 }
                guard let pendingTip = entry.remote ?? entry.local else {
                    error("Pending branch '\(branch)' no longer exists. Remove it from the stack first.")
                    return 1
                }
                guard let fork = await stack.mergeBase(pendingTip, umbrellaTip),
                    let forkPosition = firstParents.firstIndex(of: fork)
                else {
                    error("Pending branch '\(branch)' does not fork from a bubble's merge on the umbrella.")
                    return 1
                }
                state.tips.append(entry)
                state.pending.append(
                    RestackState.Pending(
                        branch: branch, tip: pendingTip, forkIndex: forkPosition == 0 ? nil : forkPosition - 1))
            }

            if state.bubbles.isEmpty, state.pending.isEmpty { state.stage = .publish }

            let unchanged =
                state.newBase == oldBase && adopted.isEmpty
                && state.bubbles.allSatisfy { $0.content == $0.oldSecondParent }
            if unchanged {
                console.out("'\(name)' is already on \(remote)/\(manifest.base) and nothing in it moved.")
                return 0
            }

            if let preflight = await configured("stack.preflight") {
                console.out("Running stack.preflight...")
                let directory = await git.capture(["rev-parse", "--show-toplevel"], config: [:]).value
                let environment = [
                    "BUBBLEFLOW_STACK": name,
                    "BUBBLEFLOW_UMBRELLA": umbrellaTip,
                    "BUBBLEFLOW_OLD_BASE": oldBase,
                    "BUBBLEFLOW_NEW_BASE": state.newBase,
                ]
                guard await hooks(preflight, directory, environment) == 0 else {
                    error("stack.preflight failed. Nothing has been changed.")
                    return 1
                }
            }

            // The lock. Everything above only read; from here on the stack is
            // ours until publish or abort releases it.
            var locked = manifest
            locked.lock = StackManifest.Lock(since: now, by: await stack.identity())
            locked.rewrites = []
            locked.notes = []
            guard let lockCommit = await stack.recordCommit(message: locked.encoded(), parent: manifestSHA) else {
                error("Could not write the lock.")
                return 1
            }
            let lockPush = await stack.push(
                remote: remote, updates: [.init(ref: manifestRef, new: lockCommit, expected: manifestSHA)])
            guard lockPush.succeeded else {
                error("Could not take the lock: \(manifestRef) changed on '\(remote)' since it was read.")
                console.err("Someone else updated the stack. Run restack again.")
                return 1
            }
            _ = await git.capture(["update-ref", manifestRef, lockCommit], config: [:])
            state.lockedManifest = lockCommit

            guard let common = await stack.commonDirectory() else {
                error("Could not locate the repository's git directory.")
                return await failAfterLock(state, remote: remote)
            }
            state.worktree = "\(common)/stack-bubble/\(name)"
            // A worktree left by a restack that died before saving its state.
            _ = await git.capture(["worktree", "remove", "--force", state.worktree], config: [:])
            _ = await git.capture(["worktree", "prune"], config: [:])
            let added = await git.capture(
                ["worktree", "add", "--detach", "--quiet", state.worktree, state.newBase], config: [:])
            guard added.succeeded else {
                console.err(String(added.standardError.trimmedWhitespace()))
                error("Could not create the restack worktree at \(state.worktree).")
                return await failAfterLock(state, remote: remote)
            }
            guard await save(state) else {
                error("Could not record the restack's state.")
                return await failAfterLock(state, remote: remote)
            }

            console.out(
                "Restacking \(state.bubbles.count) bubble(s) of '\(name)' onto \(String(state.newBase.prefix(12))) "
                    + "in \(state.worktree)")
            return await advance(state)
        }

        /// A branch's tip on the remote and locally, refusing when both exist
        /// and disagree: the remote is what restack rewrites and leases
        /// against, and a local branch that differs would be overwritten.
        func tip(of branch: String, remote: String) async -> RestackState.Tip? {
            let remoteTip = await stack.sha("refs/remotes/\(remote)/\(branch)")
            let localTip = await stack.sha("refs/heads/\(branch)")
            if let remoteTip, let localTip, remoteTip != localTip {
                error("Local '\(branch)' differs from '\(remote)/\(branch)'. Push or reset it first.")
                return nil
            }
            return RestackState.Tip(branch: branch, remote: remoteTip, local: localTip)
        }

        func configured(_ key: String) async -> String? {
            let value = await git.configValue(key, default: "")
            return value.trimmedWhitespace().isEmpty ? nil : value
        }

        // MARK: - state

        func save(_ state: RestackState) async -> Bool {
            let previous = await stack.sha(stateRef)
            guard let commit = await stack.recordCommit(message: state.encoded(), parent: previous) else {
                return false
            }
            return await git.capture(["update-ref", stateRef, commit], config: [:]).succeeded
        }

        func load() async -> RestackState? {
            guard let sha = await stack.sha(stateRef) else {
                error("No restack of '\(name)' is in progress.")
                return nil
            }
            guard let text = await stack.message(of: sha) else {
                error("Could not read \(stateRef).")
                return nil
            }
            do {
                return try RestackState.parse(text)
            } catch {
                self.error("\(stateRef) is unreadable: \(error)")
                return nil
            }
        }

        // MARK: - the rebuild

        func newFirstParent(of index: Int, in state: RestackState) -> String {
            index == 0 ? state.newBase : state.built[index - 1].merge
        }

        func nextStage(after index: Int, in state: RestackState) -> RestackState.Stage {
            if index + 1 < state.bubbles.count { return .rebase(index + 1) }
            return state.pending.isEmpty ? .publish : .pending(0)
        }

        func advance(_ initial: RestackState) async -> Int32 {
            var state = initial
            let worktree = WorktreeGit(path: state.worktree, git: git)
            while true {
                switch state.stage {
                case .rebase(let index):
                    let bubble = state.bubbles[index]
                    let newParent = newFirstParent(of: index, in: state)
                    if newParent == bubble.oldFirstParent {
                        if bubble.content == bubble.oldSecondParent {
                            // Nothing below it moved and nothing was added to
                            // it: the old bubble stands as it is.
                            state.built.append(.init(secondParent: bubble.content, merge: bubble.oldMerge))
                            state.stage = nextStage(after: index, in: state)
                            guard await save(state) else { return saveFailed() }
                            continue
                        }
                        // Commits were added, but it already sits on the right
                        // merge, so there is nothing to replay.
                        guard
                            await worktree.passthrough(["checkout", "--quiet", "--detach", bubble.content], config: [:])
                                == 0
                        else { return 1 }
                    } else {
                        console.out("")
                        console.out("Replaying bubble \(index + 1)/\(state.bubbles.count) \(bubble.label)...")
                        let status = await worktree.passthrough(
                            ["rebase", "--rebase-merges", "--onto", newParent, bubble.oldFirstParent, bubble.content],
                            config: Self.rebaseConfig)
                        if status != 0 { return stopped(state, at: "bubble \(bubble.label)") }
                    }
                    state.stage = .gate(index)
                    guard await save(state) else { return saveFailed() }

                case .gate(let index):
                    let bubble = state.bubbles[index]
                    let newParent = newFirstParent(of: index, in: state)
                    guard let head = await worktree.capture(["rev-parse", "HEAD"], config: [:]).value.nonEmpty else {
                        error("Could not read HEAD in \(state.worktree).")
                        return 1
                    }
                    guard head != newParent, await stack.isAncestor(newParent, of: head) else {
                        error("Bubble \(bubble.label) is empty on the new base, or no longer sits on it.")
                        console.err("Inspect \(state.worktree), or give the restack up with '--abort'.")
                        return 1
                    }
                    if let gate = await configured("stack.exec") {
                        console.out("Running stack.exec on bubble \(bubble.label)...")
                        let environment = [
                            "BUBBLEFLOW_STACK": name,
                            "BUBBLEFLOW_BUBBLE": bubble.label,
                            "BUBBLEFLOW_BUBBLE_BRANCH": bubble.branch ?? "",
                        ]
                        guard await hooks(gate, state.worktree, environment) == 0 else {
                            error("stack.exec failed on bubble \(bubble.label).")
                            console.err("Fix it in \(state.worktree) (amend or add commits there), then")
                            console.err("run 'git stack-bubble restack --continue'. '--abort' gives the restack up.")
                            return 1
                        }
                    }
                    guard let merge = await bubbleMerge(replacing: bubble.oldMerge, firstParent: newParent, contents: head)
                    else {
                        error("Could not create the new merge for bubble \(bubble.label).")
                        return 1
                    }
                    var verify = VerifyBubble.Options()
                    verify.ref = merge
                    verify.base = newParent
                    guard await VerifyBubble.run(options: verify, git: git, console: console) == 0 else {
                        error("The rebuilt bubble \(bubble.label) failed verification.")
                        return 1
                    }
                    state.built.append(.init(secondParent: head, merge: merge))
                    state.stage = nextStage(after: index, in: state)
                    guard await save(state) else { return saveFailed() }

                case .pending(let index):
                    let entry = state.pending[index]
                    let (oldFork, newFork) = forks(of: entry, in: state)
                    if state.rebuiltPending.count == index {
                        if oldFork == newFork {
                            state.rebuiltPending.append(entry.tip)
                        } else {
                            console.out("")
                            console.out("Replaying pending branch \(entry.branch)...")
                            let status = await worktree.passthrough(
                                ["rebase", "--rebase-merges", "--onto", newFork, oldFork, entry.tip],
                                config: Self.rebaseConfig)
                            if status != 0 { return stopped(state, at: "pending branch \(entry.branch)") }
                            guard let head = await worktree.capture(["rev-parse", "HEAD"], config: [:]).value.nonEmpty
                            else { return 1 }
                            state.rebuiltPending.append(head)
                        }
                    }
                    state.stage = index + 1 < state.pending.count ? .pending(index + 1) : .publish
                    guard await save(state) else { return saveFailed() }

                case .publish:
                    return await publish(state)
                }
            }
        }

        func forks(of entry: RestackState.Pending, in state: RestackState) -> (old: String, new: String) {
            guard let index = entry.forkIndex else { return (state.oldBase, state.newBase) }
            return (state.bubbles[index].oldMerge, state.built[index].merge)
        }

        /// The new bubble: an empty merge of the replayed contents onto the new
        /// previous merge, with the old merge's message, so the subject reads
        /// exactly as it did and `range-diff` shows only real changes.
        ///
        /// Built with `commit-tree` rather than `land`: land checks the target
        /// out and names the subject after the current branch, and restack has
        /// neither. The tree is the contents' own, which is what makes the
        /// merge empty by construction; verify confirms it afterwards.
        func bubbleMerge(replacing oldMerge: String, firstParent: String, contents: String) async -> String? {
            guard let message = await stack.message(of: oldMerge) else { return nil }
            let result = await git.capture(
                ["commit-tree", "\(contents)^{tree}", "-p", firstParent, "-p", contents, "-m", message],
                config: [:])
            return result.succeeded ? result.value.nonEmpty : nil
        }

        func stopped(_ state: RestackState, at what: String) -> Int32 {
            console.err("")
            error("The restack stopped on a conflict in \(what).")
            console.err("Resolve it in \(state.worktree) and stage the result, then run")
            console.err("  git stack-bubble restack --continue")
            console.err("Nothing has been published. '--abort' gives the restack up and releases the lock.")
            return 1
        }

        func saveFailed() -> Int32 {
            error("Could not record the restack's state in \(stateRef).")
            return 1
        }

        // MARK: - --continue

        func resume() async -> Int32 {
            guard var state = await load() else { return 1 }
            let worktree = WorktreeGit(path: state.worktree, git: git)
            guard Sys.pathExists(state.worktree) else {
                error("The restack worktree at \(state.worktree) is gone. Run '--abort' and start again.")
                return 1
            }

            if await stack.rebaseInProgress(worktree: state.worktree) {
                // An editor would block: the replayed messages are kept as is.
                let status = await worktree.passthrough(
                    ["rebase", "--continue"], config: Self.rebaseConfig.merging(["core.editor": "true"]) { $1 })
                if status != 0 { return stopped(state, at: "the current step") }
            }

            switch state.stage {
            case .rebase(let index):
                // The rebase finished: by --continue above, or by hand. If it
                // was aborted instead, HEAD is not on the new previous merge,
                // and the step simply runs again.
                let head = await worktree.capture(["rev-parse", "HEAD"], config: [:]).value
                let newParent = newFirstParent(of: index, in: state)
                if head != newParent, await stack.isAncestor(newParent, of: head) {
                    state.stage = .gate(index)
                    guard await save(state) else { return saveFailed() }
                }
            case .pending(let index) where state.rebuiltPending.count == index:
                let head = await worktree.capture(["rev-parse", "HEAD"], config: [:]).value
                let (_, newFork) = forks(of: state.pending[index], in: state)
                if head != newFork, await stack.isAncestor(newFork, of: head) {
                    state.rebuiltPending.append(head)
                    state.stage = index + 1 < state.pending.count ? .pending(index + 1) : .publish
                    guard await save(state) else { return saveFailed() }
                }
            case .gate, .pending, .publish:
                break
            }
            return await advance(state)
        }

        // MARK: - publish

        func publish(_ state: RestackState) async -> Int32 {
            guard case .success(let locked) = await stack.readManifest(at: state.lockedManifest) else {
                error("Could not read the locked manifest \(state.lockedManifest).")
                return 1
            }
            let remote = locked.remote
            let newTip = state.built.last?.merge ?? state.newBase

            console.out("")
            console.out("Changes per bubble (old...new):")
            for (index, (bubble, built)) in zip(state.bubbles, state.built).enumerated()
            where built.merge != bubble.oldMerge {
                console.out("")
                console.out("== \(bubble.label)")
                _ = await git.passthrough(
                    [
                        "range-diff", "\(bubble.oldFirstParent)..\(bubble.oldSecondParent)",
                        "\(newFirstParent(of: index, in: state))..\(built.secondParent)",
                    ], config: [:])
            }

            guard let remoteSHA = await stack.remoteManifest(remote: remote, name: name) else {
                error("Could not reach remote '\(remote)'.")
                return 1
            }
            guard remoteSHA == state.lockedManifest else {
                error("The lock on '\(name)' is no longer this restack's: it was broken or released.")
                console.err("Nothing can be published. Run 'git stack-bubble restack --abort'.")
                return 1
            }

            // Every new position, branch by branch.
            var moves: [String: String] = [locked.umbrella: newTip]
            var rewrites: [StackManifest.Rewrite] = []
            func rewrite(_ old: String, _ new: String) {
                if old != new, !rewrites.contains(where: { $0.old == old }) {
                    rewrites.append(.init(old: old, new: new))
                }
            }
            if let oldTip = state.bubbles.last?.oldMerge { rewrite(oldTip, newTip) }
            var bubbles: [StackManifest.Bubble] = []
            for (bubble, built) in zip(state.bubbles, state.built) {
                bubbles.append(.init(merge: built.merge, label: bubble.label, branch: bubble.branch))
                rewrite(bubble.oldMerge, built.merge)
                rewrite(bubble.oldSecondParent, built.secondParent)
                rewrite(bubble.content, built.secondParent)
                if let branch = bubble.branch { moves[branch] = built.secondParent }
            }
            for (entry, rebuilt) in zip(state.pending, state.rebuiltPending) {
                rewrite(entry.tip, rebuilt)
                moves[entry.branch] = rebuilt
            }

            var next = locked
            next.generation += 1
            next.lock = nil
            next.bubbles = bubbles
            next.rewrites = rewrites
            next.notes = ["restacked by \(await stack.identity()) onto \(state.newBase)"]
            guard let manifestCommit = await stack.recordCommit(message: next.encoded(), parent: state.lockedManifest)
            else {
                error("Could not write the new manifest.")
                return 1
            }

            var updates = [StackGit.Update(ref: manifestRef, new: manifestCommit, expected: state.lockedManifest)]
            for tip in state.tips {
                guard let remoteTip = tip.remote, let new = moves[tip.branch], new != remoteTip else { continue }
                updates.append(.init(ref: "refs/heads/\(tip.branch)", new: new, expected: remoteTip))
            }
            console.out("")
            console.out("Publishing generation \(next.generation) to \(remote)...")
            let pushed = await stack.push(remote: remote, updates: updates)
            guard pushed.succeeded else {
                console.err(String((pushed.standardError + pushed.standardOutput).trimmedWhitespace()))
                error("The push was refused, so nothing moved on '\(remote)'.")
                console.err("'git stack-bubble restack --continue' tries the publish again; '--abort' gives it up.")
                return 1
            }
            _ = await git.capture(["update-ref", manifestRef, manifestCommit], config: [:])

            let backupPrefix = "backup/restack-\(name)-\(backupTimestamp(now))"
            let worktrees = await Worktree.list(git: git)
            for tip in state.tips {
                guard let local = tip.local, let new = moves[tip.branch], new != local else { continue }
                await moveLocal(tip.branch, from: local, to: new, backup: "\(backupPrefix)/\(tip.branch)", worktrees: worktrees)
            }

            _ = await git.capture(["worktree", "remove", "--force", state.worktree], config: [:])
            _ = await git.capture(["update-ref", "-d", stateRef], config: [:])

            console.out("")
            console.out("Restacked '\(name)' onto \(String(state.newBase.prefix(12))): generation \(next.generation).")
            console.out("Local branches that moved are backed up under \(backupPrefix)/.")
            return 0
        }

        /// Moves a local branch to its rebuilt commit, after tagging where it
        /// was. A branch checked out in a worktree moves by `reset --keep`
        /// there, so the files follow it and uncommitted work is kept or the
        /// move refused. A branch that moved since restack read it is left
        /// alone, with the command that would move it.
        func moveLocal(_ branch: String, from old: String, to new: String, backup: String, worktrees: [Worktree]) async {
            _ = await git.capture(["tag", backup, old], config: [:])
            if let holder = worktrees.first(where: { $0.branch == "refs/heads/\(branch)" }) {
                let there = WorktreeGit(path: holder.path, git: git)
                let head = await there.capture(["rev-parse", "HEAD"], config: [:]).value
                if head == old, await stack.rebaseInProgress(worktree: holder.path) == false,
                    await there.capture(["reset", "--quiet", "--keep", new], config: [:]).succeeded
                {
                    return
                }
                console.out(
                    "Left '\(branch)' at \(holder.path) where it was. Move it with: git reset --keep \(new)")
                return
            }
            if await git.capture(["update-ref", "refs/heads/\(branch)", new, old], config: [:]).succeeded == false {
                console.out("Left local '\(branch)' alone: it moved during the restack. The rebuilt commit is \(new).")
            }
        }

        // MARK: - --abort and --break-lock

        func abort() async -> Int32 {
            guard let state = await load() else {
                let remote = await StackBubble.remote(for: name, git: git)
                if let local = await stack.sha(manifestRef),
                    case .success(let manifest) = await stack.readManifest(at: local), manifest.lock != nil
                {
                    console.err("If '\(name)' is still locked, '--break-lock' releases it (\(remote)).")
                }
                return 1
            }
            if await stack.rebaseInProgress(worktree: state.worktree) {
                _ = await WorktreeGit(path: state.worktree, git: git).capture(["rebase", "--abort"], config: [:])
            }
            _ = await git.capture(["worktree", "remove", "--force", state.worktree], config: [:])
            _ = await git.capture(["worktree", "prune"], config: [:])
            _ = await git.capture(["update-ref", "-d", stateRef], config: [:])
            console.out("Dropped the restack's work in progress. No branch was moved.")

            guard case .success(let locked) = await stack.readManifest(at: state.lockedManifest) else {
                error("Could not read the locked manifest to release the lock.")
                return 1
            }
            return await release(
                locked, at: state.lockedManifest, note: "restack aborted by \(await stack.identity())")
        }

        /// Gives a restack whose lock was just taken back its lock, for
        /// failures between taking it and saving the first state.
        func failAfterLock(_ state: RestackState, remote: String) async -> Int32 {
            if case .success(let locked) = await stack.readManifest(at: state.lockedManifest) {
                _ = await release(locked, at: state.lockedManifest, note: "restack failed to start")
            }
            return 1
        }

        func release(_ locked: StackManifest, at lockedSHA: String, note: String) async -> Int32 {
            guard let remoteSHA = await stack.remoteManifest(remote: locked.remote, name: name) else {
                error("Could not reach '\(locked.remote)' to release the lock.")
                return 1
            }
            guard remoteSHA == lockedSHA else {
                console.out("The lock on '\(name)' is no longer this restack's, so it was left as it is.")
                return 0
            }
            var released = locked
            released.lock = nil
            released.rewrites = []
            released.notes = [note]
            guard await publishManifest(released, parent: lockedSHA, remote: locked.remote) else { return 1 }
            console.out("Released the lock on '\(name)'.")
            return 0
        }

        func breakLock() async -> Int32 {
            let remote = await StackBubble.remote(for: name, git: git)
            guard
                let (manifest, sha) = await StackBubble.fetchManifest(
                    name: name, remote: remote, git: git, console: console)
            else { return 1 }
            guard let lock = manifest.lock else {
                console.out("'\(name)' is not locked.")
                return 0
            }
            var released = manifest
            released.lock = nil
            released.rewrites = []
            released.notes = [
                "lock held by \(lock.by) since \(backupTimestamp(lock.since)) broken by \(await stack.identity())"
            ]
            guard await publishManifest(released, parent: sha, remote: remote) else { return 1 }
            console.out("Broke the lock \(lock.by) took at \(backupTimestamp(lock.since)).")
            console.out("Their restack can no longer publish; they should run 'git stack-bubble restack --abort'.")
            return 0
        }

        func publishManifest(_ manifest: StackManifest, parent: String, remote: String) async -> Bool {
            guard let commit = await stack.recordCommit(message: manifest.encoded(), parent: parent) else {
                error("Could not write the manifest.")
                return false
            }
            let pushed = await stack.push(
                remote: remote, updates: [.init(ref: manifestRef, new: commit, expected: parent)])
            guard pushed.succeeded else {
                error("\(manifestRef) changed on '\(remote)' while it was being updated. Try again.")
                return false
            }
            _ = await git.capture(["update-ref", manifestRef, commit], config: [:])
            return true
        }
    }
}

extension String {
    /// Nil for an empty string, for chaining git output into a `guard let`.
    var nonEmpty: String? { isEmpty ? nil : self }
}
