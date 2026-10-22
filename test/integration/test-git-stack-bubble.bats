#!/usr/bin/env bats
# Stacks: an umbrella branch made of the base plus a chain of bubbles, each
# landed from a sub-branch that forks from the previous bubble's merge. Every
# test publishes to a bare remote, because the manifest, the lock and the
# restack's leases all live there.

setup() {
    TEST_DIR=$(mktemp -d)
    git init -q --bare -b main "$TEST_DIR/remote.git"
    git clone -q "$TEST_DIR/remote.git" "$TEST_DIR/work" 2>/dev/null
    cd "$TEST_DIR/work"
    configure_clone

    echo "seed" > README.md
    git add README.md
    git commit -qm "Initial commit"
    git checkout -qb develop
    git push -q origin develop

    build_stack
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

configure_clone() {
    git config user.name "Test User"
    git config user.email "test@example.com"
    bubble-flow-setup --base develop >/dev/null
}

# feature carries three bubbles, ABC-1..ABC-3, each sub-branch forking from
# the previous bubble's merge. Each writes its own file, and ABC-2 also edits
# README.md so that a change to README.md on develop conflicts with it.
build_stack() {
    git checkout -qb feature develop
    local n
    for n in 1 2 3; do
        git checkout -qb "ABC-$n-part" feature
        echo "part $n" > "part$n.txt"
        if [ "$n" = 2 ]; then echo "edited by ABC-2" > README.md; fi
        git add -A
        git commit -qm "Part $n"
        git land --target feature -m "part $n" >/dev/null
    done
    git checkout -q develop
    git push -q origin feature ABC-1-part ABC-2-part ABC-3-part
}

worktree_path() {
    echo "$(git rev-parse --path-format=absolute --git-common-dir)/stack-bubble/s"
}

advance_develop() { # <file> <content>
    git checkout -q develop
    echo "$2" > "$1"
    git add "$1"
    git commit -qm "develop: $1"
    git push -q origin develop
}

first_parent_subjects() {
    git log --format=%s --first-parent "origin/develop..$1"
}

@test "init publishes a manifest naming each bubble and its sub-branch" {
    run git stack-bubble init s --umbrella feature
    [ "$status" -eq 0 ]
    [[ "$output" == *"1. ABC-1"*"ABC-1-part"* ]]
    [[ "$output" == *"3. ABC-3"*"ABC-3-part"* ]]

    [ "$(git ls-remote origin refs/stack/s | cut -f1)" = "$(git rev-parse refs/stack/s)" ]
    [ "$(git config bubbleflow.stack)" = "s" ]

    run git stack-bubble show
    [ "$status" -eq 0 ]
    [[ "$output" == *"generation 0"* ]]
}

@test "init refuses a stack name that already exists on the remote" {
    git stack-bubble init s --umbrella feature >/dev/null
    run git stack-bubble init s --umbrella feature
    [ "$status" -eq 1 ]
    [[ "$output" == *"already has a stack named 's'"* ]]
}

@test "restack rebuilds every bubble on the moved base and publishes atomically" {
    git stack-bubble init s --umbrella feature >/dev/null
    before="$(first_parent_subjects origin/feature)"
    old_feature="$(git rev-parse feature)"
    advance_develop other.txt "new on develop"

    run git stack-bubble restack
    [ "$status" -eq 0 ]
    [[ "$output" == *"generation 1"* ]]

    git fetch -q origin
    # The umbrella now sits on the new develop, every bubble intact.
    git merge-base --is-ancestor origin/develop origin/feature
    run git verify-bubble --base origin/develop origin/feature
    [ "$status" -eq 0 ]
    [ "$(first_parent_subjects origin/feature)" = "$before" ]

    # Each sub-branch is its rebuilt bubble's second parent, on the remote
    # and locally.
    for n in 1 2 3; do
        [ "$(git rev-parse "origin/ABC-$n-part")" = "$(git rev-parse "ABC-$n-part")" ]
    done
    [ "$(git rev-parse origin/feature^2)" = "$(git rev-parse ABC-3-part)" ]
    [ "$(git rev-parse feature)" = "$(git rev-parse origin/feature)" ]

    # The local positions were backed up, and the manifest records the rewrite.
    [ "$(git rev-parse "$(git tag -l 'backup/restack-s-*/feature')")" = "$old_feature" ]
    git log -1 --format=%B refs/stack/s | grep -q "^rewrite $old_feature $(git rev-parse feature)$"
    run git log -1 --format=%B refs/stack/s
    [[ "$output" != *$'\nlock '* ]]

    # The worktree and the in-progress state are gone.
    [ ! -e "$(worktree_path)" ]
    run git rev-parse -q --verify refs/stack-restack/s
    [ "$status" -ne 0 ]
}

@test "restack with nothing moved changes nothing" {
    git stack-bubble init s --umbrella feature >/dev/null
    manifest="$(git rev-parse refs/stack/s)"

    run git stack-bubble restack
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing in it moved"* ]]
    [ "$(git ls-remote origin refs/stack/s | cut -f1)" = "$manifest" ]
}

@test "restack stops on a conflict, holds the lock, and --continue publishes" {
    git stack-bubble init s --umbrella feature >/dev/null
    advance_develop README.md "edited on develop"
    old_feature="$(git rev-parse origin/feature)"

    run git stack-bubble restack
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict in bubble ABC-2"* ]]

    # Nothing moved, and anyone else sees the lock.
    [ "$(git ls-remote origin refs/heads/feature | cut -f1)" = "$old_feature" ]
    run git stack-bubble show
    [[ "$output" == *"LOCKED by test@example.com"* ]]

    wt="$(worktree_path)"
    echo "resolved" > "$wt/README.md"
    git -C "$wt" add README.md

    run git stack-bubble restack --continue
    [ "$status" -eq 0 ]

    git fetch -q origin
    run git verify-bubble --base origin/develop origin/feature
    [ "$status" -eq 0 ]
    [ "$(git show origin/feature:README.md)" = "resolved" ]
}

@test "restack --abort drops the work and releases the lock" {
    git stack-bubble init s --umbrella feature >/dev/null
    advance_develop README.md "edited on develop"
    old_feature="$(git rev-parse origin/feature)"
    run git stack-bubble restack
    [ "$status" -eq 1 ]

    run git stack-bubble restack --abort
    [ "$status" -eq 0 ]
    [[ "$output" == *"Released the lock"* ]]

    [ "$(git ls-remote origin refs/heads/feature | cut -f1)" = "$old_feature" ]
    [ "$(git rev-parse feature)" = "$old_feature" ]
    [ ! -e "$(worktree_path)" ]
    run git stack-bubble show
    [[ "$output" != *"LOCKED"* ]]
}

@test "a second clone is refused while the stack is locked, and --break-lock stops the first restack publishing" {
    git stack-bubble init s --umbrella feature >/dev/null
    advance_develop README.md "edited on develop"
    run git stack-bubble restack
    [ "$status" -eq 1 ]

    git clone -q "$TEST_DIR/remote.git" "$TEST_DIR/other" 2>/dev/null
    cd "$TEST_DIR/other"
    configure_clone
    git config user.email "other@example.com"

    run git stack-bubble restack --stack s
    [ "$status" -eq 1 ]
    [[ "$output" == *"locked: test@example.com"* ]]

    run git stack-bubble restack --stack s --break-lock
    [ "$status" -eq 0 ]
    git log -1 --format=%B refs/stack/s | grep -q "broken by other@example.com"

    cd "$TEST_DIR/work"
    wt="$(worktree_path)"
    echo "resolved" > "$wt/README.md"
    git -C "$wt" add README.md
    run git stack-bubble restack --continue
    [ "$status" -eq 1 ]
    [[ "$output" == *"no longer this restack's"* ]]
}

@test "restack refuses a sub-branch with commits that never landed, and --from takes them" {
    git stack-bubble init s --umbrella feature >/dev/null
    git checkout -q ABC-2-part
    echo "fix" > fix.txt
    git add fix.txt
    git commit -qm "Fix part 2"
    git push -q origin ABC-2-part
    git checkout -q develop

    run git stack-bubble restack
    [ "$status" -eq 1 ]
    [[ "$output" == *"'ABC-2-part' has commits that never landed in bubble ABC-2"* ]]

    run git stack-bubble restack --from ABC-2 --keep-base
    [ "$status" -eq 0 ]
    git fetch -q origin
    run git verify-bubble --base origin/develop origin/feature
    [ "$status" -eq 0 ]
    [ "$(git show origin/feature:fix.txt)" = "fix" ]
    # ABC-1 sat below the change and was not rebuilt.
    [ "$(git log --format=%s -1 origin/feature~2)" = "Merge ABC-1: part 1" ]
    [ "$(git rev-parse origin/ABC-2-part)" = "$(git rev-parse origin/feature~1^2)" ]
}

@test "restack --from refuses a local sub-branch missing commits on its remote" {
    git stack-bubble init s --umbrella feature >/dev/null
    git checkout -q ABC-2-part
    echo "pushed by a teammate" > fix.txt
    git add fix.txt
    git commit -qm "Teammate fix"
    git push -q origin ABC-2-part
    git reset -q --hard HEAD~1
    git checkout -q develop
    remote_tip="$(git rev-parse origin/ABC-2-part)"

    run git stack-bubble restack --from ABC-2 --keep-base
    [ "$status" -eq 1 ]
    [[ "$output" == *"'origin/ABC-2-part' has commits that local 'ABC-2-part' does not"* ]]
    git fetch -q origin
    [ "$(git rev-parse origin/ABC-2-part)" = "$remote_tip" ]
    [ -z "$(git show -s --format=%B refs/stack/s | grep -i lock || true)" ]
}

@test "route refuses a sub-branch behind its remote until it is synced" {
    git stack-bubble init s --umbrella feature >/dev/null
    git checkout -q ABC-2-part
    echo "pushed by a teammate" > fix.txt
    git add fix.txt
    git commit -qm "Teammate fix"
    git push -q origin ABC-2-part
    git reset -q --hard HEAD~1
    git checkout -q feature
    echo "part 2 fixed" > part2.txt
    git add part2.txt

    run git stack-bubble route
    [ "$status" -eq 1 ]
    [[ "$output" == *"Sub-branch 'ABC-2-part' is behind bubble ABC-2 or 'origin/ABC-2-part'"* ]]
    [ "$(git rev-parse origin/ABC-2-part)" != "$(git rev-parse ABC-2-part)" ]

    git stack-bubble sync ABC-2-part >/dev/null
    run git stack-bubble route
    [ "$status" -eq 0 ]
    git fetch -q origin
    [ "$(git show origin/feature:fix.txt)" = "pushed by a teammate" ]
    [ "$(git show origin/feature:part2.txt)" = "part 2 fixed" ]
}

@test "a failing stack.preflight leaves the stack unlocked" {
    git stack-bubble init s --umbrella feature >/dev/null
    manifest="$(git rev-parse refs/stack/s)"
    advance_develop other.txt "new on develop"
    git config stack.preflight 'echo "preflight saw $BUBBLEFLOW_NEW_BASE"; exit 3'

    run git stack-bubble restack
    [ "$status" -eq 1 ]
    [[ "$output" == *"preflight saw $(git rev-parse origin/develop)"* ]]
    [ "$(git ls-remote origin refs/stack/s | cut -f1)" = "$manifest" ]
}

@test "a failing stack.exec stops on that bubble and --continue reruns it" {
    git stack-bubble init s --umbrella feature >/dev/null
    advance_develop other.txt "new on develop"
    git config stack.exec 'test "$BUBBLEFLOW_BUBBLE" != ABC-2 || test -f gate-ok'

    run git stack-bubble restack
    [ "$status" -eq 1 ]
    [[ "$output" == *"stack.exec failed on bubble ABC-2"* ]]

    wt="$(worktree_path)"
    echo ok > "$wt/gate-ok"
    git -C "$wt" add gate-ok
    git -C "$wt" commit -qm "Make the gate pass"

    run git stack-bubble restack --continue
    [ "$status" -eq 0 ]
    git fetch -q origin
    [ "$(git show origin/ABC-2-part:gate-ok)" = "ok" ]
}

@test "a branch checked out in a worktree follows its rebuilt commit" {
    git stack-bubble init s --umbrella feature >/dev/null
    advance_develop other.txt "new on develop"
    git checkout -q feature

    run git stack-bubble restack
    [ "$status" -eq 0 ]
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/feature)" ]
    [ "$(cat other.txt)" = "new on develop" ]
    git diff --quiet HEAD
}

@test "bubbles landed since the last generation join the stack" {
    git stack-bubble init s --umbrella feature >/dev/null
    git checkout -qb ABC-4-part feature
    echo "part 4" > part4.txt
    git add part4.txt
    git commit -qm "Part 4"
    git land --target feature -m "part 4" >/dev/null
    git checkout -q develop
    git push -q origin feature ABC-4-part
    advance_develop other.txt "new on develop"

    run git stack-bubble restack
    [ "$status" -eq 0 ]
    [[ "$output" == *"Adding 1 bubble(s)"*"ABC-4"* ]]
    run git stack-bubble show
    [[ "$output" == *"4. ABC-4"*"ABC-4-part"* ]]
}

@test "pending branches are rebased onto the new umbrella without landing" {
    git checkout -qb ABC-5-wip feature
    echo "wip" > wip.txt
    git add wip.txt
    git commit -qm "Work in progress"
    git push -q origin ABC-5-wip
    git checkout -q develop
    git stack-bubble init s --umbrella feature --pending ABC-5-wip >/dev/null
    advance_develop other.txt "new on develop"

    run git stack-bubble restack
    [ "$status" -eq 0 ]
    git fetch -q origin
    [ "$(git rev-parse origin/ABC-5-wip~1)" = "$(git rev-parse origin/feature)" ]
    [ "$(git log --format=%s -1 origin/feature)" = "Merge ABC-3: part 3" ]
}

@test "a stack with no bubbles yet moves its umbrella and pending branches to the new base" {
    git branch fresh develop
    git checkout -qb ABC-6-wip fresh
    echo "wip" > wip.txt
    git add wip.txt
    git commit -qm "Work in progress"
    git checkout -q develop
    git push -q origin fresh ABC-6-wip
    git stack-bubble init t --umbrella fresh --pending ABC-6-wip >/dev/null
    advance_develop other.txt "new on develop"

    run git stack-bubble restack --stack t
    [ "$status" -eq 0 ]
    git fetch -q origin
    [ "$(git rev-parse origin/fresh)" = "$(git rev-parse origin/develop)" ]
    [ "$(git rev-parse origin/ABC-6-wip~1)" = "$(git rev-parse origin/develop)" ]
}

# A second engineer's clone, taken before the restack, holding every stack
# branch locally plus work of their own.
clone_second() {
    git clone -q "$TEST_DIR/remote.git" "$TEST_DIR/other" 2>/dev/null
    cd "$TEST_DIR/other"
    configure_clone
    local branch
    for branch in develop feature ABC-1-part ABC-2-part ABC-3-part; do
        git branch -q "$branch" "origin/$branch"
    done
    git fetch -q origin 'refs/stack/*:refs/stack/*'
    git config bubbleflow.stack s
}

commit_on() { # <branch> <start> <file> <content>
    git checkout -qb "$1" "$2"
    echo "$4" > "$3"
    git add "$3"
    git commit -qm "$1: $3"
}

restack_from_first() {
    cd "$TEST_DIR/work"
    advance_develop "$1" "$2"
    git stack-bubble restack >/dev/null
    cd "$TEST_DIR/other"
}

@test "sync moves stack branches and replays own work onto its rewritten fork point" {
    git stack-bubble init s --umbrella feature >/dev/null
    clone_second
    commit_on mine feature mine.txt "mine"
    commit_on mid ABC-2-part mid.txt "mid"
    commit_on unrelated develop unrelated.txt "unrelated"
    unrelated_before="$(git rev-parse unrelated)"
    git checkout -q feature
    restack_from_first other.txt "new on develop"

    run git stack-bubble sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"mine: replay 1 commit(s)"* ]]

    for branch in feature ABC-1-part ABC-2-part ABC-3-part; do
        [ "$(git rev-parse "$branch")" = "$(git rev-parse "origin/$branch")" ]
    done
    # The checked-out umbrella followed, files and all.
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/feature)" ]
    [ "$(cat other.txt)" = "new on develop" ]

    [ "$(git rev-parse mine~1)" = "$(git rev-parse origin/feature)" ]
    [ "$(git rev-parse mid~1)" = "$(git rev-parse origin/ABC-2-part)" ]
    [ "$(git rev-parse unrelated)" = "$unrelated_before" ]
    [ -n "$(git tag -l 'backup/sync-s-*/mine')" ]

    run git stack-bubble sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"already on generation 1"* ]]
}

@test "sync crosses generations the clone missed" {
    git stack-bubble init s --umbrella feature >/dev/null
    clone_second
    commit_on mine feature mine.txt "mine"
    restack_from_first one.txt "first move"
    restack_from_first two.txt "second move"

    run git stack-bubble sync mine
    [ "$status" -eq 0 ]
    [ "$(git rev-parse mine~1)" = "$(git rev-parse origin/feature)" ]
    [ "$(git show mine:two.txt)" = "second move" ]
}

@test "sync replays commits added on top of a stack branch" {
    git stack-bubble init s --umbrella feature >/dev/null
    clone_second
    git checkout -q ABC-3-part
    echo "more" > more.txt
    git add more.txt
    git commit -qm "More part 3"
    git checkout -q develop
    restack_from_first other.txt "new on develop"

    run git stack-bubble sync ABC-3-part
    [ "$status" -eq 0 ]
    [ "$(git rev-parse ABC-3-part~1)" = "$(git rev-parse origin/ABC-3-part)" ]
}

@test "sync --dry-run reports without moving anything" {
    git stack-bubble init s --umbrella feature >/dev/null
    clone_second
    before="$(git rev-parse feature)"
    restack_from_first other.txt "new on develop"

    run git stack-bubble sync --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"feature: move to"* ]]
    [ "$(git rev-parse feature)" = "$before" ]
}

@test "sync leaves a conflicting branch alone and syncs the rest" {
    git stack-bubble init s --umbrella feature >/dev/null
    clone_second
    commit_on clash feature other.txt "clashing"
    clash_before="$(git rev-parse clash)"
    git checkout -q develop
    restack_from_first other.txt "new on develop"

    run git stack-bubble sync
    [ "$status" -eq 1 ]
    [[ "$output" == *"clash: conflicts on the new stack"* ]]
    [[ "$output" == *"Not synced: clash"* ]]
    [ "$(git rev-parse clash)" = "$clash_before" ]
    [ "$(git rev-parse feature)" = "$(git rev-parse origin/feature)" ]
}

@test "sync refuses while the stack is being restacked" {
    git stack-bubble init s --umbrella feature >/dev/null
    advance_develop README.md "edited on develop"
    run git stack-bubble restack
    [ "$status" -eq 1 ]
    clone_second

    run git stack-bubble sync
    [ "$status" -eq 1 ]
    [[ "$output" == *"being restacked by test@example.com"* ]]
}

@test "route folds a fix staged on the umbrella into the bubble that wrote the lines" {
    git stack-bubble init s --umbrella feature >/dev/null
    abc1_merge="$(git rev-parse feature~2)"
    git checkout -q feature
    echo "part 2 fixed" > part2.txt
    git add part2.txt

    run git stack-bubble route
    [ "$status" -eq 0 ]
    [[ "$output" == *"part2.txt @@ -1 +1 @@ → ABC-2"* ]]

    git fetch -q origin
    [ "$(git show origin/feature:part2.txt)" = "part 2 fixed" ]
    run git verify-bubble --base origin/develop origin/feature
    [ "$status" -eq 0 ]
    # Absorbed into the commit that wrote the line, not added on top.
    [ "$(git rev-list --count origin/feature~2..origin/ABC-2-part)" -eq 1 ]
    [ "$(git log -1 --format=%s origin/ABC-2-part)" = "Part 2" ]
    # Nothing below ABC-2 was rebuilt, and the checkout followed.
    [ "$(git rev-parse origin/feature~2)" = "$abc1_merge" ]
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/feature)" ]
    git diff --quiet HEAD
    [[ "$(git stash list)" == *"stack-bubble route: routed into ABC-2"* ]]
}

@test "route splits hunks across bubbles and places pure additions by their context" {
    git stack-bubble init s --umbrella feature >/dev/null
    git checkout -q feature
    echo "part 1 fixed" > part1.txt
    echo "part 3 continued" >> part3.txt
    git add part1.txt part3.txt

    run git stack-bubble route
    [ "$status" -eq 0 ]
    [[ "$output" == *"part1.txt"*"→ ABC-1"* ]]
    [[ "$output" == *"part3.txt"*"→ ABC-3"* ]]

    git fetch -q origin
    [ "$(git show origin/ABC-1-part:part1.txt)" = "part 1 fixed" ]
    [ "$(git show origin/ABC-3-part:part3.txt | tail -1)" = "part 3 continued" ]
    run git verify-bubble --base origin/develop origin/feature
    [ "$status" -eq 0 ]
}

@test "route refuses a new file until --to names its bubble" {
    git stack-bubble init s --umbrella feature >/dev/null
    git checkout -q feature
    echo "brand new" > new.txt
    git add new.txt

    run git stack-bubble route
    [ "$status" -eq 1 ]
    [[ "$output" == *"new.txt: a new file"* ]]
    [ "$(git ls-remote origin refs/heads/feature | cut -f1)" = "$(git rev-parse HEAD)" ]

    run git stack-bubble route --to ABC-3 -m "Add new.txt"
    [ "$status" -eq 0 ]
    git fetch -q origin
    [ "$(git log -1 --format=%s origin/ABC-3-part)" = "Add new.txt" ]
    [ "$(git show origin/feature:new.txt)" = "brand new" ]
}

@test "route --dry-run prints the plan and changes nothing" {
    git stack-bubble init s --umbrella feature >/dev/null
    git checkout -q feature
    echo "part 2 fixed" > part2.txt
    git add part2.txt
    before="$(git rev-parse ABC-2-part)"

    run git stack-bubble route --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"→ ABC-2"* ]]
    [ "$(git rev-parse ABC-2-part)" = "$before" ]
    [ -n "$(git diff --cached --name-only)" ]
}

@test "route only works from the umbrella" {
    git stack-bubble init s --umbrella feature >/dev/null
    run git stack-bubble route
    [ "$status" -eq 1 ]
    [[ "$output" == *"Check out 'feature' first"* ]]
}

@test "new starts a pending branch at the tip and publishes it with the manifest" {
    git stack-bubble init s --umbrella feature >/dev/null

    run git stack-bubble new ABC-7-next
    [ "$status" -eq 0 ]
    [ "$(git rev-parse --abbrev-ref HEAD)" = "ABC-7-next" ]
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/feature)" ]
    [ "$(git ls-remote origin refs/heads/ABC-7-next | cut -f1)" = "$(git rev-parse HEAD)" ]
    run git stack-bubble show
    [[ "$output" == *"pending   ABC-7-next"* ]]

    run git stack-bubble new ABC-7-next
    [ "$status" -eq 1 ]
    [[ "$output" == *"already exists"* ]]
}

@test "a pending branch that lands becomes a bubble at the next restack" {
    git stack-bubble init s --umbrella feature >/dev/null
    git stack-bubble new ABC-7-next >/dev/null
    echo "part 7" > part7.txt
    git add part7.txt
    git commit -qm "Part 7"
    git land --target feature -m "part 7" >/dev/null
    git push -q origin feature ABC-7-next
    advance_develop other.txt "new on develop"

    run git stack-bubble restack
    [ "$status" -eq 0 ]
    [[ "$output" == *"'ABC-7-next' has landed"* ]]
    run git stack-bubble show
    [[ "$output" == *"4. ABC-7"*"ABC-7-next"* ]]
    [[ "$output" != *"pending"* ]]
}
