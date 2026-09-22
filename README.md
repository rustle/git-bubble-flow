# git-bubble-flow

Tooling for a semi-linear git history where feature branches merge into long-lived branches as **empty bubbles**.

## Workflow

Assuming you have a repository with long-lived branches (`main`, `develop`, etc) and short-lived feature branches.

To land a feature you:

1. Curate the feature branch into logical commits.
2. Rebase the branch onto the tip of the target branch yourself, so the branch is exactly what will be integrated, and let CI validate that.
3. Merge it with `git merge --no-ff`, producing a merge commit whose tree is byte-identical to its second parent's tree.

Step 3 creates our eponymous bubble. The merge is "empty" because it introduces nothing beyond its second parent: the tree at the merge commit is the tree CI already signed off on. If the merge had to resolve anything, the branch was not rebased first, and the merge result is a tree nobody ever tested.

The gives us two different views of the same history:

- **First-parent line.** Following only first parents from the target's tip gives a straight chain of merge commits, each one an integration point whose tree was validated before it landed. `git bisect --first-parent` and `git log --first-parent` are therefore meaningful — every step is a state the project actually passed its tests in.
- **Full history.** The second parents still hold the individual, curated commits, so `git blame` and `git log` stay granular. Nothing is squashed away.

### Rebase bubble

If you're working on a long lived feature branch sub-feature branches can land into your main feature branch as bubbles, so the feature accumulates its own chain of bubbles, and eventually the feature itself lands into your base branch as an outer bubble.

We can expect the long lived feature branch's base to keep moving. With nesting you need to rebase a feature branch that contains merge commits, which needs `--rebase-merges --update-refs` so the bubble structure and the sub-branch refs survive, plus `rerere` so the same conflicts are not resolved by hand every time. `rebase-bubble` is that operation, wrapped with a backup tag beforehand and a verification pass after.

## Install

macOS, via Homebrew. The formula builds from source and installs a single binary plus its symlinks. A release build links only system dylibs from `/usr/lib/swift` and `/usr/lib`, so nothing has to be shipped or installed alongside it — Swift's runtime is part of the OS (macOS 10.14.4+).

```sh
brew install rustle/tap/git-bubble-flow
```

The formula lives in `packaging/homebrew/` and points at the tagged release tarball. To install from a checkout instead, build and link it directly:

```sh
make install                  # into /usr/local/bin
make install PREFIX=~/.local  # or anywhere on PATH
```

Linux: download the static binary for your architecture from the releases page, install it, and create the multi-call symlinks git uses to discover the subcommands. The binary links nothing — not even libc — so it runs on any distribution.

```sh
chmod +x git-bubble-flow-linux-$(uname -m)
sudo install git-bubble-flow-linux-$(uname -m) /usr/local/bin/git-bubble-flow
cd /usr/local/bin && for s in git-verify-bubble git-land-bubble \
    git-rebase-bubble git-bubble-absorb bubble-flow-setup; do
  sudo ln -sf git-bubble-flow "$s"
done
```

`bubble-absorb` additionally needs [`git-absorb`](https://github.com/tummychow/git-absorb) on `PATH`. The Homebrew formula depends on it.

Then, in each repository you want to use it in:

```sh
bubble-flow-setup --base develop
```

That writes the `bubbleflow.*` keys into the repository's own config, plus a single `git land` alias. It also sets `pull.ff = only` and enables `rerere` for that repository, scoped locally rather than globally so it does not change how `git pull` behaves everywhere else.

`git verify-bubble`, `git rebase-bubble` and `git bubble-absorb` need no alias at all: the installed symlinks are named `git-verify-bubble` and so on, which is how git discovers an external subcommand. Only `land` needs one, because its symlink is `git-land-bubble`.

No branch name is built in. `--base` names the branch bubbles land on, are verified against, and are rebased onto. Without it, `setup` uses the branch `HEAD` is on. A repository that never ran `setup` has no base at all, and every command that needs one says so and asks for `--base`, `--onto` or `--target` rather than guessing.

## Usage

A feature from branch to landed:

```sh
git switch -c ABC-123-neato-thingy develop
# ... work, commit ...

# Fold fixups into the commits they belong to. The base is the merge-base of
# HEAD and bubbleflow.base, so nothing below the fork point is ever rewritten.
git bubble-absorb

# Rebase onto the target yourself. This is the step that makes the bubble
# empty. The tool will not do it for you.
git fetch origin
git rebase origin/develop
git push --force-with-lease

# ... CI validates this exact tree ...

git land -m "Super neato thingy doodle."
```

`git land` checks that the working tree is clean, that the target exists and is already an ancestor of your branch (so an un-rebased branch is refused, not merged), takes a subject label from the branch name, tags the target's pre-merge tip as `backup/land-<branch>-<timestamp>`, merges with `--no-ff` and a `Merge <LABEL>: <summary>` subject, then verifies that the merge it just made is in fact a bubble — all the way down, if the branch contained bubbles of its own. The label is the ticket when the branch name carries one and the branch name itself when it does not, so a repository with no ticket convention is not forced into one. `--strict` requires a ticket, which is what makes the resulting subject satisfy `verify --strict`. If verification fails it resets the target back to its pre-merge commit and leaves your branch untouched. A branch that adds no commits is refused outright rather than reported as landed. It never pushes — it prints the `git push` command and leaves the decision to you.

If the target is already checked out in another worktree, the merge happens *there* rather than here, and you stay on your own branch — git allows a branch in at most one worktree, so this is the only way to land from a sub-feature branch into a feature branch you have open elsewhere. That worktree has to be in a fit state to receive it: land refuses if it is dirty, if an operation such as a rebase or an unresolved merge is in progress there, or if it holds an untracked file the merge would have to overwrite. Every one of those is checked before the backup tag is written, so a refusal changes nothing at all.

It will not rebase for you, deliberately. A rebase can need real conflict resolution, and resolving conflicts on your behalf would produce a tree nobody reviewed and CI never saw — which is the exact failure the empty bubble exists to rule out. Refusing an un-rebased branch keeps the decision where the judgement is.

Checking history, for example in CI:

```sh
# A pull request: the branch against the target it will land on. A plain
# feature branch has no bubbles yet and passes trivially. One that has landed
# sub-features of its own has them checked.
git verify-bubble --base origin/develop
```

```sh
# Cutting a release: everything landed on develop since the last merge to main.
git verify-bubble --base origin/main origin/develop --strict
```

`verify` walks the first-parent line from the merge base to the given ref. Every merge on that line must be a bubble: its tree must equal its second parent's tree. It then walks the bubble's contents — the commits its second parent reaches that its first parent does not — and applies the same rule to any merge it finds there, so nested bubbles are checked at every depth and reported as `Bubble 1`, `Bubble 1.1`, and so on. Non-empty merges anywhere and octopus merges fail. `--strict` additionally fails on merge subjects that do not match `Merge <TICKET>: ` and on non-merge commits sitting directly on the verified range, outside any bubble. Inside a bubble, non-merge commits are simply its logical commits and are never a violation.

**Always pass an explicit `--base` in CI.** With no `--base`, `verify` uses `bubbleflow.base`, which is normally the target branch itself. Running it *on* that branch therefore compares the branch with itself, giving an empty range and a pass that checked nothing:

```sh
git checkout develop
git verify-bubble                 # "No bubbles found to verify", exit 0 — checked nothing
git verify-bubble --base v1.4.0   # a real range: everything since that tag
```

This is by design — the default suits checking a feature branch against its target — but it makes the no-argument form useless as a gate. A run that verified nothing says so explicitly ("No bubbles found to verify") rather than claiming a count, so check for that string if a CI job must never pass vacuously.

Moving a bubble branch after its base advanced:

```sh
git rebase-bubble --onto origin/develop                       # the current branch
git rebase-bubble --bubble feature/neato-thingy --onto origin/develop
```

This tags the branch first, then rebases with `--rebase-merges --update-refs` and `rerere`, then verifies the result. On a verification failure it deliberately does **not** reset — the rebase may have taken real conflict resolution work — and instead prints the reset command for you to run.

## Commands

One multi-call binary, `git-bubble-flow`, with five subcommands. Each is also reachable through a symlink named for its git subcommand, which is how `git verify-bubble` resolves: git looks for a `git-verify-bubble` executable on `PATH`.

Nothing written into a repository names a path. The one alias `setup` writes is `land = land-bubble`, which sends git looking for `git-land-bubble` on `PATH` exactly as it would for any other subcommand. That is deliberate: an absolute path would name the versioned directory a `brew upgrade` deletes, and it would also travel to machines it is not true on when a config is synced or copied.

| Command | Symlink / alias | What it does |
|---|---|---|
| `verify [<ref>] [--base <ref>] [--strict]` | `git-verify-bubble` / `git verify-bubble` | Walks the first-parent line from the merge base of `--base` and `<ref>`, recursing into each bubble's contents, failing on non-empty bubbles and octopus merges at any depth. `--strict` also fails on subjects that are not `Merge <TICKET>: …` and on non-merge commits sitting directly on the verified range, outside any bubble. |
| `land [--target <branch>] [-m <summary>] [--strict]` | `git-land-bubble` / `git land` | Clean-tree and ancestry checks, tags the target's pre-merge tip, `--no-ff` merge, verifies exactly the new bubble, resets the target on failure. Merges in whichever worktree already holds the target, leaving you on your own branch. Never pushes, never rebases for you. The subject is `Merge <TICKET>: …` when the branch name carries a ticket and `Merge <branch>: …` when it does not. `--strict` requires the ticket. |
| `rebase [--bubble <branch>] [--onto <base>]` | `git-rebase-bubble` / `git rebase-bubble` | `rebase --rebase-merges --update-refs` with rerere on the current branch (or `--bubble`), tagging first and verifying after. On verification failure it does **not** reset — it prints the reset command. |
| `absorb [--base <ref>] [<git-absorb args>…]` | `git-bubble-absorb` / `git bubble-absorb` | Runs `git-absorb` down to the merge-base of `HEAD` and `bubbleflow.base`. Inside a nested bubble that is the enclosing bubble, so it never rewrites below it. |
| `setup [--base <branch>]` | `bubble-flow-setup` | Writes the `bubbleflow.*` keys and the `git land` alias into the current repository. The base defaults to the branch `HEAD` is on. |

Also: `git-bubble-flow --help`, `git-bubble-flow --version`.

## Configuration

All keys are read from the repository's git config.

| Key | Written by `setup --base develop` | Used by |
|---|---|---|
| `bubbleflow.targets` | `develop` | `land`'s default target, a space-separated list of which the first word wins |
| `bubbleflow.base` | `develop` | `verify`'s default base, `rebase`'s default `--onto`, and `absorb`'s base |
| `bubbleflow.ticketPattern` | `[A-Z]+-[0-9]+` | ticket extraction in `land`, and the `--strict` subject check in `verify` |

There is no built-in branch name. A repository that never ran `setup` has no base or target, and `verify`, `rebase`, `absorb` and `land` refuse to run until one is configured or passed on the command line. The ticket pattern does fall back, to `[A-Z]+-[0-9]+`, and that fallback is shared by `land` and `verify --strict` on purpose, so the two can never disagree about what counts as a ticket. Whether a ticket is *required* is opt-in on both sides: `land --strict` refuses a branch without one, and `verify --strict` refuses a subject without one. Use both or neither.

## Development

Two lanes, because the macOS artifact users install is not the Linux artifact the container builds. CI runs both.

The Linux lane runs in a container and needs only Docker on the host:

```sh
make image        # build the dev/CI image
make build        # debug build in the container
make test         # swift unit tests, in the container
make conformance  # bats suite against the built binary
make check        # both
make static       # fully-static Linux binaries for both arches -> dist/
make shell        # interactive shell in the dev image
make clean        # remove build output
```

The macOS lane builds and tests natively, so it needs Xcode or a Swift toolchain on the host, plus `bats` and `git-absorb` (both available through Homebrew) for the conformance suite:

```sh
make macos-build  # release build on the host
make macos-check  # swift test + ./test/run-tests.sh on the host
```

### What the container carries

- **Swift 6.3.3**, pinned in `docker/Dockerfile`. The macOS lane builds with whatever toolchain the host resolves, so the two lanes are not guaranteed to share a compiler. CI checks both.
- **The Static Linux SDK**, which cross-compiles to fully-static musl binaries for x86_64 and aarch64. It is pinned by sha256 in `docker/Dockerfile` because swift.org publishes no `.sha256` sidecar for the artifact bundle.
- **git-absorb 0.9.0**, built from source: upstream publishes no aarch64-Linux binary and Ubuntu packages only 0.6.11.
- **bats**, for the conformance suite.

### Testing

Two layers, deliberately different in kind.

`Tests/` holds swift-testing unit tests for the pure logic — argument grammar, config fallbacks, base resolution, multi-call dispatch — against a stub implementation of the git interface, so they need no repository on disk.

`test/` holds a bats suite that runs against the real, built binary through the same install-shaped symlinks a real installation creates (see `test/run-tests.sh`), driving throwaway git repositories. That is the conformance gate: it exercises the shape users actually get, including the symlink dispatch and the exact stdout/stderr strings, which CI and other scripts parse.

## Design notes

**Why shell out to git rather than link libgit2.** Three of the four working commands are porcelain-shaped: `rebase --rebase-merges --update-refs`, `rerere`, and `git-absorb` have no libgit2 equivalent at all. Only `verify` is pure plumbing — revwalk, tree OIDs, merge-base — and could be done in-process. Shelling out also means the tools honor the user's git config, hooks, credential helpers and worktree layout for free. All git access goes through a `GitRunning` protocol, so a libgit2-backed `verify` can be dropped in later without touching command logic, and so the unit tests can substitute a stub.

**Why no Foundation.** Process spawning uses [swiftlang/swift-subprocess](https://github.com/swiftlang/swift-subprocess) 1.0.0, with its `SubprocessFoundation` trait disabled — that trait is on by default and would pull Foundation in. Nothing in the shipped code imports Foundation.

Sizes, measured on aarch64 musl with `-Osize --gc-sections --strip-all`:

| Contents | Size |
|---|---|
| bare stdlib | 6.1 MB |
| stdlib + runtime `Regex` + string processing, no Foundation | 7.6 MB |
| the same, plus an unused `import Foundation` | 7.6 MB |
| plus Foundation's `Process`/`Pipe`/`FileHandle`/`FileManager`/`Bundle` | 53 MB |
| this tool, as shipped (incl. swift-subprocess) | 9.0 MB |

`import Foundation` on its own is free — `--gc-sections` strips what is never called. The 45 MB is `Process` and friends specifically, which is why they are the thing being avoided. macOS is unaffected either way: the release binary is about 1.5 MB there, because it links only the OS's own Swift runtime and the two package dependencies.

String processing largely lives in stdlib: `String`, Unicode-correct grapheme handling, `split`, `replacing` and `trimmingPrefix`.

What *is* gone, and is the likely reason to reach back:

- **`folding(options:locale:)`** and locale-aware collation. These need `FoundationInternationalization` (ICU), not merely Foundation, so re-adding them will not be free — measure before committing to it.
- **`Date`/`Calendar`/`TimeZone`.** Formatting the current local time is covered, which is all the backup tags need. Calendar arithmetic, lookup by timezone identifier, and ISO 8601 parsing are not.
- `String(format:)`, `DateFormatter`, and non-UTF-8 text encodings.

**Building from a Homebrew formula.** The formula builds from source, and Homebrew builds must not reach the network for dependencies. So rather than letting SwiftPM resolve them, the formula declares swift-subprocess and swift-system as `resource` stanzas and rewrites the package manifest to path-based dependencies before building — verified to build with no network at all.

**Safety properties, inherited by every command.** Never push. Always tag before anything that rewrites or advances a ref, so recovery is a `git reset --hard` to a named tag. Never rebase on the user's behalf — `land` refuses an un-rebased branch rather than silently fixing it, because the rebase is the step that makes the bubble empty and it is the user's judgment call.

## License

Apache License 2.0. See `LICENSE`.
