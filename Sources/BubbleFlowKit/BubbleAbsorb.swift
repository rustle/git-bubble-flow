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

public enum BubbleAbsorb {
    public static func run(
        arguments: [String],
        git: any GitRunning,
        console: any Console,
        searchPath: String = Sys.environment("PATH") ?? ""
    ) async -> Int32 {
        var explicitBase: String?
        var scanner = ArgumentScanner(arguments)

        // Only a leading --base is ours. Everything from the first other
        // argument onward is forwarded to git-absorb untouched.
        while let argument = scanner.peek, argument == "--base" {
            guard let value = scanner.takeValue(for: "--base") else {
                console.err("ERROR: --base requires a value")
                return 1
            }
            explicitBase = value
        }
        let forwarded = scanner.rest

        func error(_ message: String) { console.err("ERROR: \(message)") }

        guard Git.resolve(program: "git-absorb", path: searchPath) != nil else {
            error("git-absorb is not installed. Please install it first.")
            console.out("Installation instructions: https://github.com/tummychow/git-absorb")
            return 1
        }

        var base: String
        if let explicitBase {
            if let complaint = BubbleFlowConfig.refComplaint(about: explicitBase, describedAs: "base") {
                error(complaint)
                return 1
            }
            console.out("Using explicit base: \(explicitBase)")
            base = explicitBase
        } else {
            // The merge-base of HEAD and the configured base. Inside a bubble
            // that is the enclosing bubble, which is what absorb should stop
            // at — never rewrite below it.
            guard let candidate = await BubbleFlowConfig(git: git).base() else {
                error("Could not auto-detect an absorb base: bubbleflow.base is not set.")
                console.err("Pass one explicitly: git bubble-absorb --base <ref>")
                return 1
            }
            if let complaint = BubbleFlowConfig.refComplaint(about: candidate, describedAs: "bubbleflow.base") {
                error(complaint)
                return 1
            }
            guard await git.revisionExists(candidate) else {
                error("Configured base '\(candidate)' does not exist")
                return 1
            }
            let result = await git.capture(["merge-base", candidate, "HEAD"], config: [:])
            guard result.succeeded, !result.value.isEmpty else {
                error("Could not determine the merge base between \(candidate) and HEAD")
                return 1
            }
            console.out("Auto-detected base: \(candidate) (merge-base \(result.value))")
            // Absorb from the merge-base itself so commits below the fork point
            // (e.g. an earlier bubble on the base) are never rewritten, even if
            // the base branch has moved ahead of HEAD's fork.
            base = result.value
        }

        guard await git.revisionExists(base) else {
            error("Base branch '\(base)' does not exist")
            return 1
        }

        console.out("Running git absorb -r --base \(base) \(forwarded.joined(separator: " "))")

        // Nudge, never block, when git-absorb predates 0.9.0.
        let version = await git.capture(["absorb", "--version"], config: [:])
        let versionText = version.standardOutput + version.standardError
        if let regex = try? Regex("([0-9]+)\\.([0-9]+)"),
            let match = try? regex.firstMatch(in: versionText),
            let majorText = match[1].substring, let major = Int(majorText),
            let minorText = match[2].substring, let minor = Int(minorText)
        {
            if major == 0 && minor < 9 {
                console.out("Note: git-absorb \(major).\(minor) is older than 0.9.0. Consider upgrading:")
                console.out("  cargo install git-absorb --locked")
            }
        } else {
            console.out("Note: Could not determine git-absorb version")
        }

        return await git.passthrough(["absorb", "-r", "--base", base] + forwarded, config: [:])
    }
}
