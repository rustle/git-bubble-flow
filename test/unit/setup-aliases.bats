#!/usr/bin/env bats
# How setup wires `git <command>` up to the binary.
#
# The contract is that no absolute path is ever written into a repository's
# config. Three of the four commands are found by git's own PATH-based
# subcommand discovery, and `land` gets the one alias, because its shim is
# named git-land-bubble rather than git-land.

seed_repo() {
    repo="$(mktemp -d)"
    cd "$repo"
    git init -q .
    git config user.name "Test User"
    git config user.email "test@example.com"
    git commit -q --allow-empty -m "Initial commit"
}

@test "setup writes one alias, and it is a subcommand name rather than a path" {
    seed_repo
    bubble-flow-setup >/dev/null

    [ "$(git config --local --get alias.land)" = "land-bubble" ]

    # The other three would only shadow the shims git already finds.
    for key in alias.verify-bubble alias.rebase-bubble alias.bubble-absorb; do
        run git config --local --get "$key"
        [ "$status" -ne 0 ]
    done

    cd /
    rm -rf "$repo"
}

@test "the three unaliased commands are found on PATH with no config at all" {
    seed_repo
    # Deliberately no setup: this is git's external subcommand discovery only.
    run git verify-bubble --base HEAD HEAD
    [ "$status" -eq 0 ]
    [[ "$output" == *"No bubbles found to verify"* ]]

    cd /
    rm -rf "$repo"
}

@test "every command survives the install directory being replaced" {
    # The regression this whole approach exists for. A Homebrew install puts a
    # stable symlink farm in front of a versioned directory, and `brew upgrade`
    # deletes the version that setup ran from. Anything setup wrote that named
    # that directory would now be dangling.
    root="$(mktemp -d)"
    versioned="$root/versions/0.1.0/bin"
    stable="$root/bin"
    mkdir -p "$versioned" "$stable"
    cp "$BUBBLE_FLOW_BINARY" "$versioned/git-bubble-flow"
    shims="git-verify-bubble git-land-bubble git-rebase-bubble git-bubble-absorb bubble-flow-setup"
    for name in $shims; do
        ln -s git-bubble-flow "$versioned/$name"
        ln -s "$versioned/$name" "$stable/$name"
    done
    ln -s "$versioned/git-bubble-flow" "$stable/git-bubble-flow"

    seed_repo
    run env PATH="$stable:$PATH" bubble-flow-setup
    [ "$status" -eq 0 ]

    # Upgrade: a new version replaces the old one, and the farm re-points.
    mv "$root/versions/0.1.0" "$root/versions/0.2.0"
    rm -f "$stable"/*
    for name in $shims git-bubble-flow; do
        ln -s "$root/versions/0.2.0/bin/$name" "$stable/$name"
    done

    export PATH="$stable:$PATH"

    run git verify-bubble --base HEAD HEAD
    [ "$status" -eq 0 ]
    [[ "$output" == *"No bubbles found to verify"* ]]

    # Reaching our own argument error proves the alias dispatched into the
    # binary rather than dying in git as an unknown command.
    run git land --target
    [ "$status" -eq 1 ]
    [[ "$output" == *"--target requires a value"* ]]

    run git rebase-bubble --onto
    [ "$status" -eq 1 ]
    [[ "$output" == *"--onto requires a value"* ]]

    run git bubble-absorb --base
    [ "$status" -eq 1 ]
    [[ "$output" == *"--base requires a value"* ]]

    cd /
    rm -rf "$repo" "$root"
}

@test "setup warns when the shims are not on PATH but still configures the repo" {
    seed_repo
    run env PATH="/usr/bin:/bin" "$BUBBLE_FLOW_SHIMS/bubble-flow-setup"
    [ "$status" -eq 0 ]
    [[ "$output" == *"git-land-bubble"* ]]
    [ "$(git config --local --get alias.land)" = "land-bubble" ]

    cd /
    rm -rf "$repo"
}

@test "re-running setup is idempotent" {
    seed_repo
    bubble-flow-setup >/dev/null
    run bubble-flow-setup
    [ "$status" -eq 0 ]
    [ "$(git config --local --get alias.land)" = "land-bubble" ]
    [ "$(git config --local --get alias.land | wc -l)" -eq 1 ]

    cd /
    rm -rf "$repo"
}
