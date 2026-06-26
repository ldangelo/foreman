# oftheangels/homebrew-tap

[Homebrew](https://brew.sh) tap for tools from [oftheangels](https://github.com/oftheangels).

## Formulae

| Formula | Description |
|---------|-------------|
| [foreman](Formula/foreman.rb) | AI-powered multi-agent engineering orchestrator |

---

## Foreman

**Foreman** is an AI-powered engineering orchestrator that decomposes work into tasks, dispatches them to AI agents in isolated git worktrees, and merges results back automatically.

### Installation

```bash
brew tap oftheangels/tap
brew install foreman
```

### Requirements

After installation, configure your AI provider key. `beads_rust` (`br`) is optional and only needed for importing legacy bead data with `foreman task import --from-beads`; it is not required for default Elixir-backed task execution.

#### Anthropic API key

```bash
# Add to ~/.zshrc or ~/.bash_profile
export ANTHROPIC_API_KEY="sk-ant-..."
```

Get an API key at [console.anthropic.com](https://console.anthropic.com/).

### Quick Start

```bash
# Verify Elixir server/projection health
foreman server doctor

# Initialize in your project
cd ~/your-project
foreman init --name my-project

# Create Elixir-backed tasks
foreman task create --title "Add user auth" --type feature

# Start default Elixir scheduler/server
foreman server start

# Monitor progress
foreman status
```

### Supported Platforms

| Platform | Architecture |
|----------|-------------|
| macOS | Apple Silicon (arm64) |
| macOS | Intel (x86_64) |
| Linux | x86_64 |
| Linux | ARM64 |

> **Windows:** Not supported via Homebrew. Use the [installer script](https://github.com/ldangelo/foreman/blob/main/install.ps1) or download a pre-built binary from [GitHub Releases](https://github.com/ldangelo/foreman/releases).

### Updating

```bash
brew update
brew upgrade foreman
```

### Uninstalling

```bash
brew uninstall foreman
brew untap oftheangels/tap
```

### More Information

- **Main repository:** [github.com/ldangelo/foreman](https://github.com/ldangelo/foreman)
- **Documentation:** [github.com/ldangelo/foreman#readme](https://github.com/ldangelo/foreman#readme)
- **Releases:** [github.com/ldangelo/foreman/releases](https://github.com/ldangelo/foreman/releases)
- **Issues:** [github.com/ldangelo/foreman/issues](https://github.com/ldangelo/foreman/issues)

---

## Tap Maintenance

This tap is automatically updated when new versions of Foreman are released via the [update-homebrew-tap](https://github.com/ldangelo/foreman/blob/main/.github/workflows/update-homebrew-tap.yml) GitHub Actions workflow.

To add a formula manually, submit a PR to this repository.
