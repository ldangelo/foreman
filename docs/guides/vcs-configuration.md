# VCS Backend Configuration

> **Audience:** Developers and operators who want to configure which VCS backend Foreman uses.

Foreman supports two VCS backends — **git** and **Jujutsu (jj)** — and by default auto-detects which one to use. This guide explains the configuration system, configuration precedence, and how to troubleshoot common errors.

---

## Quick Reference

| Scenario | Configuration |
|----------|--------------|
| Pure git project (default) | No configuration needed — auto-detected |
| Jujutsu (colocated) project | See [Project-Level Config](#project-level-config) |
| Force git in a jj repo | Set `vcs.backend: git` in project config |
| Different backend per workflow | Set `vcs.backend` in the workflow YAML |
| Worker env passthrough | `FOREMAN_VCS_BACKEND=git\|jujutsu` (set automatically) |

---

## Auto-Detection (Default)

When no explicit VCS backend is configured, Foreman inspects the project root directory:

1. **`.jj/` directory present** → Jujutsu backend (takes precedence)
2. **`.git/` directory present** → Git backend
3. **Neither present** → Error: `VcsBackendFactory: auto-detection failed`

```
project/
├── .jj/        ← Jujutsu wins
├── .git/       ← git wins (only if .jj/ absent)
└── ...
```

> **Why does `.jj/` take precedence?** A colocated jj repo always has both `.jj/` and `.git/`. Checking for `.jj/` first ensures the richer jj interface is used when available.

---

## Configuration Precedence

When multiple sources specify a backend, the **highest-priority non-auto value wins**:

```
Workflow YAML vcs.backend   (highest priority)
    ↓  (if absent or 'auto')
~/.foreman/config.yaml vcs.backend
    ↓  (if absent or 'auto')
Auto-detection (.jj/ / .git/)   (lowest priority)
```

`'auto'` is treated as "no preference" — it passes through to the next level. Only a concrete value (`'git'` or `'jujutsu'`) wins at that level.

---

## Project-Level Config

Create `~/.foreman/config.yaml` to set Foreman-wide VCS defaults:

```yaml
# ~/.foreman/config.yaml

vcs:
  # Options: 'git' | 'jujutsu' | 'auto' (default: 'auto')
  backend: jujutsu

  # Git-specific options (only applies when backend is 'git' or 'auto' detects git)
  git:
    useTown: true    # Use git-town for branch management (default: true)

  # Jujutsu-specific options
  jujutsu:
    minVersion: "0.21.0"    # Minimum jj version; validated by 'foreman doctor'
```

### Config File Locations

| Location | Priority |
|----------|---------|
| `~/.foreman/config.yaml` | Preferred (YAML) |
| `~/.foreman/config.json` | Legacy fallback (JSON) |

If neither exists, Foreman uses auto-detection. The `~/.foreman/` directory is created by `foreman init`.

### JSON Format (legacy)

```json
{
  "vcs": {
    "backend": "jujutsu",
    "jujutsu": {
      "minVersion": "0.21.0"
    }
  }
}
```

---

## Workflow-Level Config

Workflows can override the project-level VCS config. This is useful when you want different workflows to use different VCS backends, or to document the expected backend in the workflow itself.

Add a top-level `vcs:` block to your workflow YAML:

```yaml
# ~/.foreman/workflows/default.yaml

name: default
vcs:
  backend: jujutsu    # Override project config for this workflow
  # Note: git/jujutsu sub-options are global-config-only (~/.foreman/config.yaml)
phases:
  - ...
```

> **When to use workflow-level VCS config:**
> - You maintain multiple workflow files for different teams (some using git, some using jj)
> - You want to document the expected VCS backend as part of the workflow definition
> - You need different backend-specific options per workflow

---

## Environment Variable (Internal)

When the Dispatcher spawns a worker process, it sets `FOREMAN_VCS_BACKEND` to the resolved backend name:

```
FOREMAN_VCS_BACKEND=git
FOREMAN_VCS_BACKEND=jujutsu
```

The worker uses this to reconstruct the same `VcsBackend` without re-detecting. **This variable is managed automatically** — you should not set it manually in most cases.

The worker reconstruction:

```ts
const vcs = await VcsBackendFactory.fromEnv(projectPath, process.env.FOREMAN_VCS_BACKEND);
```

If the env var is absent or unrecognized, it falls back to `git`.

---

## Git-Specific Options

### `vcs.git.useTown`

Controls whether `detectDefaultBranch()` uses git-town configuration.

```yaml
vcs:
  backend: git
  git:
    useTown: true    # Default: true
```

When `useTown: true`, `detectDefaultBranch()` first checks git-town config (`git config git-town.main-branch-name`) before falling back to `origin/HEAD` → `main` → `master`.

Set `useTown: false` if you don't use git-town and want to skip that lookup.

---

## Jujutsu-Specific Options

### `vcs.jujutsu.minVersion`

Specifies the minimum acceptable jj CLI version. Validated by `foreman doctor`.

```yaml
vcs:
  backend: jujutsu
  jujutsu:
    minVersion: "0.21.0"
```

If the installed jj version is older than `minVersion`, `foreman doctor` reports a warning:

```
⚠ jj version 0.18.0 is below minimum required 0.21.0
  Upgrade jj: https://martinvonz.github.io/jj/latest/install-and-setup
```

See [Jujutsu Considerations](./jujutsu-considerations.md) for version-specific notes.

---

## Examples by Use Case

### Pure Git Project

No configuration needed — auto-detection handles it:

```
project/
├── .git/
└── .foreman/   ← No config.yaml required
```

### Jujutsu Colocated Project

```yaml
# ~/.foreman/config.yaml
vcs:
  backend: jujutsu
  jujutsu:
    minVersion: "0.21.0"
```

Verify setup:

```bash
foreman doctor
# ✓ jj 0.24.0 >= 0.21.0 (required)
# ✓ colocated repo detected (.jj/ + .git/ present)
```

### Force Git on a Jujutsu Repo

Some teams run jujutsu locally but want Foreman to use the git backend for simplicity:

```yaml
# ~/.foreman/config.yaml
vcs:
  backend: git    # Explicitly use git even though .jj/ exists
```

### Multi-Team Project (Workflow Override)

Teams A and B use different VCS backends:

```yaml
# ~/.foreman/workflows/team-a.yaml
name: team-a
vcs:
  backend: git
phases: [...]

# ~/.foreman/workflows/team-b.yaml
name: team-b
vcs:
  backend: jujutsu
phases: [...]
```

Dispatch with the appropriate workflow:

```bash
br update <id> --set-labels "workflow:team-a"
foreman run
```

---

## Troubleshooting

### Auto-detection failed

```
Error: VcsBackendFactory: auto-detection failed — neither .git/ nor .jj/ found in "/path/to/project".
Initialize a git repository (git init) or jujutsu repository (jj git init) first.
```

**Cause:** No VCS repository found at the project root.

**Fix:**
```bash
git init && git commit --allow-empty -m "Initial commit"
# or
jj git init --colocate
```

### Invalid backend value

```
Error: ProjectConfig: ~/.foreman/config.yaml: vcs.backend must be 'git', 'jujutsu', or 'auto' (got: github)
```

**Cause:** Typo or unsupported backend in config.

**Fix:** Use exactly `git`, `jujutsu`, or `auto`.

### Config file parse error

```
Error: ProjectConfig: ~/.foreman/config.yaml: failed to parse YAML: unexpected token
```

**Cause:** Malformed YAML in `~/.foreman/config.yaml`.

**Fix:** Validate YAML syntax with `python3 -c "import os, yaml; yaml.safe_load(open(os.path.expanduser('~/.foreman/config.yaml')))"` or an online YAML validator.

### jj not found

```
Error: jj resolve failed: spawn jj ENOENT
```

**Cause:** `jj` binary is not on PATH.

**Fix:**
```bash
# Install jj (macOS)
brew install jj

# Verify
jj --version

# Run doctor
foreman doctor
```

### Non-colocated jj repo (Foreman limitation)

```
Error: JujutsuBackend requires a colocated repository (.jj/ and .git/ both present).
```

**Cause:** `jj init` was used instead of `jj git init --colocate`.

**Fix:**
```bash
# Initialize as colocated (creates both .jj/ and .git/)
jj git init --colocate

# Or if you have an existing non-colocated jj repo:
# Create a new colocated repo and migrate history
```

See [Jujutsu Considerations](./jujutsu-considerations.md#colocated-mode) for details.

### Wrong backend detected

If `foreman status` shows the wrong backend, check the resolution order:

```bash
# 1. Check workflow vcs block
cat ~/.foreman/workflows/default.yaml | grep -A5 "^vcs:"

# 2. Check project config
cat ~/.foreman/config.yaml

# 3. Check what's in project root
ls -la | grep -E "\.git|\.jj"

# 4. Run doctor
foreman doctor
```

---

## Verifying Configuration

```bash
# Run health checks (checks VCS config, binary availability, colocated mode)
foreman doctor

# Check which backend is active for a dispatched run
foreman status
# Output includes: "vcs: jujutsu" or "vcs: git"
```

---

## Related Documentation

- [VcsBackend Interface Reference](./vcs-backend-interface.md) — Full method reference for custom backends
- [Jujutsu Considerations](./jujutsu-considerations.md) — Jujutsu adoption guide
- [Workflow YAML Reference](../workflow-yaml-reference.md) — Full workflow config reference
