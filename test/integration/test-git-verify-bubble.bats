#!/usr/bin/env bats
# Test cases for git-verify-bubble

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
    
    # Verify against the root commit: with base=staging (the setup default) a
    # verify run on staging itself would see an empty range and pass vacuously
    git config bubbleflow.base "$(git rev-list --max-parents=0 HEAD)"
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

@test "verify-bubble passes with empty bubbles" {
    # Create a feature branch and proper bubble
    git checkout -b feature-test staging
    echo "Feature content" > feature.txt
    git add feature.txt
    git commit -m "Add feature.txt"
    
    git checkout staging
    git merge --no-ff -m "Merge feature-test: Add feature.txt" feature-test
    
    # Verify the bubble is empty (should pass)
    run git verify-bubble
    [ "$status" -eq 0 ]
    [[ "$output" == *"All validations passed"* ]]
}

@test "verify-bubble fails with non-empty bubbles" {
    # This is tricky to test directly, but let's make sure it detects invalid refs
    run git verify-bubble nonexistent-ref
    [ "$status" -eq 1 ]
    
    # Should produce an error message
    [[ "$output" == *"FATAL"* ]]
}

@test "verify-bubble handles octopus merges correctly" {
    # Create a merge with three parents to test octopus detection
    git checkout -b branch1 staging
    echo "Branch1 content" > branch1.txt
    git add branch1.txt
    git commit -m "Branch1 commit"
    
    git checkout -b branch2 staging  
    echo "Branch2 content" > branch2.txt
    git add branch2.txt
    git commit -m "Branch2 commit"
    
    # This will create an octopus merge (three-way merge)
    git checkout staging
    git merge branch1 branch2 -m "Octopus merge test" --no-ff
    
    # Try to verify - should fail with octopus error
    run git verify-bubble
    [ "$status" -eq 1 ]
    [[ "$output" == *"Octopus merge"* ]]
}

@test "verify-bubble strict mode enforces subject line convention" {
    # Create a feature and bubble 
    git checkout -b feature-strict staging
    echo "Strict test content" > test.txt
    git add test.txt
    git commit -m "Add strict test"
    
    git checkout staging
    # Use an invalid subject format (without 'Merge <ticket>: ')
    git merge --no-ff -m "Invalid subject format, no prefix" feature-strict
    
    # Verify with strict mode - should fail for subject convention
    run git verify-bubble --strict
    [ "$status" -eq 1 ]
    
    # Note: This test is about the behavior, not an exact error message match
}

@test "verify-bubble handles invalid reference gracefully" {
    run git verify-bubble "nonexistent-ref"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
}
@test "verify-bubble does not count non-merge commits as bubbles" {
    # staging has only ordinary commits here, so there are no bubbles at all.
    run git verify-bubble
    [ "$status" -eq 0 ]
    [[ "$output" == *"No bubbles found to verify"* ]]
    [[ "$output" != *"All validations passed"* ]]
}

@test "verify-bubble strict mode survives an alternation in the ticket pattern" {
    # An unparenthesised alternation used to bind looser than the surrounding
    # text, letting the second branch match anywhere and disabling the check.
    git config bubbleflow.ticketPattern 'ABC-[0-9]+|WEB-[0-9]+'
    git checkout -b feature-alt staging
    echo "alt" > alt.txt
    git add alt.txt
    git commit -m "Add alt"
    git checkout staging
    git merge --no-ff -m "Nonsense WEB-1: not a real merge subject" feature-alt

    run git verify-bubble --strict
    [ "$status" -eq 1 ]
    [[ "$output" == *"Subject line doesn't match"* ]]
}

@test "verify-bubble rejects a value-less --base instead of eating the next flag" {
    # Exit 1 alone proves nothing here: swallowing --strict as the base would
    # also fail, just with "Invalid reference: --strict". Assert the diagnostic
    # names the missing value.
    run git verify-bubble --base --strict
    [ "$status" -eq 1 ]
    [[ "$output" == *"--base requires a value"* ]]
    [[ "$output" != *"Invalid reference"* ]]
}

@test "verify-bubble rejects an option-shaped base from config" {
    # `git merge-base --octopus <ref>` prints <ref> itself, so an unvalidated
    # base made the range empty and the gate pass having checked nothing.
    git config bubbleflow.base "--octopus"
    run git verify-bubble
    [ "$status" -eq 1 ]
    [[ "$output" == *"must not begin with '-'"* ]]
    # The point of the guard: it must not reach merge-base and pass vacuously.
    [[ "$output" != *"No bubbles found to verify"* ]]
    [[ "$output" != *"All validations passed"* ]]
}

@test "verify-bubble recurses into a nested bubble and passes when it is empty" {
    # An outer feature branch that itself lands an inner bubble, then lands on
    # staging: bubble 1 contains bubble 1.1 and a logical commit.
    git checkout -b outer staging
    echo "outer" > outer.txt
    git add outer.txt
    git commit -m "Outer logical commit"
    git checkout -b inner outer
    echo "inner" > inner.txt
    git add inner.txt
    git commit -m "Inner logical commit"
    git checkout outer
    git merge --no-ff -m "Merge inner: Add inner.txt" inner
    git checkout staging
    git merge --no-ff -m "Merge outer: Add outer and inner" outer

    run git verify-bubble
    [ "$status" -eq 0 ]
    [[ "$output" == *"Bubble 1:"* ]]
    [[ "$output" == *"Bubble 1.1:"* ]]
    [[ "$output" == *"All validations passed for 2 bubble(s)"* ]]
}

@test "verify-bubble fails on a non-empty merge nested inside an otherwise empty bubble" {
    # The outer merge is empty, but the inner one is a back-merge of staging
    # that changed the tree, which the recursive walk must catch.
    git checkout -b outer2 staging
    echo "outer" > outer.txt
    git add outer.txt
    git commit -m "Outer logical commit"
    git checkout staging
    echo "moved" > moved.txt
    git add moved.txt
    git commit -m "Staging moves on"
    git checkout outer2
    git merge --no-ff -m "Merge staging into outer2" staging
    git checkout staging
    git merge --no-ff -m "Merge outer2: back-merge inside" outer2

    run git verify-bubble
    [ "$status" -eq 1 ]
    [[ "$output" == *"Non-empty bubble 1.1"* ]]
}

@test "verify-bubble strict mode does not flag logical commits inside a bubble" {
    # Non-merge commits are only a violation directly on the verified range;
    # inside a bubble they are the bubble's contents.
    git config bubbleflow.ticketPattern 'ABC-[0-9]+'
    git checkout -b ABC-7-strict staging
    echo "a" > a.txt
    git add a.txt
    git commit -m "Logical commit A"
    echo "b" > b.txt
    git add b.txt
    git commit -m "Logical commit B"
    git checkout staging
    git merge --no-ff -m "Merge ABC-7: A and B" ABC-7-strict

    run git verify-bubble --strict --base HEAD~1
    [ "$status" -eq 0 ]
    [[ "$output" == *"All validations passed for 1 bubble(s)"* ]]
}
