#!/usr/bin/env bats
# Test cases for git-land-bubble

setup() {
    # Create a temporary directory for testing
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
    
    # Initialize git repo
    git init
    git config user.name "Test User"
    git config user.email "test@example.com"

    # Put bin/ on PATH and run the real setup script so tests exercise the same
    # aliases consumers get
    # PATH already carries the multi-call shims (see test/run-tests.sh). Run
    # the real setup so tests exercise the aliases consumers get.
    bubble-flow-setup --base staging >/dev/null
    
    # Create initial commit
    echo "Initial commit" > README.md
    git add README.md
    git commit -m "Initial commit"
    
    # Create staging branch
    git checkout -b staging
    
    # Add some commits to establish history
    echo "Second commit" > file1.txt
    git add file1.txt
    git commit -m "Add file1.txt"
    
    echo "Third commit" > file2.txt  
    git add file2.txt
    git commit -m "Add file2.txt"
    
    # Set up bubble-flow config  
    git config bubbleflow.base staging
    git config bubbleflow.ticketPattern "ABC-[0-9]+"
}

teardown() {
    cd /
    # Worktrees are created outside the repo, so the second path is not covered
    # by removing the first.
    rm -rf "$TEST_DIR" "$TEST_DIR-worktrees"
}

# The layout the nested-branch workflow produces: a feature branch and a
# sub-feature branch off it, each checked out in its own worktree, with the
# shell left standing in the sub-feature one. Records the feature branch's tip
# in FEATURE_BEFORE so a test can assert on whether it moved. Not called through
# command substitution anywhere: that would run it in a subshell, and neither
# the directory change nor WT would reach the test.
setup_worktree_pair() {
    WT="$TEST_DIR-worktrees"
    mkdir -p "$WT"
    git checkout -q staging
    git branch ABC-100-feature staging
    git worktree add -q "$WT/feature" ABC-100-feature
    git worktree add -q -b ABC-101-sub "$WT/sub" ABC-100-feature
    cd "$WT/sub"
    echo "sub work" > sub.txt
    git add sub.txt
    git commit -qm "ABC-101 sub work"
    FEATURE_BEFORE="$(git rev-parse ABC-100-feature)"
}

@test "land-bubble successfully lands a feature branch" {
    # Create a feature branch with a proper ticket name
    git checkout -b ABC-123-feature-test staging
    echo "Feature content" > feature.txt
    git add feature.txt
    git commit -m "Add feature functionality"
    
    # Check that we're on the feature branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    [ "$current_branch" = "ABC-123-feature-test" ]
    
    # Land the bubble
    run git land --target staging -m "Implement feature"
    [ "$status" -eq 0 ]
    
    # Check that we're back on staging
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    [ "$current_branch" = "staging" ]
    
    # Verify the new bubble (explicit base: on staging the configured base is
    # staging itself, which would make a bare verify run vacuous)
    run git verify-bubble --base HEAD~1
    [ "$status" -eq 0 ]
    [[ "$output" == *"All validations passed"* ]]
}

@test "land-bubble fails with dirty working tree" {
    # Create a feature branch
    git checkout -b ABC-456-dirty-test staging
    echo "Feature content" > feature.txt
    git add feature.txt
    git commit -m "Add feature functionality"
    
    # Modify file without committing (dirty tree)
    echo "Dirty content" >> feature.txt
    
    # Try to land - should fail
    run git land --target staging -m "Should fail"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Working tree is dirty"* ]]
}

@test "land-bubble fails when feature branch is not ancestor of target" {
    # Create the feature branch first...
    git checkout -b ABC-789-separate-test staging
    echo "Feature content" > feature.txt
    git add feature.txt
    git commit -m "Add feature functionality"

    # ...then advance staging past the fork point, so staging is no longer an
    # ancestor of the feature branch (feature needs a rebase before landing)
    git checkout staging
    echo "Separate commit" > separate.txt
    git add separate.txt
    git commit -m "Separate commit"
    git checkout ABC-789-separate-test

    # Try to land - should fail because target is not an ancestor of the feature
    run git land --target staging -m "Should fail"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not an ancestor"* ]]
}

@test "land-bubble extracts ticket from branch name" {
    # Create a feature branch with ticket 
    git checkout -b ABC-999-test-feature staging
    echo "Feature content" > test.txt  
    git add test.txt
    git commit -m "Add test functionality"
    
    # Verify it can extract the ticket correctly
    run git land --target staging -m "Test landing"
    [ "$status" -eq 0 ]
    
    # The merge message should contain our ticket
    last_commit_msg=$(git log --format=%B -1)
    [[ "$last_commit_msg" == *"Merge ABC-999:"* ]]
}
@test "land-bubble falls back to the branch name when there is no ticket" {
    # A ticket convention is opt-in. Without --strict a branch that does not
    # carry one still lands, with its own name as the subject label.
    git checkout -b no-ticket-here staging
    echo "Untickered" > untickered.txt
    git add untickered.txt
    git commit -m "Add untickered work"

    run git land --target staging -m "Landing without a ticket"
    [ "$status" -eq 0 ]

    last_commit_msg=$(git log --format=%B -1)
    [[ "$last_commit_msg" == *"Merge no-ticket-here: Landing without a ticket"* ]]
}

@test "land-bubble --strict refuses a branch with no ticket" {
    git checkout -b still-no-ticket staging
    echo "Strict" > strict.txt
    git add strict.txt
    git commit -m "Add strict work"

    run git land --strict --target staging -m "Should fail"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not extract ticket"* ]]
    [[ "$output" == *"Drop --strict"* ]]

    # Nothing may have moved: the refusal comes before the merge.
    [ "$(git rev-parse --abbrev-ref HEAD)" = "still-no-ticket" ]
}

@test "land-bubble --strict accepts a branch that carries a ticket" {
    git checkout -b ABC-555-strict-ok staging
    echo "Strict ok" > strictok.txt
    git add strictok.txt
    git commit -m "Add strict-ok work"

    run git land --strict --target staging -m "Strictly landed"
    [ "$status" -eq 0 ]

    last_commit_msg=$(git log --format=%B -1)
    [[ "$last_commit_msg" == *"Merge ABC-555: Strictly landed"* ]]
}

@test "land-bubble refuses a feature branch that adds nothing" {
    # A branch created at the target tip has nothing to merge: git reports
    # "Already up to date", exits 0 and creates no commit. Landing must fail
    # rather than announce success and tell the user to push.
    before="$(git rev-parse staging)"
    git checkout -b ABC-000-empty-test staging

    run git land --target staging -m "Empty test"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Nothing to land"* ]]

    # The target must be untouched, with no backup tag left behind.
    [ "$(git rev-parse staging)" = "$before" ]
    [ -z "$(git tag -l 'backup/land-ABC-000-empty-test-*')" ]
}

@test "land-bubble refuses a target that is not a local branch" {
    # A tag, a remote-tracking ref or a sha all resolve, but checking one out
    # detaches HEAD, so the land would "succeed" without moving any branch.
    git tag v-target staging
    git checkout -b ABC-321-tag-target staging
    echo "tagged" > tagged.txt
    git add tagged.txt
    git commit -m "Add tagged.txt"

    run git land --target v-target -m "should refuse"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a local branch"* ]]

    # HEAD must still be attached to the feature branch, not detached.
    [ "$(git rev-parse --abbrev-ref HEAD)" = "ABC-321-tag-target" ]
}

@test "land-bubble lands into the worktree that holds the target branch" {
    # git refuses to check out a branch a second worktree already has, which
    # used to stop the land dead. The merge happens in that worktree instead, so
    # its ref, index and files stay consistent with one another.
    setup_worktree_pair

    run git land --target ABC-100-feature -m "Sub feature"
    [ "$status" -eq 0 ]
    [[ "$output" == *"is checked out at"* ]]

    # The target advanced, and its worktree holds the landed content with
    # nothing left uncommitted.
    [ "$(git rev-parse ABC-100-feature)" != "$FEATURE_BEFORE" ]
    [ -f "$WT/feature/sub.txt" ]
    [ -z "$(git -C "$WT/feature" status --porcelain)" ]

    # The sub-feature worktree is where we started and still is.
    [ "$(git rev-parse --abbrev-ref HEAD)" = "ABC-101-sub" ]

    # And what landed is a bubble like any other.
    run git verify-bubble --base staging ABC-100-feature
    [ "$status" -eq 0 ]
    [[ "$output" == *"Merge ABC-101"* ]]
}

@test "land-bubble refuses a target worktree with uncommitted changes" {
    # Landing would check the merge result out over whatever is sitting there.
    setup_worktree_pair
    echo "scratch" > "$WT/feature/scratch.txt"
    git -C "$WT/feature" add scratch.txt

    run git land --target ABC-100-feature -m "Sub feature"
    [ "$status" -eq 1 ]
    [[ "$output" == *"dirty"* ]]

    # The refusal comes before anything is written, backup tag included.
    [ "$(git rev-parse ABC-100-feature)" = "$FEATURE_BEFORE" ]
    [ -z "$(git tag -l 'backup/*')" ]
    [ "$(git rev-parse --abbrev-ref HEAD)" = "ABC-101-sub" ]
}

@test "land-bubble still checks the target out when no other worktree holds it" {
    # The single-worktree path is unchanged: the land leaves you on the target.
    git checkout -b ABC-200-plain staging
    echo "plain" > plain.txt
    git add plain.txt
    git commit -qm "ABC-200 plain work"

    run git land --target staging -m "Plain"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Checking out target branch"* ]]
    [ "$(git rev-parse --abbrev-ref HEAD)" = "staging" ]
}
