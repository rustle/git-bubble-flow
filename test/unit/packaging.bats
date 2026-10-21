#!/usr/bin/env bats
# The packaging shape: one multi-call binary reached through per-subcommand
# symlinks. These guard the contract the Homebrew formula relies on.

@test "every shim resolves to the same binary" {
    for shim in git-verify-bubble git-land-bubble git-rebase-bubble git-bubble-absorb git-stack-bubble bubble-flow-setup; do
        run command -v "$shim"
        [ "$status" -eq 0 ]
        [ "$(readlink "$BUBBLE_FLOW_SHIMS/$shim")" = "$BUBBLE_FLOW_BINARY" ]
    done
}

@test "--version reports a version" {
    run "$BUBBLE_FLOW_BINARY" --version
    [ "$status" -eq 0 ]
    [[ "$output" == git-bubble-flow\ * ]]
}

@test "--help lists every command" {
    run "$BUBBLE_FLOW_BINARY" --help
    [ "$status" -eq 0 ]
    for command in verify land rebase absorb stack setup; do
        [[ "$output" == *"$command"* ]]
    done
}

@test "no arguments exits non-zero with usage" {
    run "$BUBBLE_FLOW_BINARY"
    [ "$status" -eq 1 ]
    [[ "$output" == *"USAGE"* ]]
}

@test "unknown command is rejected" {
    run "$BUBBLE_FLOW_BINARY" definitely-not-a-command
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown command"* ]]
}

@test "setup refuses to run outside a git repository" {
    outside="$(mktemp -d)"
    cd "$outside"
    run bubble-flow-setup
    [ "$status" -eq 1 ]
    [[ "$output" == *"Not inside a Git repository"* ]]
    cd /
    rm -rf "$outside"
}

@test "the binary links no Swift runtime beyond the platform's own" {
    # A Homebrew install must not drag a Swift toolchain along. On Linux the
    # static SDK build has no dynamic Swift at all. On macOS the runtime lives
    # in the OS, under /usr/lib/swift.
    #
    # Debug builds are exempt: SwiftPM links dependency modules dynamically and
    # adds @rpath back-deployment shims (libswiftCompatibilitySpan, for Span)
    # that a release build resolves statically. Run with CONFIGURATION=release,
    # or against a `make static` binary, to assert the shipped shape.
    # SwiftPM names the binary's parent directory after the configuration:
    # .build/<triple>/debug/ through Swift 6.3, and .build/out/Products/Debug/
    # under the build system that arrived with Swift 6.4. The container pins
    # 6.3.3 but the macOS lane builds with whatever toolchain the host
    # resolves, so both spellings are live. Only that one segment is inspected. Matching the
    # whole path let a checkout under a directory named Debug exempt a release
    # or static binary from the assertion below.
    configuration="$(basename "$(dirname "$BUBBLE_FLOW_BINARY")")"
    if [[ "$configuration" == debug || "$configuration" == Debug ]]; then
        # On macOS a release build is already the shipped shape. On Linux only
        # the static SDK build is, so CONFIGURATION=release is not enough there.
        skip "debug build. Use CONFIGURATION=release (macOS) or 'make static' (Linux)"
    fi

    if command -v ldd >/dev/null 2>&1; then
        run ldd "$BUBBLE_FLOW_BINARY"
        # A fully static binary makes ldd either say so or refuse outright
        # ("not a dynamic executable").
        [[ "$output" == *"statically linked"* || "$output" == *"not a dynamic executable"* ]]
        [[ "$output" != *"libswift"* ]]
    elif command -v otool >/dev/null 2>&1; then
        run otool -L "$BUBBLE_FLOW_BINARY"
        [ "$status" -eq 0 ]
        # Nothing may be resolved through @rpath, and every Swift dylib must be
        # the OS copy rather than a toolchain path.
        [[ "$output" != *"@rpath"* ]]
        while read -r line; do
            case "$line" in
                *libswift*)
                    [[ "$line" == *"/usr/lib/swift/"* ]] || return 1
                    ;;
            esac
        done <<< "$output"
    else
        skip "no ldd or otool available"
    fi
}

@test "setup writes repository config even when a global value shadows it" {
    # `git config --get` reads global and system too, so probing without
    # --local let a user's global rerere.enabled=false suppress the repo write.
    fakehome="$(mktemp -d)"
    HOME="$fakehome" git config --global rerere.enabled false

    repo="$(mktemp -d)"
    cd "$repo"
    git init -q .
    git config user.name "Test User"
    git config user.email "test@example.com"

    run env HOME="$fakehome" bubble-flow-setup
    [ "$status" -eq 0 ]
    [ "$(git config --local --get rerere.enabled)" = "true" ]

    cd /
    rm -rf "$repo" "$fakehome"
}
