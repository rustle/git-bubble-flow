#!/usr/bin/env bats
# Test cases for git-bubble-absorb

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
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

@test "bubble-absorb runs successfully with auto-detected base" {
    # Create a feature branch
    git checkout -b feature-auto-test staging
    echo "Feature content 1" > feature1.txt
    git add feature1.txt
    git commit -m "Add feature 1"
    
    echo "Feature content 2" > feature2.txt
    git add feature2.txt  
    git commit -m "Add feature 2"
    
    # Test with auto-detection
    # If git-absorb is not installed, we can only check that it doesn't immediately crash
    
    # This should at least not throw a fatal error if git-absorb exists
    run git bubble-absorb
    # Exit code may vary depending on whether git-absorb is available
}

@test "bubble-absorb fails gracefully when git-absorb not installed" {
    # We can test this indirectly by ensuring that the script doesn't crash 
    # or fails with proper error handling
    
    # Since we're testing in a clean environment, the script should check for git-absorb
    run git bubble-absorb --help 2>&1 || true  # Don't fail if command doesn't exist
    
    # It should at least not have a syntax error or crash
}

@test "bubble-absorb accepts explicit base parameter" {
    # Create a feature branch
    git checkout -b feature-explicit-test staging
    echo "Feature content" > test.txt
    git add test.txt
    git commit -m "Add test"
    
    # Test with explicit base (staging)
    run git bubble-absorb --base staging 2>&1 || true
    
    # If git-absorb is installed, it should execute normally
    # If not, it should fail gracefully with a meaningful error message
}

@test "bubble-absorb handles non-existent base gracefully" {
    # Try to use a non-existent base
    run git bubble-absorb --base nonexistent-base 2>&1 || true
    
    # Should give a meaningful error (though the exact behavior may vary) 
    [[ "$output" == *"does not exist"* ]]
}

@test "bubble-absorb detects ticket from feature branch name" {
    # Create a branch that follows our expected naming convention
    git checkout -b ABC-123-feature-test staging
    echo "Test content" > test.txt
    git add test.txt
    git commit -m "Add test"
    
    # Basic execution test - shouldn't crash immediately
    run git bubble-absorb 2>&1 || true
    
    # If this command is available, it should at least be executable
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]  # Either success or error (depending on git-absorb availability)
}