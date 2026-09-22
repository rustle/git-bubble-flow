# Homebrew formula for git-bubble-flow.
#
# Builds from source and installs a single binary plus the symlinks git uses to
# discover the subcommands. Swift's runtime ships with macOS 10.14.4+, so
# nothing Swift-related is installed alongside it.
#
# Homebrew builds must not reach the network, so the two SwiftPM dependencies
# are declared as `resource`s -- fetched in the audited download phase -- and
# the manifest is rewritten to path-based dependencies before building. The
# build itself performs no resolution and no fetching.
#
class GitBubbleFlow < Formula
  desc "Semi-linear git-flow tooling: empty, nestable bubble merges"
  homepage "https://github.com/rustle/git-bubble-flow"
  url "https://github.com/rustle/git-bubble-flow/archive/refs/tags/0.2.0.tar.gz"
  sha256 "9b74dff3ee5f887cf2a6bb952d1b6bf054a626aa81b8b442cb994410d7a96817"
  license "Apache-2.0"
  head "https://github.com/rustle/git-bubble-flow.git", branch: "main"

  depends_on xcode: ["26.0", :build] # swift-subprocess 1.0 requires Swift 6.2
  depends_on "git-absorb"
  depends_on :macos

  resource "swift-subprocess" do
    url "https://github.com/swiftlang/swift-subprocess/archive/refs/tags/1.0.0.tar.gz"
    sha256 "16dccc16e162f043999078fc8be36938ef723188518d3d4d9f734775bb593c8d"
  end

  resource "swift-system" do
    url "https://github.com/apple/swift-system/archive/refs/tags/1.8.1.tar.gz"
    sha256 "5610bea8f1f390895137247e7e6aa6bf89a6cd108d75d3368aba5da3f06f0d7a"
  end

  # The multi-call symlinks git uses to discover the subcommands.
  SHIMS = %w[
    git-verify-bubble
    git-land-bubble
    git-rebase-bubble
    git-bubble-absorb
    bubble-flow-setup
  ].freeze

  def install
    resources.each { |r| r.stage(buildpath/"vendor"/r.name) }

    # Point the manifest at the staged copies. `traits: []` is preserved so the
    # SubprocessFoundation trait stays off. Enabling it would link Foundation.
    inreplace "Package.swift" do |s|
      rewritten = s.gsub!(
        /\.package\(\s*url:\s*"[^"]*swift-subprocess[^"]*",\s*from:\s*"[^"]*",\s*traits:\s*\[\]\s*\),/m,
        '.package(path: "vendor/swift-subprocess", traits: []), ' \
        '.package(path: "vendor/swift-system"),',
      )
      # Without this the build silently falls back to resolving the dependency
      # from the network, which Homebrew forbids and which would fail late and
      # confusingly instead of here.
      odie "Package.swift dependency rewrite did not match" if rewritten.nil?
    end

    # swift-subprocess's own manifest still refers to swift-system by URL, which
    # collides on package identity with the path dependency injected above.
    # Point it at the same staged copy.
    inreplace buildpath/"vendor/swift-subprocess/Package.swift" do |s|
      rewritten = s.gsub!(
        /\.package\(\s*url:\s*"[^"]*swift-system[^"]*",[^)]*\)/m,
        '.package(path: "../swift-system")',
      )
      odie "swift-subprocess dependency rewrite did not match" if rewritten.nil?
    end

    # Path dependencies need no resolution, so this never touches the network.
    system "swift", "build",
           "--disable-sandbox",
           "-c", "release",
           "--product", "git-bubble-flow"

    bin.install ".build/release/git-bubble-flow"
    SHIMS.each { |shim| bin.install_symlink "git-bubble-flow" => shim }
  end

  def caveats
    <<~EOS
      Configure a repository with:
        cd /path/to/repo && bubble-flow-setup

      That writes the bubbleflow.* config keys and the `git land` alias.
      git verify-bubble, git rebase-bubble and git bubble-absorb need no
      alias: git finds their symlinks on PATH by itself.
    EOS
  end

  test do
    assert_match "git-bubble-flow", shell_output("#{bin}/git-bubble-flow --version")

    # The binary must not depend on a Swift toolchain being present.
    refute_match "@rpath", shell_output("otool -L #{bin}/git-bubble-flow")

    system "git", "init", "-q", testpath
    system "git", "-C", testpath, "config", "user.name", "Homebrew"
    system "git", "-C", testpath, "config", "user.email", "brew@example.com"
    (testpath/"README.md").write "seed\n"
    system "git", "-C", testpath, "add", "README.md"
    system "git", "-C", testpath, "commit", "-qm", "Initial commit"

    # Every shim must dispatch to its own command rather than to the binary's
    # default, which is what a broken symlink install looks like.
    ENV["PATH"] = "#{bin}:#{ENV["PATH"]}"
    system bin/"bubble-flow-setup"

    # Nothing written into the repository may name a path. An absolute one
    # would point into this versioned keg, which the next `brew upgrade`
    # deletes, breaking `git land` in every configured repository.
    alias_value = shell_output("git -C #{testpath} config --get alias.land").strip
    assert_equal "land-bubble", alias_value
    # git config --get exits 1 for a key that is not there.
    %w[verify-bubble rebase-bubble bubble-absorb].each do |name|
      assert_empty shell_output("git -C #{testpath} config --get alias.#{name}", 1).strip
    end

    # Dispatch through git itself, not through the shim directly: that is the
    # path a user takes, and the only one that exercises alias expansion and
    # git's external-subcommand lookup.
    output = shell_output("git -C #{testpath} verify-bubble --base HEAD HEAD")
    assert_match "No bubbles found to verify", output

    # Reaching our own argument error proves `git land` resolved through the
    # alias into the binary rather than dying in git as an unknown command.
    output = shell_output("git -C #{testpath} land --target 2>&1", 1)
    assert_match "--target requires a value", output
  end
end
