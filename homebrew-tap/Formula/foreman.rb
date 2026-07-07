# typed: false
# frozen_string_literal: true

# Foreman — AI-powered multi-agent engineering orchestrator
#
# This formula installs Foreman as a standalone binary. The release archive
# contains the platform-specific Foreman binary.
# A thin shell wrapper in bin/ delegates to the real binary.
#
# Usage after installation:
#   brew tap oftheangels/tap
#   brew install foreman
#
class Foreman < Formula
  desc "AI-powered multi-agent engineering orchestrator"
  homepage "https://github.com/ldangelo/foreman"
  version "0.1.0"
  license "MIT"

  # ── macOS ──────────────────────────────────────────────────────────────────
  on_macos do
    # Apple Silicon (M1 / M2 / M3)
    on_arm do
      url "https://github.com/ldangelo/foreman/releases/download/v#{version}/foreman-v#{version}-darwin-arm64.tar.gz"
      sha256 "PLACEHOLDER_DARWIN_ARM64_SHA256"
    end

    # Intel
    on_intel do
      url "https://github.com/ldangelo/foreman/releases/download/v#{version}/foreman-v#{version}-darwin-x64.tar.gz"
      sha256 "PLACEHOLDER_DARWIN_X64_SHA256"
    end
  end

  # ── Linux ──────────────────────────────────────────────────────────────────
  on_linux do
    # x86_64
    on_intel do
      url "https://github.com/ldangelo/foreman/releases/download/v#{version}/foreman-v#{version}-linux-x64.tar.gz"
      sha256 "PLACEHOLDER_LINUX_X64_SHA256"
    end

    # ARM64 (AWS Graviton, Raspberry Pi 4+)
    on_arm do
      url "https://github.com/ldangelo/foreman/releases/download/v#{version}/foreman-v#{version}-linux-arm64.tar.gz"
      sha256 "PLACEHOLDER_LINUX_ARM64_SHA256"
    end
  end

  def install
    # Determine platform-specific binary name from the release archive
    binary_name = if OS.mac?
      Hardware::CPU.arm? ? "foreman-darwin-arm64" : "foreman-darwin-x64"
    else
      Hardware::CPU.arm? ? "foreman-linux-arm64" : "foreman-linux-x64"
    end

    # Install the binary into libexec/foreman/.
    libexec_dir = libexec/"foreman"
    libexec_dir.mkpath

    # Rename platform binary to a generic name inside libexec
    cp binary_name, libexec_dir/"foreman"
    chmod 0755, libexec_dir/"foreman"


    # Create a thin wrapper in bin/ that delegates to the real binary.
    # Using a shell wrapper (not a symlink) ensures import.meta.url in the
    # compiled binary resolves to the libexec path, not the bin symlink.
    # bin.install is not used here because the wrapper must be written with
    # the resolved libexec path interpolated at install time.
    (bin/"foreman").write <<~EOS
      #!/usr/bin/env bash
      exec "#{libexec_dir}/foreman" "$@"
    EOS
    chmod 0755, bin/"foreman"
  end

  def caveats
    <<~EOS
      ╔══════════════════════════════════════════════════════════════╗
      ║              Foreman Post-Install Setup                      ║
      ╚══════════════════════════════════════════════════════════════╝

      Foreman requires an API key:

      ┌─ ANTHROPIC_API_KEY — Claude API Key ───────────────────────
      │
      │  Add to your shell profile (~/.zshrc or ~/.bash_profile):
      │    export ANTHROPIC_API_KEY="sk-ant-..."
      │
      │  Then reload your shell:
      │    source ~/.zshrc
      │
      │  Get an API key at: https://console.anthropic.com/
      │
      └───────────────────────────────────────────────────────────────

      Quick Start:
        cd ~/your-project
        foreman init --name my-project
        foreman run

      Full documentation:
        https://github.com/ldangelo/foreman#readme

      Run `foreman doctor` to verify your setup.
    EOS
  end

  test do
    # Smoke test: binary must run and report the correct version
    assert_match version.to_s, shell_output("#{bin}/foreman --version")

    # Verify --help output mentions expected commands
    help_output = shell_output("#{bin}/foreman --help 2>&1")
    assert_match "run", help_output

    # Verify doctor runs without crashing (exit code may be non-zero in sandbox
    # because ANTHROPIC_API_KEY will not be present — that's expected).
    system "bash", "-c", "#{bin}/foreman doctor --no-color 2>&1 || true"
  end
end
