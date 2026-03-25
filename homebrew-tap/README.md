# oftheangels/tap — Homebrew Tap

This is the official [Homebrew](https://brew.sh) tap for [Foreman](https://github.com/ldangelo/foreman) — a multi-agent AI coding orchestrator.

## Installation

```bash
# Add the tap
brew tap oftheangels/tap

# Install foreman
brew install foreman
```

Or as a one-liner:

```bash
brew install oftheangels/tap/foreman
```

## What is Foreman?

Foreman is an AI-powered engineering orchestrator that:
- Decomposes work into tasks using beads_rust (`br`) for task tracking
- Dispatches tasks to AI agents in isolated git worktrees
- Runs a pipeline: Explorer → Developer → QA → Reviewer → Finalize
- Merges completed work back to your main branch

## Requirements

After installing via Homebrew, you also need:

1. **br (beads_rust)** — task tracking CLI:
   ```bash
   cargo install beads_rust
   # or download binary from https://github.com/Dicklesworthstone/beads_rust/releases
   ```

2. **ANTHROPIC_API_KEY** — add to your shell profile:
   ```bash
   export ANTHROPIC_API_KEY=sk-ant-...
   ```

3. **Git** — for worktree management (usually pre-installed)

## Quick Start

```bash
cd ~/your-project
foreman init
br create --title "Add feature X" --type feature --priority 1
foreman run
foreman status
```

## Upgrading

```bash
brew upgrade foreman
```

## Uninstalling

```bash
brew uninstall foreman
brew untap oftheangels/tap
```

## Issues

Please report issues at [ldangelo/foreman](https://github.com/ldangelo/foreman/issues), not here.

## Formula Updates

The formula is automatically updated by the [release-binaries](https://github.com/ldangelo/foreman/blob/main/.github/workflows/release-binaries.yml) workflow whenever a new Foreman version is released.
