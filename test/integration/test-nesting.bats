#!/usr/bin/env bats
# Nested bubbles: a bubble whose contents are themselves bubbles, mixed with
# logical commits. Everything here is built with the real `git land`, so the
# history under test is exactly what the tool produces.

setup() {
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
    git init -q
    git config user.name "Test User"
    git config user.email "test@example.com"
    bubble-flow-setup --base develop >/dev/null

    echo "seed" > README.md
    git add README.md
    git commit -qm "Initial commit"
    git checkout -qb develop
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

# Adds a line to shared.txt in its own logical commit and records the sha in
# the variable named by $2, so blame can be checked against it later.
logical_commit() {
    echo "$1" >> shared.txt
    git add shared.txt
    git commit -qm "Add line: $1"
    printf -v "$2" '%s' "$(git rev-parse HEAD)"
}


# Asserts that verify printed a passing bubble line at the given depth with
# the given label and subject. Anchored with grep rather than a [[ ]] glob
# because bash 3.2 (macOS) matches the check-mark glyph unreliably.
assert_bubble_line() { # <depth> <label> <subject>
    local indent label
    indent="$(printf '%*s' $(( $1 * 2 )) '')"
    label="${2//./\\.}"
    grep -qE "^${indent}[^ ]+ Bubble ${label}: [0-9a-f]{40} \(${3}\)\$" <<< "$output"
}

# outer (ABC-1) contains: a logical commit, bubble ABC-2, a logical commit,
# bubble ABC-3. ABC-3 in turn contains bubble ABC-4. Then outer lands on
# develop. Labels follow git's newest-first order, so ABC-3 is bubble 1.1
# (containing 1.1.1) and ABC-2 is bubble 1.2.
build_nested_history() {
    git checkout -qb ABC-1-outer develop
    logical_commit "outer-a" OUTER_A

    git checkout -qb ABC-2-inner ABC-1-outer
    logical_commit "inner-2" INNER_2
    git land --target ABC-1-outer -m "inner two" >/dev/null

    logical_commit "outer-b" OUTER_B

    git checkout -qb ABC-3-inner ABC-1-outer
    logical_commit "inner-3" INNER_3
    git checkout -qb ABC-4-deep ABC-3-inner
    logical_commit "deep-4" DEEP_4
    git land --target ABC-3-inner -m "deep four" >/dev/null
    git land --target ABC-1-outer -m "inner three" >/dev/null

    git land --target develop -m "outer one" >/dev/null
}

@test "nesting: land builds bubbles inside bubbles and verify walks every depth" {
    build_nested_history
    [ "$(git rev-parse --abbrev-ref HEAD)" = "develop" ]

    run git verify-bubble --base HEAD~1
    [ "$status" -eq 0 ]
    assert_bubble_line 0 1 "Merge ABC-1: outer one"
    assert_bubble_line 1 1.1 "Merge ABC-3: inner three"
    assert_bubble_line 2 1.1.1 "Merge ABC-4: deep four"
    assert_bubble_line 1 1.2 "Merge ABC-2: inner two"
    [[ "$output" == *"All validations passed for 4 bubble(s) across 1 first-parent commit(s)"* ]]
}

@test "nesting: logical commits mixed with nested bubbles are not violations under --strict" {
    build_nested_history
    # outer-a and outer-b sit between bubbles inside bubble 1. They are its
    # logical commits, not loose commits on the verified line.
    run git verify-bubble --strict --base HEAD~1
    [ "$status" -eq 0 ]
    [[ "$output" != *"Non-merge commit found"* ]]
    [[ "$output" == *"All validations passed for 4 bubble(s)"* ]]

    # Whereas the same commits directly on the verified range, outside any
    # bubble, are.
    git checkout -q develop
    logical_commit "loose" LOOSE
    run git verify-bubble --strict --base HEAD~2
    [ "$status" -eq 1 ]
    [[ "$output" == *"Non-merge commit found on first-parent line"* ]]
}

@test "nesting: every landed merge is empty at every depth" {
    build_nested_history
    # The invariant, checked directly rather than through the tool: each
    # merge's tree equals its second parent's tree.
    for merge in $(git rev-list --merges develop); do
        [ "$(git rev-parse "$merge^{tree}")" = "$(git rev-parse "$merge^2^{tree}")" ]
    done
}

@test "nesting: a non-empty merge two levels down fails with its depth label" {
    git checkout -qb ABC-1-outer develop
    logical_commit "outer-a" OUTER_A
    git checkout -qb ABC-3-inner ABC-1-outer
    logical_commit "inner-3" INNER_3
    git checkout -qb ABC-4-deep ABC-3-inner
    logical_commit "deep-4" DEEP_4
    # Move the inner branch so the deep merge has to resolve something,
    # then merge by hand: land would have refused the un-rebased branch.
    git checkout -q ABC-3-inner
    echo "other" > other.txt
    git add other.txt
    git commit -qm "Inner moves on"
    git merge -q --no-ff -m "Merge ABC-4: not empty" ABC-4-deep
    git checkout -q ABC-1-outer
    git merge -q --no-ff -m "Merge ABC-3: inner three" ABC-3-inner
    git checkout -q develop
    git merge -q --no-ff -m "Merge ABC-1: outer one" ABC-1-outer

    run git verify-bubble --base HEAD~1
    [ "$status" -eq 1 ]
    [[ "$output" == *"Non-empty bubble 1.1.1"* ]]
    [[ "$output" == *"1 invalid bubble(s)"* ]]

    # land itself refuses to create such a bubble: the deep branch is not
    # rebased onto its target, so it is not an ancestor.
    git checkout -q ABC-4-deep
    run git land --target ABC-3-inner -m "should refuse"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not an ancestor"* ]]
}

@test "nesting: blame attributes every line to its logical commit, never a merge" {
    build_nested_history
    git checkout -q develop

    # shared.txt has one line per logical commit, in landing order.
    [ "$(cat shared.txt)" = "$(printf 'outer-a\ninner-2\nouter-b\ninner-3\ndeep-4')" ]

    run git blame -l -s -- shared.txt
    [ "$status" -eq 0 ]
    expected=("$OUTER_A" "$INNER_2" "$OUTER_B" "$INNER_3" "$DEEP_4")
    i=0
    while IFS= read -r line; do
        [ "${line%% *}" = "${expected[$i]}" ]
        i=$((i + 1))
    done <<< "$output"
    [ "$i" -eq 5 ]

    # None of those shas is a merge commit.
    for sha in "${expected[@]}"; do
        [ "$(git rev-list --no-walk --merges "$sha" | wc -l)" -eq 0 ]
    done
}

@test "nesting: the first-parent view collapses to one merge per bubble at each level" {
    build_nested_history

    # From develop: one step, the outer bubble.
    run git log --first-parent --format=%s HEAD~1..develop
    [ "$output" = "Merge ABC-1: outer one" ]

    # Inside the outer bubble: its logical commits and nested bubbles, in order.
    run git log --first-parent --format=%s "develop^1..develop^2"
    [ "$(printf '%s' "$output")" = "$(printf 'Merge ABC-3: inner three\nAdd line: outer-b\nMerge ABC-2: inner two\nAdd line: outer-a')" ]

    # Inside bubble 1.2: one logical commit and the deep bubble.
    inner_three="$(git rev-list --first-parent --grep='inner three' -n1 develop^2)"
    run git log --first-parent --format=%s "$inner_three^1..$inner_three^2"
    [ "$(printf '%s' "$output")" = "$(printf 'Merge ABC-4: deep four\nAdd line: inner-3')" ]

    # --first-parent bisect sees only the outer bubbles, so every step is a
    # tree that was validated before landing.
    run git rev-list --first-parent --count HEAD~1..develop
    [ "$output" -eq 1 ]
    run git rev-list --count HEAD~1..develop
    [ "$output" -eq 9 ]
}

@test "nesting: rebase-bubble carries the whole nested structure onto a moved base" {
    # Build the nested feature but do not land it. Then move develop.
    git checkout -qb ABC-1-outer develop
    logical_commit "outer-a" OUTER_A
    git checkout -qb ABC-2-inner ABC-1-outer
    logical_commit "inner-2" INNER_2
    git checkout -qb ABC-4-deep ABC-2-inner
    logical_commit "deep-4" DEEP_4
    git land --target ABC-2-inner -m "deep four" >/dev/null
    git land --target ABC-1-outer -m "inner two" >/dev/null
    logical_commit "outer-b" OUTER_B

    git checkout -q develop
    echo "moved" > moved.txt
    git add moved.txt
    git commit -qm "develop moves on"
    develop_tip="$(git rev-parse develop)"

    git checkout -q ABC-1-outer
    run git rebase-bubble --onto develop
    [ "$status" -eq 0 ]
    assert_bubble_line 0 1 "Merge ABC-2: inner two"
    assert_bubble_line 1 1.1 "Merge ABC-4: deep four"
    [[ "$output" == *"Bubble rebase completed successfully"* ]]

    # The structure now sits on the new develop tip, and --update-refs moved
    # the nested branches along with it.
    git merge-base --is-ancestor "$develop_tip" ABC-1-outer
    git merge-base --is-ancestor "$develop_tip" ABC-2-inner
    git merge-base --is-ancestor "$develop_tip" ABC-4-deep
    git merge-base --is-ancestor ABC-2-inner ABC-1-outer
    git merge-base --is-ancestor ABC-4-deep ABC-2-inner

    # Every merge is still empty, and the file content survived intact.
    run git verify-bubble --base develop ABC-1-outer
    [ "$status" -eq 0 ]
    [[ "$output" == *"All validations passed for 2 bubble(s)"* ]]
    [ "$(cat shared.txt)" = "$(printf 'outer-a\ninner-2\ndeep-4\nouter-b')" ]
    [ -f moved.txt ]

    # And it can now land, verifying the nested contents on the way.
    run git land --target develop -m "outer one"
    [ "$status" -eq 0 ]
    assert_bubble_line 0 1 "Merge ABC-1: outer one"
    assert_bubble_line 1 1.1 "Merge ABC-2: inner two"
    assert_bubble_line 2 1.1.1 "Merge ABC-4: deep four"
    [[ "$output" == *"Bubble successfully landed"* ]]
}
