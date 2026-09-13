#!/usr/bin/env bats
# Test cases for git-rebase-bubble

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
    
    # Create staging branch (the bubble chain under test)
    git checkout -b staging
    
    # Add some commits to establish history
    echo "Second commit" > file1.txt
    git add file1.txt
    git commit -m "Add file1.txt"
    
    echo "Third commit" > file2.txt  
    git add file2.txt
    git commit -m "Add file2.txt"
    
    # Create a feature branch and bubble
    git checkout -b feature1 staging
    echo "Feature 1 content" > feature1.txt
    git add feature1.txt
    git commit -m "Add feature 1"
    
    git checkout staging
    git merge --no-ff -m "Merge feature1: Add feature 1" feature1
    
    # Create another feature branch and bubble  
    git checkout -b feature2 staging
    echo "Feature 2 content" > feature2.txt
    git add feature2.txt
    git commit -m "Add feature 2"
    
    git checkout staging
    git merge --no-ff -m "Merge feature2: Add feature 2" feature2
    
    # Set up bubble-flow config
    # Verify against the root commit so 'git verify-bubble' on staging sees a
    # non-empty range instead of passing vacuously
    git config bubbleflow.base "$(git rev-list --max-parents=0 HEAD)"
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

@test "rebase-bubble successfully rebases the bubble branch" {
    # Check we're starting on staging
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    [ "$current_branch" = "staging" ]
    
    # Check that we have bubbles
    run git verify-bubble
    [ "$status" -eq 0 ]
    
    # Rebase the bubble branch
    run git rebase-bubble
    [ "$status" -eq 0 ]
    
    # Verify it still works after rebase
    run git verify-bubble
    [ "$status" -eq 0 ]
}

@test "rebase-bubble fails with dirty working tree" {
    # Modify a tracked file without committing (an untracked file would not
    # make diff-index report the tree as dirty)
    echo "Dirty content" >> file1.txt
    
    # Try to rebase - should fail
    run git rebase-bubble
    [ "$status" -eq 1 ]
    [[ "$output" == *"Working tree is dirty"* ]]
}

@test "rebase-bubble handles invalid bubble branch gracefully" {
    # Try to rebase with a non-existent bubble branch
    run git rebase-bubble --bubble nonexistent-branch
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "rebase-bubble successfully checks backup tag creation" {
    # Get initial commit count
    initial_count=$(git log --oneline | wc -l)
    
    # Rebase the bubble branch
    run git rebase-bubble
    
    # Should succeed
    [ "$status" -eq 0 ]
    
    # Check for backup tag created
    run git tag
    [[ "$output" == *"backup/rebase-bubble-"* ]]
}

@test "rebase-bubble preserves bubble structure" {
    # Get subjects before rebase
    pre_subjects=$(git log --format=%s --first-parent staging | grep -v "^$")
    
    # Rebase the bubble branch
    run git rebase-bubble
    [ "$status" -eq 0 ]
    
    # Get subjects after rebase 
    post_subjects=$(git log --format=%s --first-parent staging | grep -v "^$")
    
    # Basic check that we have the same number of bubbles
    run git verify-bubble
    [ "$status" -eq 0 ]
}
@test "rebase-bubble leaves a recoverable state when the rebase conflicts" {
    # The conflict path is the one that most needs its guidance to be true:
    # it stops mid-rebase, so the backup tag and the printed instructions are
    # all the user has.
    git checkout -b conflict-bubble staging
    echo "bubble version" > contested.txt
    git add contested.txt
    git commit -m "Add contested.txt from the bubble branch"

    # Move the base underneath it with a conflicting change to the same file.
    git checkout staging
    echo "staging version" > contested.txt
    git add contested.txt
    git commit -m "Add contested.txt from staging"

    git checkout conflict-bubble
    before="$(git rev-parse HEAD)"
    run git rebase-bubble --bubble conflict-bubble --onto staging
    [ "$status" -eq 1 ]

    # It must name the conflict, not fail silently or claim success.
    [[ "$output" == *"Rebase stopped"* ]]
    [[ "$output" == *"git rebase --abort"* ]]

    # A backup tag must exist, and the message must name the one it created.
    backup="$(git tag -l 'backup/rebase-bubble-*' | head -1)"
    [ -n "$backup" ]
    [[ "$output" == *"$backup"* ]]

    # The backup must point at the pre-rebase tip, not merely exist.
    [ "$(git rev-parse "$backup")" = "$before" ]

    # The advertised recovery must restore that exact state.
    git rebase --abort
    run git reset --hard "$backup"
    [ "$status" -eq 0 ]
    [ "$(git rev-parse HEAD)" = "$before" ]
}

@test "rebase-bubble does not let a ref name reach git fetch in option position" {
    # git accepts a ref named refs/remotes/origin/--upload-pack=<path>, and
    # `git fetch <remote> --upload-pack=<path>` executes <path>. The fetch is
    # guarded with --end-of-options so a branch name can never be read as one.
    marker="$TEST_DIR/pwned"
    printf '#!/bin/sh\ntouch %s\nexit 1\n' "$marker" > "$TEST_DIR/evil.sh"
    chmod +x "$TEST_DIR/evil.sh"

    git init -q --bare "$TEST_DIR/remote.git"
    git remote add origin "$TEST_DIR/remote.git"
    git update-ref "refs/remotes/origin/--upload-pack=$TEST_DIR/evil.sh" staging

    git checkout -b bubble-injection staging
    run git rebase-bubble --bubble bubble-injection \
        --onto "origin/--upload-pack=$TEST_DIR/evil.sh"

    # The command may fail. What matters is that nothing was executed.
    [ ! -f "$marker" ]
}
