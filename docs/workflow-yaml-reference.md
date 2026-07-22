# Workflow YAML Reference

Workflow YAML files define the complete pipeline configuration for Foreman: which phases to run, which models to use, how to handle retries, and how to set up the development environment. Foreman is stack-agnostic — workflows work with any language or framework.

## File Locations

| Location | Purpose |
|----------|---------|
| `~/.foreman/workflows/{name}.yaml` | Global overrides (highest priority) |
| `src/defaults/workflows/{name}.yaml` | Bundled defaults (installed by `foreman init`) |

Foreman ships with bundled workflows for common task types:
- **`default`** — Standard pipeline with implementation, validation, PR creation, PR wait, and merge gates
- **`task` / `feature` / `bug`** — Type-specific workflows with post-finalize PR phases (`create-pr → pr-wait → merge`); PR wait requires a short stable-ready window, and merge re-waits if a late GitHub check appears
- **`epic`** — Planning + implementation workflow (`prd → trd → implement → developer → qa → finalize`) followed by the same PR wait/merge gates
- **`smoke`** — Lightweight fast-validation pipeline using cheaper models and no PR/merge gates

## Workflow Selection

Workflows are resolved per task:
1. `foreman run --workflow <name>` CLI override (applies to every task in that dispatch; fails fast if the workflow cannot be loaded)
2. First `workflow:<name>` label on the task (e.g. `workflow:smoke`)
3. Workflow-declared `task_type` in YAML (for example, `task_type: bug` maps bug tasks to that workflow)
4. `taskTypeWorkflowMap[task.type]` in project config (compatibility fallback)
5. `taskTypeWorkflowMap.default`
6. File-existence fallback (`~/.foreman/workflows/<type>.yaml` or bundled defaults)

Startup/doctor validation fails if multiple workflows declare the same `task_type`, because type-based dispatch would be ambiguous.

```bash
# Dispatch with default workflow
native task store create --title="Add user auth" --type=feature
foreman run

# Dispatch everything with a custom workflow that omits phases you do not want
foreman run --workflow my-fast-workflow

# Dispatch with smoke workflow
foreman task create --title "Smoke test" --type task --label workflow:smoke
foreman run

# Directly run a workflow for a task regardless of current task state
foreman run task <task-id> task --project <name> --no-watch
```

---

## Top-Level Fields

```yaml
name: default                    # Workflow name (required)
task_type: task                  # Task type this workflow handles (optional)
setup: [...]                     # Setup steps (optional)
setupCache: { key, path }        # Dependency cache (optional)
vcs: { backend, git, jujutsu }   # VCS backend override (optional)
phases: [...]                    # Phase sequence (required)
```

PR creation and merging are controlled by explicit phases (`create-pr`, `pr-wait`, `merge`). Top-level `merge:` and `pr:` workflow tags are not supported.

### `name` (required)

The workflow identifier. Must match the filename (e.g. `default.yaml` → `name: default`).

```yaml
name: default
```

### `task_type` (optional)

Declares which task type should dispatch to this workflow when there is no CLI override or `workflow:<name>` label.

```yaml
name: bug
task_type: bug
```

Each task type may be declared by at most one workflow. Duplicate declarations are reported by `foreman doctor` and should be fixed before dispatch.

---

## VCS Configuration

The optional top-level `vcs:` block overrides the global VCS configuration in `~/.foreman/config.yaml` for this specific workflow.

### `vcs` (optional)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `backend` | string | `'auto'` | VCS backend to use: `'git'`, `'jujutsu'`, or `'auto'` |

> **Note:** Backend-specific sub-options (`git.useTown`, `jujutsu.minVersion`) are only available in the global `~/.foreman/config.yaml`, not in workflow YAML.

**Resolution priority** (highest wins): workflow `vcs.backend` → global `~/.foreman/config.yaml` `vcs.backend` → auto-detection.

```yaml
# Force git even if .jj/ is present
vcs:
  backend: git

# Require jujutsu
vcs:
  backend: jujutsu

# Explicit auto-detection (same as omitting the vcs block)
vcs:
  backend: auto
```

**When to set workflow-level VCS:**
- Multi-team monorepo where teams use different VCS backends
- Documenting the expected VCS backend in the workflow definition
- Temporarily overriding the project default for a specific workflow (e.g. a migration workflow)

See [VCS Configuration Guide](./guides/vcs-configuration.md) for full details.

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

The `setupCache` block enables a shared dependency cache across worktrees. Instead of running setup steps for every task, Foreman hashes a key file and symlinks the cached dependency directory. **First task pays the full install cost; subsequent tasks get a symlink in <1 second.**

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

The `phases` array defines the ordered sequence of pipeline phases. Most phases run an AI agent with a prompt, model, and constraints. Builtin phases run deterministic TypeScript code instead. **New prompt phases require zero TypeScript changes** — just add a YAML entry and a prompt file.

### Phase Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | *required* | Phase identifier (used in logs, mail, labels) |
| `prompt` | string | — | Prompt file name in `~/.foreman/prompts/{workflow}/` |
| `model` | string | — | Single model shorthand or full ID (deprecated, use `models`) |
| `models` | map | — | Priority-based model overrides (see below) |
| `maxTurns` | number | — | Maximum agent turns before timeout |
| `artifact` | string | — | Expected output path. Bundled workflows write phase reports under `{task.projectReportsDir}` (for example, `{task.projectReportsDir}/QA_REPORT.md`) so runtime reports stay outside repository commits. |
| `skipIfArtifact` | string | — | Skip phase if this file already exists (resume from crash) |
| `verdict` | boolean | `false` | Parse PASS/FAIL from artifact content |
| `retryWith` | string | — | On verdict FAIL, loop back to this phase name |
| `retryOnFail` | number | `0` | Maximum retry count for verdict failures |
| `mail` | object | — | Mail hook configuration (see below) |
| `files` | object | — | File reservation configuration (see below) |
| `builtin` | boolean | `false` | Phase implemented in TypeScript, not as agent prompt |
| `checkpointPr` | boolean | `false` | After a successful dirty phase, commit and push the worktree, then create or update a draft PR when the workflow also has a `create-pr` phase |
| `rebaseAfterPhase` | string | — | After a phase completes successfully, run `vcs.rebase()` against the specified target branch before the next phase dispatches. When rebase fails (conflicts), the phase is marked failed and the pipeline stops. Requires a VCS backend to be configured. |

### Documentation Phase

Bundled workflows include a prompt-driven `documentation` phase before `finalize`. The shared prompt lives at `src/defaults/prompts/default/documentation.md` and is installed as `~/.foreman/prompts/default/documentation.md`. It requires agents to check whether the task changed behavior, commands, workflows, prompts, setup, troubleshooting, or operator expectations, then update the affected docs (`CLAUDE.md`, `AGENTS.md`, `README.md`, and `docs/cli-reference.md`) or write `{task.projectReportsDir}/DOCUMENTATION_REPORT.md` explaining why no doc change was needed. For documentation-focused tasks where earlier phases already changed docs, this phase should verify the existing doc diff and report instead of broadening scope or adding churn unless the diff clearly misses the task acceptance criteria.

Prompt phases with artifacts under `{task.projectReportsDir}` must instruct the agent to write the rendered report-directory artifact path. Foreman fails fast before spawning the agent when a stale prompt omits that path or points the report at the worktree root.

```yaml
  - name: documentation
    prompt: documentation.md
    artifact: "{task.projectReportsDir}/DOCUMENTATION_REPORT.md"
```

### Finalize Phase

Bundled workflows use a deterministic builtin `finalize` phase. It runs dependency install/typecheck, stages/restores workspace-safe files, commits, rebases when the target changed after QA, conditionally reruns tests, pushes `foreman/<task-id>`, and writes `FINALIZE_VALIDATION.md` plus `FINALIZE_REPORT.md`. Earlier mutating phases may already have pushed draft PR checkpoints via `checkpointPr`; finalize remains the authoritative final commit before the explicit PR phases. Keep `artifact`, `verdict`, `retryWith`, and `retryOnFail` on the phase so validation failures still loop back through remediation.

```yaml
  - name: finalize
    builtin: true
    artifact: "{task.projectReportsDir}/FINALIZE_VALIDATION.md"
    maxTurns: 30
    verdict: true
    retryWith: developer
    retryOnFail: 1
```

### PR and Merge Phases

Bundled merge-capable workflows express PR and merge behavior as phases, not top-level tags:

```yaml
  - name: create-pr
    builtin: true
    artifact: "{task.projectReportsDir}/PR_METADATA.json"

  - name: pr-wait
    builtin: true
    artifact: "{task.projectReportsDir}/PR_WAIT_REPORT.md"
    retryWithByReason:
      "ci_failed:": cicd-developer
      "merge_conflict:": merge-resolver

  - name: merge
    builtin: true
    artifact: "{task.projectReportsDir}/MERGE_REPORT.md"
```

- `checkpointPr: true` on mutating prompt/command phases checkpoints committed work to the task branch and ensures a draft PR exists as soon as that phase produces changes. Bundled merge-capable workflows set it on developer/fix/remediation/documentation phases, not on read-only, QA/review, `finalize`, `create-pr`, `pr-wait`, or `merge`.
- `create-pr` refreshes or reuses the same PR, marks an existing draft ready, and writes `PR_METADATA.json`.
- `pr-wait` waits for required checks/review readiness and can route failures.
- `merge` performs the final PR readiness gate and queues refinery merge processing.
- Omit `merge` for workflows that should not merge. Omit `create-pr`/`pr-wait` for workflows that should not create or wait on PRs; `checkpointPr` has no effect without `create-pr`.

### Models

The `models` map supports priority-based model selection. Keys are `"default"` (required) or `"P0"` through `"P4"` (optional overrides). The task's priority determines which model is used.

**Bundled workflow models:** Foreman's bundled workflows (`default`, `feature`, `bug`, `task`, `epic`, `smoke`) use the model names declared in their YAML. The shorthands below are available for custom workflows.

**Model shorthands:**

| Shorthand | Full Model ID |
|-----------|---------------|
| `haiku` | `anthropic/claude-haiku-4-5` |
| `sonnet` | `anthropic/claude-sonnet-4-6` |
| `opus` | `anthropic/claude-opus-4-6` |
| `MiniMax` | `MiniMax` |
| `MiniMax-highspeed` | `MiniMax-highspeed` |

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

# Priority-based: critical tasks get a more capable model
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

Phases with `verdict: true` parse PASS/FAIL from their artifact. On FAIL, `retryWith` loops back to the named phase for another attempt. Prefer a focused retry-only repair phase for generic QA/review/finalize findings so the agent fixes only the reported assertion instead of reopening broad task scope.

```yaml
# QA fails → send feedback to repair → repair patches only the failure → QA retries
- name: repair
  retryOnly: true
  prompt: repair.md
  artifact: "{task.projectReportsDir}/FIX_REPORT.md"

- name: qa
  verdict: true
  retryWith: repair             # Loop back to focused repair on FAIL
  retryOnFail: 2                # Max 2 retries (3 total attempts)
  mail:
    onFail: repair              # Send QA_REPORT.md to repair inbox

# Reviewer fails → same pattern, independent retry budget
- name: reviewer
  verdict: true
  retryWith: repair
  retryOnFail: 1                # Max 1 retry (2 total attempts)
  mail:
    onFail: repair
```

QA and Reviewer have **independent retry budgets** — QA exhausting its retries does not affect Reviewer's ability to retry. Bundled `task` and `docs` workflows use `repair.md` for generic verdict retries while keeping specialized `retryWithByReason` targets for CI, CodeRabbit, and merge-conflict failures. The bundled `cicd-developer` and `cr-developer` prompts keep those retries narrow: they start from the failed check or cited review finding, run focused proving commands before broad reruns, and require report evidence for each addressed gate.

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
    maxTurns: 12
    artifact: "{task.projectReportsDir}/EXPLORER_REPORT.md"
    skipIfArtifact: "{task.projectReportsDir}/EXPLORER_REPORT.md"
    mail:
      onStart: true
      onComplete: true
      forwardArtifactTo: developer

  - name: developer
    prompt: developer.md
    models:
      default: sonnet
      P0: opus
    maxTurns: 50
    artifact: "{task.projectReportsDir}/DEVELOPER_REPORT.md"
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
    artifact: "{task.projectReportsDir}/QA_REPORT.md"
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
    artifact: "{task.projectReportsDir}/REVIEW.md"
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
    maxTurns: 12
    artifact: "{task.projectReportsDir}/EXPLORER_REPORT.md"
    skipIfArtifact: "{task.projectReportsDir}/EXPLORER_REPORT.md"
    mail:
      onStart: true
      onComplete: true
      forwardArtifactTo: developer

  - name: developer
    prompt: developer.md
    models:
      default: sonnet
      P0: opus
    maxTurns: 50
    artifact: "{task.projectReportsDir}/DEVELOPER_REPORT.md"
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
    artifact: "{task.projectReportsDir}/QA_REPORT.md"
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
    artifact: "{task.projectReportsDir}/REVIEW.md"
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
    artifact: "{task.projectReportsDir}/EXPLORER_REPORT.md"
    skipIfArtifact: "{task.projectReportsDir}/EXPLORER_REPORT.md"
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
    artifact: "{task.projectReportsDir}/DEVELOPER_REPORT.md"
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
    artifact: "{task.projectReportsDir}/QA_REPORT.md"
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
    artifact: "{task.projectReportsDir}/REVIEW.md"
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
    artifact: "{task.projectReportsDir}/EXPLORER_REPORT.md"
    skipIfArtifact: "{task.projectReportsDir}/EXPLORER_REPORT.md"
    mail:
      onStart: true
      onComplete: true
      forwardArtifactTo: developer

  - name: developer
    prompt: developer.md
    models:
      default: haiku
    maxTurns: 5
    artifact: "{task.projectReportsDir}/DEVELOPER_REPORT.md"
    mail:
      onStart: true
      onComplete: true

  - name: qa
    prompt: qa.md
    models:
      default: haiku
    maxTurns: 5
    artifact: "{task.projectReportsDir}/QA_REPORT.md"
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
    artifact: "{task.projectReportsDir}/REVIEW.md"
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
2. A prompt file in `~/.foreman/prompts/{workflow}/`

```yaml
phases:
  - name: security-scan
    prompt: security-scan.md
    models:
      default: opus              # Security review benefits from best model
    maxTurns: 20
    artifact: "{task.projectReportsDir}/SECURITY_REPORT.md"
    verdict: true
    retryWith: developer
    retryOnFail: 1
    mail:
      onStart: true
      onComplete: true
      onFail: developer
```

The prompt file (`~/.foreman/prompts/default/security-scan.md`) defines the agent's instructions, using `{{taskId}}`, `{{taskTitle}}`, `{{taskDescription}}`, and other template variables.

---

## Custom Workflows

Create a new workflow by adding a YAML file to `~/.foreman/workflows/`:

```bash
# Create a minimal workflow for documentation tasks
cat > ~/.foreman/workflows/docs.yaml << 'EOF'
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
    artifact: "{task.projectReportsDir}/DEVELOPER_REPORT.md"
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

# Assign a task to the custom workflow
native task store update <id> --set-labels "workflow:docs"
foreman run
```
