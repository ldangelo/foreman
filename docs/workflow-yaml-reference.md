# Workflow YAML Reference

Workflow YAML files define the complete pipeline configuration for Foreman: which phases to run, which models to use, how to handle retries, and how to set up the development environment. Foreman is stack-agnostic — workflows work with any language or framework.

## File Locations

| Location | Purpose |
|----------|---------|
| Explicit YAML path | Highest priority for one run/command |
| `.foreman/workflows/{name}.yaml|.yml` | Project overrides |
| `~/.foreman/workflows/{name}.yaml|.yml` | Global overrides |
| `src/defaults/workflows/{name}.yaml` | Bundled defaults (installed by `foreman init`) |

Foreman ships with bundled workflows for common task types:
- **`default`** — Standard pipeline with implementation, validation, PR creation, PR wait/review, and merge gates
- **`quick`** — Fast variant of `default` without the explorer and reviewer phases (`developer ⇄ qa → finalize → PR gates → merge`). YAML-first replacement for the retired `--skip-explore`/`--skip-review` flags
- **`task` / `feature` / `bug`** — Type-specific workflows with post-finalize PR phases (`create-pr → pr-wait → prepare-pr-review → pr-review → merge`); PR wait requires a short stable-ready window, and merge re-waits if a late GitHub check appears
- **`epic`** — Planning + implementation workflow (`prd → trd → implement → developer → qa → finalize`) followed by the same PR wait/review/merge gates
- **`smoke`** — Lightweight fast-validation pipeline using cheaper models

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
br create --title="Add user auth" --type=feature
foreman run

# Dispatch everything with the quick workflow (no explorer/reviewer phases)
foreman run --workflow quick

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

The `phases` array defines the ordered sequence of pipeline phases. Each phase binds a workflow label (`name`) to a reusable execution `action`. Most phases use the `prompt-agent` action with a prompt, model, and constraints. Builtin phases use deterministic TypeScript actions such as `finalize`, `create-pr`, or `merge`. **New prompt phases require zero TypeScript changes** — just add a YAML entry and a prompt file.

### Phase Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | *required* | Phase identifier (used in logs, mail, labels) |
| `action` | string | inferred | Reusable execution action (`prepare-worktree`, `setup-workspace`, `write-task-context`, `prompt-agent`, `command-agent`, `bash`, `finalize`, `cli-review`, `create-pr`, `pr-wait`, `prepare-pr-review`, `merge`, or custom) |
| `prompt` | string | — | Prompt file name in `~/.foreman/prompts/{workflow}/` for `prompt-agent` phases |
| `model` | string | — | Single model shorthand or full ID (deprecated, use `models`) |
| `models` | map | — | Priority-based model overrides (see below) |
| `maxTurns` | number | — | Maximum agent turns before timeout |
| `artifact` | string | — | Expected output path. Bundled workflows write phase reports under `{task.projectReportsDir}` (for example, `{task.projectReportsDir}/QA_REPORT.md`) so runtime reports stay outside repository commits. |
| `skipIfArtifact` | string | — | Skip phase if this file already exists (resume from crash) |
| `verdict` | boolean | `false` | Parse PASS/FAIL from artifact content |
| `retryWith` | string | — | On verdict FAIL, loop back to this phase name |
| `retryOnFail` | number | `0` | Maximum retry count for this failing/source phase. The budget is charged to the phase that produced FAIL, not to the `retryWith` target. |
| `mail` | object | — | Mail hook configuration (see below) |
| `files` | object | — | File reservation configuration (see below) |
| `contract` | object | — | Optional artifact completion contract used by phase overwatch |
| `capabilities` | string[] | `[]` | Advisory host capabilities used by custom/project action modules, e.g. `vcs`, `mail`, `task-store`, `network`, `exec` |
| `overwatch` | object | — | Optional runtime supervisor/policy controls for runaway phase prevention |
| `builtin` | boolean | `false` | Backward-compatible marker for TypeScript-backed phases; prefer explicit `action` in new workflows |

### Phase Overwatch

Prompt phases can enable `overwatch` to make `maxTurns` an emergency fuse instead of the only runaway-control mechanism. Overwatch tracks tool calls, validates the phase artifact, blocks known drift patterns, and returns steering messages through blocked tool-call results. When the artifact is valid, the stop instruction is returned as non-error terminal guidance so the agent is less likely to enter error-recovery tool loops. If a phase hits a budget/max-turn stop after producing a valid artifact and `continueIfArtifactValidOnBudgetStop: true`, Foreman accepts the phase evidence and continues.

Bundled default/feature/bug workflows enable overwatch across prompt-backed phases and use the fast path by default: Explorer/fix hands off directly to Developer, then QA/review/finalize validate the patch. The opt-in `tdd` workflow inserts Test Red and Test Review before Developer. Test Red writes only 1–3 focused failing tests and is gated on test-only diffs plus expected failing-test evidence; synced Foreman runtime config under `.foreman/workflows/**` and `.foreman/prompts/**` is ignored by this diff gate. Test Review is a verdict phase that verifies those tests cover the acceptance contract before implementation and retries Red once. Developer/fix follows `EXPLORER_REPORT.md`, reviewed red tests when present, or focused retry feedback, blocks test execution and broad repo discovery, and requires changed-files/QA-handoff evidence. QA is verification-only: it reviews changed files, runs targeted commands, blocks broad discovery/full-suite commands, and requires a verdict/report contract. During the Elixir cutover, runtime/state/MCP/activity-feed tasks should target the Elixir event/projection path plus current CLI/read-model consumers, not legacy Postgres/native TS storage unless explicitly requested. Review and documentation phases stop after bounded evidence and valid reports.

```yaml
  - name: explorer
    artifact: "{task.projectReportsDir}/EXPLORER_REPORT.md"
    contract:
      requiredSections: [Summary, Likely edit targets, Test targets, Risks]
      completion:
        minEditTargets: 1
        maxEditTargets: 3
        requireTestTargets: true
      allowedScope:
        canWriteOnly: [EXPLORER_REPORT.md, SESSION_LOG.md]
    overwatch:
      enabled: true
      mode: enforce # or warn/off
      continueIfArtifactValidOnBudgetStop: true
      maxSteersPerPhase: 3
      forceArtifactAfterSteers: 2
      forceArtifactAfterToolCalls: 10
      maxToolCalls: 20
      repeatedCommandLimit: 2
```

Additional `contract.completion` fields include `requireFilesChanged` and `requireValidationNotes` for handoff-style phases. `contract.policy` declares engine-level validation behavior that used to be tied to specific phase names: `requiresExplorerReport`, `explorerCircuitBreaker`, `developerCompletion`, `redPhaseCompletion`, `acceptanceCoverage`, `allowDeferredAcceptance`, `testEvidence`, `captureQaTarget`, `finalizeValidation`, `skipDeveloperRetryOnUnrelatedFinalizeFailure`, `structuredFailureChecklist`, and `terminalOnFailExhausted`. Dispatcher actions (`prepare-worktree`, `setup-workspace`, `write-task-context`) run before worker launch and may omit `prompt`, `bash`, `command`, and `builtin`. Workflow YAML resolves from an explicit YAML path, then project `.foreman/workflows/{name}.yaml|.yml`, then global `~/.foreman/workflows/{name}.yaml|.yml`, then bundled defaults; project-relative explicit paths must stay inside the project root, and project workflows also participate in `task_type` routing when a project path is available. Use `foreman workflows list|show|validate|install|create` to inspect, validate, install bundled YAML, or create workflow stubs for project/global override directories. Project actions can be overridden or added without rebuilding Foreman by adding `.foreman/actions/{action}.js` or `.foreman/actions/{action}.mjs`, or globally via `~/.foreman/actions/{action}.js|.mjs` (project actions win; TypeScript action files are not loaded directly yet). Modules export a default function/value or named `run` function/value (for example `export default async function run(ctx) {}`, `export default async (ctx) => {}`, `export async function run(ctx) {}`, `export const run = async (ctx) => {}`, or `export { run }`). A custom action phase may omit `prompt`, `bash`, `command`, and `builtin` when `action` names a project/global module; action names must use only letters, numbers, `.`, `_`, and `-`. Bundled editable stubs call `ctx.internal.runBuiltin()`, and `foreman doctor` / `foreman actions validate` validate safe action names, required exports, and workflow references to custom actions. Action `ctx` includes `actionType`, `phase`, `config`, `workflowConfig`, `log`, `mail`, and `internal.runBuiltin()`; worker-phase actions must return a phase result with `success`, `costUsd`, `turns`, `tokensIn`, and `tokensOut`, while workspace actions receive workspace fields such as `repoPath`, `worktreePath`, `branchName`, `seedInfo`, and setup/hook metadata and must return the updated workspace context object. `capabilities` is validated as non-empty strings and remains advisory metadata for reviewers/doctor output. Phase names must be unique, and `retryWith` / `mail.onFail` must target phases declared in the same workflow. Additional `overwatch` controls include `forceArtifactAfterToolCalls`, `maxToolCalls`, `repeatedCommandLimit`, and `blockedCommands` (regular-expression strings matched against normalized shell commands).

### Documentation Phase

Bundled workflows include a prompt-driven `documentation` phase after `finalize` and before PR creation. The shared prompt lives at `src/defaults/prompts/default/documentation.md` and is installed as `~/.foreman/prompts/default/documentation.md`. It requires agents to check whether the task changed behavior, commands, workflows, prompts, setup, troubleshooting, or operator expectations, then update the affected docs (`CLAUDE.md`, `AGENTS.md`, `README.md`, and `docs/cli-reference.md`) or write `{task.projectReportsDir}/DOCUMENTATION_REPORT.md` explaining why no doc change was needed.

```yaml
  - name: documentation
    prompt: documentation.md
    artifact: "{task.projectReportsDir}/DOCUMENTATION_REPORT.md"
    contract:
      requiredSections: [Verdict, Documentation Updated, Documentation Not Needed, Checks]
    overwatch:
      enabled: true
      mode: enforce
      continueIfArtifactValidOnBudgetStop: true
```

### Finalize Phase

Bundled workflows use a deterministic builtin `finalize` phase. It runs dependency install/typecheck, stages/restores workspace-safe files, commits, rebases when the target changed after QA, conditionally reruns tests, pushes `foreman/<task-id>`, and writes `FINALIZE_VALIDATION.md` plus `FINALIZE_REPORT.md`. Keep `artifact`, `verdict`, `retryWith`, and `retryOnFail` on the phase so validation failures still loop back through remediation.

```yaml
  - name: finalize
    builtin: true
    artifact: "{task.projectReportsDir}/FINALIZE_VALIDATION.md"
    maxTurns: 30
    verdict: true
    retryWith: developer
    retryOnFail: 6
```

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

Phases with `verdict: true` parse PASS/FAIL from their artifact. On FAIL, `retryWith` loops back to the named phase for another attempt.

```yaml
# QA fails → send feedback to developer → developer retries → QA retries
- name: qa
  verdict: true
  retryWith: developer           # Loop back to developer on FAIL
  retryOnFail: 3                 # Max 3 QA retries (4 QA attempts)
  mail:
    onFail: developer            # Send QA_REPORT.md to developer inbox

# Reviewer fails → same pattern, independent retry budget
- name: reviewer
  verdict: true
  retryWith: developer
  retryOnFail: 1                 # Max 1 reviewer retry (2 reviewer attempts)
  mail:
    onFail: developer

# Finalize failures use finalize's budget, even though they retry developer
- name: finalize
  verdict: true
  retryWith: developer
  retryOnFail: 6                 # Max 6 finalize retries
```

Retry budgets are **independent per failing/source phase**, not per retry target. QA, Reviewer, CLI review, PR review, and Finalize can all loop back to Developer without consuming a shared Developer retry budget. With QA at 3 and Finalize at 6, Developer can run once initially plus additional source-phase retries. If a verdict phase still reports FAIL after its own retry budget is exhausted, the pipeline stops instead of continuing to later phases with invalid evidence.

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
    maxTurns: 20
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
    retryOnFail: 3
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
    maxTurns: 20
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
    retryOnFail: 3
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
    retryOnFail: 3
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
    retryOnFail: 3
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

The prompt file (`~/.foreman/prompts/default/security-scan.md`) defines the agent's instructions, using `{{seedId}}`, `{{seedTitle}}`, `{{seedDescription}}`, and other template variables.

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

# Assign a bead to the custom workflow
br update <id> --set-labels "workflow:docs"
foreman run
```
