# Workflow YAML Reference

Workflow YAML files define the complete pipeline configuration for Foreman: which phases to run, which models to use, how to handle retries, and how to set up the development environment. Foreman is stack-agnostic — workflows work with any language or framework.

## File Locations

| Location | Purpose |
|----------|---------|
| `.foreman/workflows/{name}.yaml` | Project-local overrides (highest priority) |
| `src/defaults/workflows/{name}.yaml` | Bundled defaults (installed by `foreman init`) |

Foreman ships with two bundled workflows:
- **`default`** — Standard 5-phase pipeline (Explorer → Developer ⇄ QA → Reviewer → Finalize)
- **`smoke`** — Lightweight fast-validation pipeline using cheaper models

## Workflow Selection

Workflows are resolved per-bead:
1. First `workflow:<name>` label on the bead (e.g. `workflow:smoke`)
2. Bead type: `"smoke"` → smoke workflow, everything else → default workflow

```bash
# Dispatch with default workflow
br create --title="Add user auth" --type=feature
foreman run

# Dispatch with smoke workflow
br create --title="Smoke test" --type=task
br update <id> --set-labels "workflow:smoke"
foreman run
```

---

## Top-Level Fields

```yaml
name: default                    # Workflow name (required)
setup: [...]                     # Setup steps (optional)
setupCache: { key, path }        # Dependency cache (optional)
phases: [...]                    # Phase sequence (required)
```

### `name` (required)

The workflow identifier. Must match the filename (e.g. `default.yaml` → `name: default`).

```yaml
name: default
```

---

## Setup Steps

Setup steps run in the worktree **before any pipeline phase begins**. They prepare the environment (install dependencies, build, etc.).

### `setup` (optional)

An array of shell commands to execute sequentially.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `command` | string | *required* | Shell command to run (split on whitespace) |
| `description` | string | — | Human-readable label for logs |
| `failFatal` | boolean | `true` | If `true`, a non-zero exit aborts the pipeline |

### Node.js Example

```yaml
setup:
  - command: npm install --prefer-offline --no-audit
    description: Install Node.js dependencies
    failFatal: true
```

### .NET Example

```yaml
setup:
  - command: dotnet restore --no-interactive
    description: Restore NuGet packages
    failFatal: true
  - command: dotnet build --no-restore --configuration Release
    description: Build solution
    failFatal: true
```

### Go Example

```yaml
setup:
  - command: go mod download
    description: Download Go modules
    failFatal: true
  - command: go build ./...
    description: Verify build
    failFatal: false
```

### Multi-Step Example (Node.js monorepo)

```yaml
setup:
  - command: npm install --prefer-offline --no-audit
    description: Install root dependencies
    failFatal: true
  - command: npm run build --workspace=packages/shared
    description: Build shared package
    failFatal: true
  - command: npx prisma generate
    description: Generate Prisma client
    failFatal: false
```

---

## Setup Cache

The `setupCache` block enables a shared dependency cache across worktrees. Instead of running setup steps for every bead, Foreman hashes a key file and symlinks the cached dependency directory. **First bead pays the full install cost; subsequent beads get a symlink in <1 second.**

### `setupCache` (optional)

| Field | Type | Description |
|-------|------|-------------|
| `key` | string | File path (relative to worktree root) to hash for cache identity |
| `path` | string | Directory (relative to worktree root) to cache and symlink |

**How it works:**
1. Hash the `key` file → e.g. `a1b2c3d4`
2. Check `.foreman/setup-cache/a1b2c3d4/` for a cached copy
3. **Cache hit** → symlink `<worktree>/<path>` → cache dir (skip setup steps)
4. **Cache miss** → run setup steps → move `<path>` to cache → symlink back

**Cache invalidation:** When the key file changes (e.g. new dependency added to `package-lock.json`), the hash changes and a new cache entry is created. Old entries remain until cleaned with `foreman worktree clean --purge-cache`.

### Node.js

```yaml
setup:
  - command: npm install --prefer-offline --no-audit
    description: Install Node.js dependencies
    failFatal: true
setupCache:
  key: package-lock.json
  path: node_modules
```

### .NET

```yaml
setup:
  - command: dotnet restore --no-interactive
    description: Restore NuGet packages
    failFatal: true
setupCache:
  key: Directory.Packages.props      # Central package management file
  path: packages                     # NuGet packages directory
```

Alternative for projects without central package management:

```yaml
setupCache:
  key: MyProject.csproj             # Or the solution's .csproj file
  path: obj                         # Restore output
```

### Go

```yaml
setup:
  - command: go mod download
    description: Download Go modules
    failFatal: true
setupCache:
  key: go.sum
  path: vendor                      # If using go mod vendor
```

### Python

```yaml
setup:
  - command: pip install -r requirements.txt
    description: Install Python dependencies
    failFatal: true
setupCache:
  key: requirements.txt
  path: .venv
```

### Rust

```yaml
setup:
  - command: cargo fetch
    description: Fetch Rust crate dependencies
    failFatal: true
setupCache:
  key: Cargo.lock
  path: target
```

---

## Phases

The `phases` array defines the ordered sequence of pipeline phases. Each phase runs an AI agent with a specific prompt, model, and set of constraints. **New phases require zero TypeScript changes** — just add a YAML entry and a prompt file.

### Phase Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | *required* | Phase identifier (used in logs, mail, labels) |
| `prompt` | string | — | Prompt file name in `.foreman/prompts/{workflow}/` |
| `model` | string | — | Single model shorthand or full ID (deprecated, use `models`) |
| `models` | map | — | Priority-based model overrides (see below) |
| `maxTurns` | number | — | Maximum agent turns before timeout |
| `artifact` | string | — | Expected output filename (e.g. `QA_REPORT.md`) |
| `skipIfArtifact` | string | — | Skip phase if this file already exists (resume from crash) |
| `verdict` | boolean | `false` | Parse PASS/FAIL from artifact content |
| `retryWith` | string | — | On verdict FAIL, loop back to this phase name |
| `retryOnFail` | number | `0` | Maximum retry count for verdict failures |
| `mail` | object | — | Mail hook configuration (see below) |
| `files` | object | — | File reservation configuration (see below) |
| `builtin` | boolean | `false` | Phase implemented in TypeScript, not as agent prompt |

### Models

The `models` map supports priority-based model selection. Keys are `"default"` (required) or `"P0"` through `"P4"` (optional overrides). The bead's priority determines which model is used.

**Model shorthands:**

| Shorthand | Full Model ID |
|-----------|---------------|
| `haiku` | `anthropic/claude-haiku-4-5` |
| `sonnet` | `anthropic/claude-sonnet-4-6` |
| `opus` | `anthropic/claude-opus-4-6` |

Full model IDs are also accepted for any provider:

| Provider | Example |
|----------|---------|
| Anthropic | `anthropic/claude-sonnet-4-6` |
| OpenAI | `openai/gpt-4o` |
| Google | `google/gemini-2.5-pro` |

**Examples:**

```yaml
# Simple: same model for all priorities
models:
  default: sonnet

# Priority-based: critical beads get a more capable model
models:
  default: sonnet
  P0: opus
  P1: sonnet

# Non-Anthropic provider
models:
  default: openai/gpt-4o
  P0: openai/o3

# Cost-optimized: cheap model for most work, upgrade for critical
models:
  default: haiku
  P0: opus
  P1: sonnet
  P2: sonnet
```

**Priority scale:** P0 = critical, P1 = high, P2 = medium, P3 = low, P4 = backlog.

### Mail Hooks

The `mail` block controls lifecycle notifications sent via Agent Mail.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `onStart` | boolean | `true` | Send `phase-started` to foreman before phase runs |
| `onComplete` | boolean | `true` | Send `phase-complete` to foreman after phase succeeds |
| `onFail` | string | — | On verdict FAIL, send artifact content to this agent |
| `forwardArtifactTo` | string | — | On success, forward artifact to this agent's inbox |

```yaml
mail:
  onStart: true
  onComplete: true
  onFail: developer              # Send QA feedback to developer on FAIL
  forwardArtifactTo: foreman     # Forward REVIEW.md to foreman inbox
```

### File Reservations

The `files` block reserves the worktree directory during a phase to prevent concurrent access.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `reserve` | boolean | `false` | Reserve the worktree before phase runs |
| `leaseSecs` | number | `600` | Lease duration in seconds |

```yaml
files:
  reserve: true
  leaseSecs: 600                 # 10 minutes
```

### Retry Loops

Phases with `verdict: true` parse PASS/FAIL from their artifact. On FAIL, `retryWith` loops back to the named phase for another attempt.

```yaml
# QA fails → send feedback to developer → developer retries → QA retries
- name: qa
  verdict: true
  retryWith: developer           # Loop back to developer on FAIL
  retryOnFail: 2                 # Max 2 retries (3 total attempts)
  mail:
    onFail: developer            # Send QA_REPORT.md to developer inbox

# Reviewer fails → same pattern, independent retry budget
- name: reviewer
  verdict: true
  retryWith: developer
  retryOnFail: 1                 # Max 1 retry (2 total attempts)
  mail:
    onFail: developer
```

QA and Reviewer have **independent retry budgets** — QA exhausting its retries does not affect Reviewer's ability to retry.

---

## Complete Examples

### Node.js (Default)

```yaml
name: default
setup:
  - command: npm install --prefer-offline --no-audit
    description: Install Node.js dependencies
    failFatal: true
setupCache:
  key: package-lock.json
  path: node_modules
phases:
  - name: explorer
    prompt: explorer.md
    models:
      default: haiku
      P0: sonnet
    maxTurns: 30
    artifact: EXPLORER_REPORT.md
    skipIfArtifact: EXPLORER_REPORT.md
    mail:
      onStart: true
      onComplete: true
      forwardArtifactTo: developer

  - name: developer
    prompt: developer.md
    models:
      default: sonnet
      P0: opus
    maxTurns: 80
    artifact: DEVELOPER_REPORT.md
    mail:
      onStart: true
      onComplete: true
    files:
      reserve: true
      leaseSecs: 600

  - name: qa
    prompt: qa.md
    models:
      default: sonnet
      P0: opus
    maxTurns: 30
    artifact: QA_REPORT.md
    verdict: true
    retryWith: developer
    retryOnFail: 2
    mail:
      onStart: true
      onComplete: true
      onFail: developer

  - name: reviewer
    prompt: reviewer.md
    models:
      default: sonnet
      P0: opus
    maxTurns: 20
    artifact: REVIEW.md
    verdict: true
    retryWith: developer
    retryOnFail: 1
    mail:
      onStart: true
      onComplete: true
      onFail: developer
      forwardArtifactTo: foreman

  - name: finalize
    prompt: finalize.md
    models:
      default: haiku
    maxTurns: 20
    mail:
      onStart: true
      onComplete: true
```

### .NET

```yaml
name: dotnet
setup:
  - command: dotnet restore --no-interactive
    description: Restore NuGet packages
    failFatal: true
  - command: dotnet build --no-restore --configuration Release
    description: Build solution
    failFatal: true
setupCache:
  key: Directory.Packages.props
  path: packages
phases:
  - name: explorer
    prompt: explorer.md
    models:
      default: haiku
      P0: sonnet
    maxTurns: 30
    artifact: EXPLORER_REPORT.md
    skipIfArtifact: EXPLORER_REPORT.md
    mail:
      onStart: true
      onComplete: true
      forwardArtifactTo: developer

  - name: developer
    prompt: developer.md
    models:
      default: sonnet
      P0: opus
    maxTurns: 80
    artifact: DEVELOPER_REPORT.md
    mail:
      onStart: true
      onComplete: true
    files:
      reserve: true
      leaseSecs: 900

  - name: qa
    prompt: qa.md
    models:
      default: sonnet
    maxTurns: 40
    artifact: QA_REPORT.md
    verdict: true
    retryWith: developer
    retryOnFail: 2
    mail:
      onStart: true
      onComplete: true
      onFail: developer

  - name: reviewer
    prompt: reviewer.md
    models:
      default: sonnet
      P0: opus
    maxTurns: 20
    artifact: REVIEW.md
    verdict: true
    retryWith: developer
    retryOnFail: 1
    mail:
      onStart: true
      onComplete: true
      onFail: developer
      forwardArtifactTo: foreman

  - name: finalize
    prompt: finalize.md
    models:
      default: haiku
    maxTurns: 20
    mail:
      onStart: true
      onComplete: true
```

### Go

```yaml
name: golang
setup:
  - command: go mod download
    description: Download Go modules
    failFatal: true
  - command: go build ./...
    description: Verify build compiles
    failFatal: false
setupCache:
  key: go.sum
  path: vendor
phases:
  - name: explorer
    prompt: explorer.md
    models:
      default: haiku
    maxTurns: 25
    artifact: EXPLORER_REPORT.md
    skipIfArtifact: EXPLORER_REPORT.md
    mail:
      onStart: true
      onComplete: true
      forwardArtifactTo: developer

  - name: developer
    prompt: developer.md
    models:
      default: sonnet
      P0: opus
    maxTurns: 60
    artifact: DEVELOPER_REPORT.md
    mail:
      onStart: true
      onComplete: true
    files:
      reserve: true
      leaseSecs: 600

  - name: qa
    prompt: qa.md
    models:
      default: sonnet
    maxTurns: 30
    artifact: QA_REPORT.md
    verdict: true
    retryWith: developer
    retryOnFail: 2
    mail:
      onStart: true
      onComplete: true
      onFail: developer

  - name: reviewer
    prompt: reviewer.md
    models:
      default: sonnet
    maxTurns: 20
    artifact: REVIEW.md
    verdict: true
    retryWith: developer
    retryOnFail: 1
    mail:
      onStart: true
      onComplete: true
      onFail: developer
      forwardArtifactTo: foreman

  - name: finalize
    prompt: finalize.md
    models:
      default: haiku
    maxTurns: 20
    mail:
      onStart: true
      onComplete: true
```

### Smoke Test (Lightweight)

```yaml
name: smoke
setup:
  - command: npm install --prefer-offline --no-audit
    description: Install dependencies
    failFatal: true
setupCache:
  key: package-lock.json
  path: node_modules
phases:
  - name: explorer
    prompt: explorer.md
    models:
      default: haiku
    maxTurns: 5
    artifact: EXPLORER_REPORT.md
    skipIfArtifact: EXPLORER_REPORT.md
    mail:
      onStart: true
      onComplete: true
      forwardArtifactTo: developer

  - name: developer
    prompt: developer.md
    models:
      default: haiku
    maxTurns: 5
    artifact: DEVELOPER_REPORT.md
    mail:
      onStart: true
      onComplete: true

  - name: qa
    prompt: qa.md
    models:
      default: haiku
    maxTurns: 5
    artifact: QA_REPORT.md
    verdict: true
    retryWith: developer
    retryOnFail: 2
    mail:
      onStart: true
      onComplete: true
      onFail: developer

  - name: reviewer
    prompt: reviewer.md
    models:
      default: sonnet
    maxTurns: 5
    artifact: REVIEW.md
    verdict: true
    retryWith: developer
    retryOnFail: 1
    mail:
      onStart: true
      onComplete: true
      onFail: developer
      forwardArtifactTo: foreman

  - name: finalize
    prompt: finalize.md
    models:
      default: haiku
    maxTurns: 10
    mail:
      onStart: true
      onComplete: true
```

---

## Custom Phases

You can add custom phases beyond the default five. Each custom phase needs:
1. A YAML entry in the workflow
2. A prompt file in `.foreman/prompts/{workflow}/`

```yaml
phases:
  - name: security-scan
    prompt: security-scan.md
    models:
      default: opus              # Security review benefits from best model
    maxTurns: 20
    artifact: SECURITY_REPORT.md
    verdict: true
    retryWith: developer
    retryOnFail: 1
    mail:
      onStart: true
      onComplete: true
      onFail: developer
```

The prompt file (`.foreman/prompts/default/security-scan.md`) defines the agent's instructions, using `{{seedId}}`, `{{seedTitle}}`, `{{seedDescription}}`, and other template variables.

---

## Custom Workflows

Create a new workflow by adding a YAML file to `.foreman/workflows/`:

```bash
# Create a minimal workflow for documentation tasks
cat > .foreman/workflows/docs.yaml << 'EOF'
name: docs
setup:
  - command: npm install --prefer-offline --no-audit
    description: Install dependencies
    failFatal: false
phases:
  - name: developer
    prompt: developer.md
    models:
      default: haiku
    maxTurns: 20
    artifact: DEVELOPER_REPORT.md
    mail:
      onStart: true
      onComplete: true

  - name: finalize
    prompt: finalize.md
    models:
      default: haiku
    maxTurns: 10
    mail:
      onStart: true
      onComplete: true
EOF

# Assign a bead to the custom workflow
br update <id> --set-labels "workflow:docs"
foreman run
```
