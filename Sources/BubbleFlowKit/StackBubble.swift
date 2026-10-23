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

/// `git stack-bubble`: an umbrella branch kept as a base followed by a chain of
/// bubbles, each landed from a sub-branch that forks from the previous bubble's
/// merge. The stack's structure is shared through a manifest ref on the remote.
public enum StackBubble {
    public static let usage = """
        Usage: git stack-bubble init <name> --umbrella <branch> [--base <branch>] [--remote <remote>] [--pending <branch>]...
               git stack-bubble show [--stack <name>]
               git stack-bubble restack [--stack <name>] [--from <bubble>] [--keep-base]
               git stack-bubble restack --continue | --abort | --break-lock [--stack <name>]
               git stack-bubble sync [--stack <name>] [--dry-run] [<branch>...]
               git stack-bubble new <branch> [--stack <name>]
               git stack-bubble route [--stack <name>] [--to <bubble>] [-m <message>] [--dry-run] [--no-restack]
        """

    public static func run(
        arguments: [String],
        git: any GitRunning,
        console: any Console,
        hooks: @escaping HookRunner = Hook.shell,
        now: Int = Sys.now()
    ) async -> Int32 {
        guard let subcommand = arguments.first else {
            console.err(usage)
            return 1
        }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "init":
            return await initialize(arguments: rest, git: git, console: console)
        case "show":
            return await show(arguments: rest, git: git, console: console)
        case "restack":
            return await Restack.run(arguments: rest, git: git, console: console, hooks: hooks, now: now)
        case "sync":
            return await Sync.run(arguments: rest, git: git, console: console, now: now)
        case "new":
            return await newBranch(arguments: rest, git: git, console: console)
        case "route":
            return await Route.run(arguments: rest, git: git, console: console, hooks: hooks, now: now)
        case "-h", "--help", "help":
            console.out(usage)
            return 0
        default:
            console.err("ERROR: Unknown stack-bubble command: \(subcommand)")
            console.err(usage)
            return 1
        }
    }

    // MARK: - Shared

    /// `--stack`, then `bubbleflow.stack`, then the only manifest this
    /// repository has.
    static func resolveName(_ requested: String?, git: any GitRunning, console: any Console) async -> String? {
        if let requested { return validName(requested, console: console) ? requested : nil }
        let configured = await git.configValue("bubbleflow.stack", default: "")
        if !configured.isEmpty { return validName(configured, console: console) ? configured : nil }
        let local = await git.capture(["for-each-ref", "--format=%(refname)", "refs/stack/"], config: [:]).lines
        if local.count == 1, let only = local.first {
            return String(only.dropFirst("refs/stack/".count))
        }
        console.err(
            local.isEmpty
                ? "ERROR: No stack: pass --stack <name>, or run 'git stack-bubble init'."
                : "ERROR: Several stacks exist here: pass --stack <name>, or set bubbleflow.stack.")
        return nil
    }

    static func validName(_ name: String, console: any Console) -> Bool {
        if let complaint = BubbleFlowConfig.refComplaint(about: name, describedAs: "stack name") {
            console.err("ERROR: \(complaint)")
            return false
        }
        // One ref component: refs/stack/<name> must not grow a hierarchy, or a
        // stack named a/b would shadow one named a.
        if name.contains("/") || name.contains(" ") || name.contains("..") {
            console.err("ERROR: stack name must be a single ref component: \(name)")
            return false
        }
        return true
    }

    /// The remote a stack lives on: the one its local manifest names, or
    /// `origin` for a stack this clone has not fetched yet.
    static func remote(for name: String, git: any GitRunning) async -> String {
        let stack = StackGit(git: git)
        if let local = await stack.sha(StackManifest.ref(for: name)),
            case .success(let manifest) = await stack.readManifest(at: local)
        {
            return manifest.remote
        }
        return "origin"
    }

    /// Fetches the remote's manifest and returns it with the sha it was read
    /// at, the lease every later update is made against.
    static func fetchManifest(
        name: String, remote: String, git: any GitRunning, console: any Console
    ) async -> (manifest: StackManifest, sha: String)? {
        let stack = StackGit(git: git)
        guard let remoteSHA = await stack.remoteManifest(remote: remote, name: name) else {
            console.err("ERROR: Could not reach remote '\(remote)'.")
            return nil
        }
        guard let sha = remoteSHA else {
            console.err("ERROR: '\(remote)' has no stack named '\(name)'. Run 'git stack-bubble init' first.")
            return nil
        }
        guard await stack.fetchManifest(remote: remote, name: name) else {
            console.err("ERROR: Could not fetch \(StackManifest.ref(for: name)) from '\(remote)'.")
            return nil
        }
        switch await stack.readManifest(at: sha) {
        case .success(let manifest): return (manifest, sha)
        case .failure(let error):
            console.err("ERROR: \(StackManifest.ref(for: name)) is unreadable: \(error)")
            return nil
        }
    }

    /// Describes the bubbles on a stretch of the umbrella's first-parent line,
    /// refusing anything on it that is not a merge.
    static func discoverBubbles(
        _ merges: [String], remote: String, umbrella: String, base: String,
        git: any GitRunning, console: any Console
    ) async -> [StackManifest.Bubble]? {
        let stack = StackGit(git: git)
        var bubbles: [StackManifest.Bubble] = []
        for merge in merges {
            let parents = await stack.parents(of: merge)
            guard parents.count == 2 else {
                console.err("ERROR: \(merge) on '\(umbrella)' is not a bubble merge.")
                console.err("A stack's umbrella must be its base followed only by bubbles.")
                return nil
            }
            let subject = await stack.subject(of: merge)
            let candidates = await branches(pointingAt: parents[1], remote: remote, git: git)
                .filter { $0 != umbrella && $0 != base }
            let branch: String?
            if candidates.count == 1 {
                branch = candidates[0]
            } else {
                branch = nil
                if candidates.count > 1 {
                    console.out(
                        "Not tracking a branch for \(String(merge.prefix(12))): several point at it "
                            + "(\(candidates.joined(separator: ", "))).")
                }
            }
            let label = StackGit.label(fromSubject: subject) ?? branch ?? String(merge.prefix(12))
            bubbles.append(StackManifest.Bubble(merge: merge, label: label, branch: branch))
        }
        return bubbles
    }

    /// Short names of the local and remote-tracking branches at `commit`.
    static func branches(pointingAt commit: String, remote: String, git: any GitRunning) async -> [String] {
        let result = await git.capture(
            ["for-each-ref", "--format=%(refname)", "--points-at", commit, "refs/heads/", "refs/remotes/\(remote)/"],
            config: [:])
        var names: [String] = []
        for ref in result.lines {
            let name: String
            if ref.hasPrefix("refs/heads/") {
                name = String(ref.dropFirst("refs/heads/".count))
            } else {
                name = String(ref.dropFirst("refs/remotes/\(remote)/".count))
                if name == "HEAD" { continue }
            }
            if !names.contains(name) { names.append(name) }
        }
        return names.sorted()
    }

    // MARK: - init

    static func initialize(arguments: [String], git: any GitRunning, console: any Console) async -> Int32 {
        var name: String?
        var umbrella: String?
        var base: String?
        var remote = "origin"
        var pending: [String] = []
        var scanner = ArgumentScanner(arguments)
        while let argument = scanner.peek {
            switch argument {
            case "--umbrella", "--base", "--remote", "--pending":
                guard let value = scanner.takeValue(for: argument) else {
                    console.err("ERROR: \(argument) requires a value")
                    return 1
                }
                switch argument {
                case "--umbrella": umbrella = value
                case "--base": base = value
                case "--remote": remote = value
                default: pending.append(value)
                }
            case let other where other.hasPrefix("-"):
                console.err("Unknown argument: \(other)")
                return 1
            case let other:
                guard name == nil else {
                    console.err("ERROR: Only one stack name may be given")
                    return 1
                }
                name = other
                scanner.advance()
            }
        }
        func error(_ message: String) { console.err("ERROR: \(message)") }

        guard let name, validName(name, console: console) else {
            if name == nil { console.err(usage) }
            return 1
        }
        guard let umbrella else {
            error("--umbrella is required")
            return 1
        }
        let configuredBase = if let base { base } else { await BubbleFlowConfig(git: git).base() }
        guard let base = configuredBase else {
            error("No base: bubbleflow.base is not set. Pass --base <branch>.")
            return 1
        }
        for (value, what) in [(umbrella, "umbrella"), (base, "base"), (remote, "remote")] + pending.map({ ($0, "pending branch") }) {
            if let complaint = BubbleFlowConfig.refComplaint(about: value, describedAs: what) {
                error(complaint)
                return 1
            }
        }

        let stack = StackGit(git: git)
        console.out("Fetching \(remote)...")
        guard await git.passthrough(["fetch", "--quiet", "--end-of-options", remote], config: [:]) == 0 else {
            return 1
        }
        guard let existing = await stack.remoteManifest(remote: remote, name: name) else {
            error("Could not reach remote '\(remote)'.")
            return 1
        }
        if existing != nil {
            error("'\(remote)' already has a stack named '\(name)'.")
            return 1
        }

        guard let baseTip = await stack.sha("refs/remotes/\(remote)/\(base)") else {
            error("'\(remote)/\(base)' does not exist.")
            return 1
        }
        guard let umbrellaTip = await stack.sha("refs/remotes/\(remote)/\(umbrella)") else {
            error("'\(remote)/\(umbrella)' does not exist. Push the umbrella first.")
            return 1
        }
        if let local = await stack.sha("refs/heads/\(umbrella)"), local != umbrellaTip {
            error("Local '\(umbrella)' differs from '\(remote)/\(umbrella)'. Push or reset it first.")
            return 1
        }
        for branch in pending {
            if await stack.sha("refs/remotes/\(remote)/\(branch)") == nil,
                await stack.sha("refs/heads/\(branch)") == nil
            {
                error("Pending branch '\(branch)' does not exist.")
                return 1
            }
        }

        guard let forkPoint = await stack.mergeBase(baseTip, umbrellaTip),
            let chain = await stack.firstParentChain(from: forkPoint, to: umbrellaTip)
        else {
            error("Could not find where '\(umbrella)' forks from '\(remote)/\(base)'.")
            return 1
        }
        guard
            let bubbles = await discoverBubbles(
                chain, remote: remote, umbrella: umbrella, base: base, git: git, console: console)
        else { return 1 }

        let manifest = StackManifest(
            name: name, remote: remote, base: base, umbrella: umbrella, bubbles: bubbles, pending: pending)
        guard let commit = await stack.recordCommit(message: manifest.encoded(), parent: nil) else {
            error("Could not write the manifest commit.")
            return 1
        }
        let ref = StackManifest.ref(for: name)
        let pushed = await stack.push(remote: remote, updates: [.init(ref: ref, new: commit, expected: nil)])
        guard pushed.succeeded else {
            console.err(String(pushed.standardError.trimmedWhitespace()))
            error("Could not publish \(ref) to '\(remote)'.")
            return 1
        }
        _ = await git.capture(["update-ref", ref, commit], config: [:])
        if await git.configValue("bubbleflow.stack", default: "").isEmpty {
            _ = await git.capture(["config", "--local", "bubbleflow.stack", name], config: [:])
        }

        console.out("Created stack '\(name)' on \(remote) (\(ref)):")
        printManifest(manifest, console: console)
        return 0
    }

    // MARK: - new

    /// Starts a branch at the umbrella's tip and registers it as pending, so
    /// every clone's restack carries it along until it lands.
    ///
    /// The branch and the manifest are published in one atomic push: a pending
    /// branch that exists only here would be missing from every other clone's
    /// restack.
    static func newBranch(arguments: [String], git: any GitRunning, console: any Console) async -> Int32 {
        var requested: String?
        var branch: String?
        var scanner = ArgumentScanner(arguments)
        while let argument = scanner.peek {
            switch argument {
            case "--stack":
                guard let value = scanner.takeValue(for: argument) else {
                    console.err("ERROR: --stack requires a value")
                    return 1
                }
                requested = value
            case let other where other.hasPrefix("-"):
                console.err("Unknown argument: \(other)")
                return 1
            case let other:
                guard branch == nil else {
                    console.err("ERROR: Only one branch may be given")
                    return 1
                }
                branch = other
                scanner.advance()
            }
        }
        func error(_ message: String) { console.err("ERROR: \(message)") }
        guard let branch else {
            console.err(usage)
            return 1
        }
        guard await git.succeeds("check-ref-format", "--branch", branch), !branch.hasPrefix("-") else {
            error("'\(branch)' is not a valid branch name.")
            return 1
        }
        guard let name = await resolveName(requested, git: git, console: console) else { return 1 }
        let stack = StackGit(git: git)
        let remote = await remote(for: name, git: git)
        guard await git.passthrough(["fetch", "--quiet", "--end-of-options", remote], config: [:]) == 0 else {
            return 1
        }
        guard let (manifest, sha) = await fetchManifest(name: name, remote: remote, git: git, console: console)
        else { return 1 }
        if let lock = manifest.lock {
            error("'\(name)' is being restacked by \(lock.by). Start the branch once it is published.")
            return 1
        }
        if let bubble = manifest.bubbles.first(where: { $0.branch == branch }) {
            error("'\(branch)' is the sub-branch of bubble \(bubble.label).")
            return 1
        }
        let existingLocal = await stack.sha("refs/heads/\(branch)")
        let existingRemote = await stack.sha("refs/remotes/\(remote)/\(branch)")
        if existingLocal != nil || existingRemote != nil {
            error("'\(branch)' already exists.")
            return 1
        }
        guard let tip = await stack.sha("refs/remotes/\(remote)/\(manifest.umbrella)") else {
            error("'\(remote)/\(manifest.umbrella)' does not exist.")
            return 1
        }

        var next = manifest
        // Listed already when an earlier pending branch of that name was
        // deleted; restarting it must not add a second entry.
        if !next.pending.contains(branch) { next.pending.append(branch) }
        next.rewrites = []
        next.notes = ["pending \(branch) added by \(await stack.identity())"]
        guard let commit = await stack.recordCommit(message: next.encoded(), parent: sha) else {
            error("Could not write the manifest.")
            return 1
        }
        let ref = StackManifest.ref(for: name)
        let pushed = await stack.push(
            remote: remote,
            updates: [
                .init(ref: ref, new: commit, expected: sha),
                .init(ref: "refs/heads/\(branch)", new: tip, expected: nil),
            ])
        guard pushed.succeeded else {
            console.err(String(pushed.standardError.trimmedWhitespace()))
            error("Could not publish '\(branch)': the stack or the branch changed on '\(remote)'. Try again.")
            return 1
        }
        _ = await git.capture(["update-ref", ref, commit], config: [:])
        _ = await git.capture(["fetch", "--quiet", "--end-of-options", remote, branch], config: [:])

        let created = await git.capture(
            ["switch", "--quiet", "--create", branch, "--track", "\(remote)/\(branch)"], config: [:])
        guard created.succeeded else {
            console.err(String(created.standardError.trimmedWhitespace()))
            console.out("'\(branch)' is published and pending in '\(name)', but could not be checked out here.")
            return 1
        }
        console.out("Started '\(branch)' at the tip of \(manifest.umbrella), pending in '\(name)'.")
        console.out("Land it into \(manifest.umbrella) with 'git land' when it is ready; restack adopts it as a bubble.")
        return 0
    }

    // MARK: - show

    static func show(arguments: [String], git: any GitRunning, console: any Console) async -> Int32 {
        var requested: String?
        var scanner = ArgumentScanner(arguments)
        while let argument = scanner.peek {
            guard argument == "--stack", let value = scanner.takeValue(for: argument) else {
                console.err(argument == "--stack" ? "ERROR: --stack requires a value" : "Unknown argument: \(argument)")
                return 1
            }
            requested = value
        }
        guard let name = await resolveName(requested, git: git, console: console) else { return 1 }
        let remote = await remote(for: name, git: git)
        guard let (manifest, sha) = await fetchManifest(name: name, remote: remote, git: git, console: console)
        else { return 1 }
        console.out("Stack '\(name)' at \(String(sha.prefix(12))):")
        printManifest(manifest, console: console)
        return 0
    }

    static func printManifest(_ manifest: StackManifest, console: any Console) {
        console.out("  base      \(manifest.remote)/\(manifest.base)")
        console.out("  umbrella  \(manifest.umbrella)")
        console.out("  generation \(manifest.generation)")
        if let lock = manifest.lock {
            console.out("  LOCKED by \(lock.by) since \(backupTimestamp(lock.since))")
        }
        for (index, bubble) in manifest.bubbles.enumerated() {
            console.out(
                "  \(index + 1). \(bubble.label)  \(String(bubble.merge.prefix(12)))  \(bubble.branch ?? "(no branch)")")
        }
        for branch in manifest.pending { console.out("  pending   \(branch)") }
    }
}
