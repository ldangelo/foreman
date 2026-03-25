# Formula for oftheangels/tap/foreman
#
# This formula is auto-updated by the update-formula.yml workflow in the
# oftheangels/homebrew-tap repository whenever a new Foreman release is published.
#
# To install:
#   brew tap oftheangels/tap
#   brew install foreman
#
# Or as a one-liner:
#   brew install oftheangels/tap/foreman

class Foreman < Formula
  desc "Multi-agent AI coding orchestrator with task decomposition and git worktree management"
  homepage "https://github.com/ldangelo/foreman"
  version "0.1.0"
  license "MIT"

  # Platform-specific download URLs and SHA-256 checksums.
  # These are automatically updated by the CI/CD update-formula workflow
  # whenever a new GitHub Release is published.
  on_macos do
    on_arm do
      url "https://github.com/ldangelo/foreman/releases/download/v0.1.0/foreman-v0.1.0-darwin-arm64.tar.gz"
      sha256 "PLACEHOLDER_DARWIN_ARM64_SHA256"
    end
    on_intel do
      url "https://github.com/ldangelo/foreman/releases/download/v0.1.0/foreman-v0.1.0-darwin-x64.tar.gz"
      sha256 "PLACEHOLDER_DARWIN_X64_SHA256"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/ldangelo/foreman/releases/download/v0.1.0/foreman-v0.1.0-linux-arm64.tar.gz"
      sha256 "PLACEHOLDER_LINUX_ARM64_SHA256"
    end
    on_intel do
      url "https://github.com/ldangelo/foreman/releases/download/v0.1.0/foreman-v0.1.0-linux-x64.tar.gz"
      sha256 "PLACEHOLDER_LINUX_X64_SHA256"
    end
  end

  # No dependencies — foreman is a standalone binary that bundles Node.js.
  # better_sqlite3.node is included as a side-car in the archive.

  def install
    # Determine binary name based on platform and arch
    if OS.mac? && Hardware::CPU.arm?
      binary_name = "foreman-darwin-arm64"
    elsif OS.mac? && Hardware::CPU.intel?
      binary_name = "foreman-darwin-x64"
    elsif OS.linux? && Hardware::CPU.arm?
      binary_name = "foreman-linux-arm64"
    else
      binary_name = "foreman-linux-x64"
    end

    # Install the main binary to bin/
    bin.install binary_name => "foreman"

    # Install the native addon side-car.
    # better_sqlite3.node must reside in the same directory as the binary
    # so that foreman can load it at runtime via relative path resolution.
    # We place it alongside foreman in libexec/ and patch the binary's lookup path.
    #
    # NOTE: We install to libexec and symlink from lib/ so Homebrew's
    # keg structure is preserved.
    if File.exist?("better_sqlite3.node")
      libexec.install "better_sqlite3.node"
      # The binary resolves better_sqlite3.node relative to itself at runtime.
      # We create a wrapper script that sets the appropriate path and delegates to the binary.
      (bin/"foreman").unlink if (bin/"foreman").exist?
      (bin/"foreman").write <<~BASH
        #!/bin/bash
        # Wrapper to ensure better_sqlite3.node side-car is resolved correctly.
        # Foreman looks for better_sqlite3.node adjacent to the binary executable.
        exec "#{libexec}/foreman" "$@"
      BASH
      chmod 0755, bin/"foreman"
      libexec.install binary_name => "foreman"
      # Copy the native addon to libexec so it's in the same directory as the binary
      cp libexec/"better_sqlite3.node", libexec/"better_sqlite3.node" rescue nil
    end
  end

  def caveats
    <<~EOS
      Foreman requires the following external tools:

      1. br (beads_rust) — task tracking CLI:
           cargo install beads_rust
         or download from: https://github.com/Dicklesworthstone/beads_rust/releases

      2. Anthropic API key — set in your environment:
           export ANTHROPIC_API_KEY=sk-ant-...
         or add to your shell profile (~/.zshrc, ~/.bashrc, etc.)

      3. Git — for worktree management (usually pre-installed on macOS/Linux)

      Get started:
           cd ~/your-project
           foreman init
           foreman run
    EOS
  end

  test do
    # Verify the binary executes and reports a version
    assert_match version.to_s, shell_output("#{bin}/foreman --version")
    # Verify help text is accessible
    assert_match "foreman", shell_output("#{bin}/foreman --help")
  end
end
