# Foreman vs Sandcastle Gap Analysis

**Sandcastle Reference:** https://github.com/mattpocock/sandcastle
**Analysis Date:** 2026-06-02
**Sandcastle Version:** v0.x (npm: @ai-hero/sandcastle, 5,675 stars)
**Foreman Branch:** main

## Executive Summary

**Sandcastle** is a lightweight TypeScript library for orchestrating AI coding agents in isolated Docker/Podman/Vercel sandboxes. It focuses on:

- Running single or multiple agent sessions in containers
- Per-run worktree/branch management
- Structured output extraction
- Lifecycle hooks for setup/teardown

**Foreman** is a full-featured orchestrator for multi-agent VCS workflows with:

- Persistent daemon with polling
- Issue tracker integration (Jira, GitHub, Beads)
- Multi-phase agent pipelines
- Epic mode for grouped issues
- Retry logic and backoff

### Key Architectural Difference

| Aspect | Sandcastle | Foreman |
|--------|------------|---------|
| Scope | Single-run agent orchestration | Continuous daemon + multi-agent workflows |
| Isolation | Docker/Podman containers | Git worktrees (same host) |
| Issue tracking | GitHub Issues (template-driven) | Multi-tracker (Jira, GitHub, Beads) |
| Agent workflow | One prompt per run | Multi-phase pipelines |
| State | Ephemeral (per-run) | Persistent (PostgreSQL/SQLite) |
| Retry | Manual via `resumeSession` | Automatic exponential backoff |

---

## Detailed Gap Analysis

### 1. Sandbox / Isolation Model

#### Sandcastle Approach
- **Docker/Podman containers** as sandbox environments
- Bind mounts for host directory access
- Optional Vercel Firecracker microVMs
- `noSandbox()` for direct host execution

#### Foreman Approach
- **Git worktrees** as isolated workspaces
- Each issue gets its own worktree branch
- No container isolation by default

#### Gap Analysis
| Feature | Sandcastle | Foreman | Gap |
|---------|------------|---------|-----|
| Container isolation | ✅ Docker/Podman/Vercel | ❌ None | **Major** |
| Bind mounts | ✅ Full support | N/A | Different model |
| Resource limits | ✅ cpus, devices, network | ❌ None | **Major** |
| UID/GID alignment | ✅ Built-in | N/A | Different model |
| Rootless execution | ✅ Podman | N/A | Different model |

#### Assessment
This is an **intentional architectural difference**, not a gap. Foreman relies on Git worktrees rather than containers. However, adding container sandboxing as an optional provider would improve security for untrusted workflows.

---

### 2. Issue Tracking Integration

#### Sandcastle Approach
- Templates scaffold GitHub Issues integration
- Custom tracker via `custom` option
- Issue polling handled by user code in templates

#### Foreman Approach
- **Built-in polling** for Jira, GitHub Issues, Beads
- **Webhook support** for immediate notification
- **Debounce** to prevent duplicate dispatches
- **tRPC API** for programmatic access

#### Gap Analysis
| Feature | Sandcastle | Foreman | Gap |
|---------|------------|---------|-----|
| GitHub Issues polling | Template-dependent | ✅ Built-in | Foreman leads |
| Jira integration | ❌ None | ✅ Built-in | **Foreman-only** |
| Beads integration | ✅ Template option | ✅ Built-in | Parity |
| Webhook support | ❌ None | ✅ Built-in | **Foreman-only** |
| Debounce/throttling | ❌ None | ✅ Built-in | **Foreman-only** |
| Custom tracker | ✅ Via custom template | ❌ Limited | Sandcastle leads |

#### Assessment
Foreman has **superior built-in issue tracking**. Sandcastle requires manual implementation for non-GitHub trackers.

---

### 3. Agent Workflows

#### Sandcastle Approach
- Single prompt per `run()` call
- `maxIterations` for loop control
- `completionSignal` for early termination
- **Multi-run in same sandbox** via `sandbox.run()` chaining

#### Foreman Approach
- **Multi-phase pipelines** (plan → explore → implement → review → QA)
- **Role-based agents** with different capabilities
- **Epic mode** for grouped issues
- **Branch strategy** via VCS backend

#### Gap Analysis
| Feature | Sandcastle | Foreman | Gap |
|---------|------------|---------|-----|
| Single prompt run | ✅ Core model | ✅ Via single phase | Parity |
| Multi-phase pipelines | ❌ Manual chaining | ✅ Built-in | **Foreman-only** |
| Role-based agents | ❌ One agent type | ✅ Multiple roles | **Foreman-only** |
| Epic/multi-issue groups | ❌ Manual | ✅ Built-in | **Foreman-only** |
| Sequential review | Template | ✅ Built-in | Parity |
| Parallel execution | `createSandbox()` reuse | ✅ Dispatcher | Parity |

#### Assessment
Foreman has **significantly richer workflow support**. Sandcastle's model is intentionally simple — you chain `run()` calls for multi-step workflows.

---

### 4. Lifecycle Hooks

#### Sandcastle Approach

```typescript
hooks: {
  host: {
    onWorktreeReady: [{ command: "cp .env.example .env" }],
    onSandboxReady: [{ command: "echo setup done" }],
  },
  sandbox: {
    onSandboxReady: [{ command: "npm install" }],
  },
}
```

#### Foreman Approach
- ❌ **No hooks currently implemented**
- Workspace creation/deletion in `WorktreeManager`
- No lifecycle callbacks

#### Gap Analysis
| Hook | Sandcastle | Foreman | Gap |
|------|------------|---------|-----|
| after_create/onWorktreeReady | ✅ | ❌ | **Missing** |
| before_run/onSandboxReady | ✅ | ❌ | **Missing** |
| after_run | ✅ | ❌ | **Missing** |
| before_remove | ✅ | ❌ | **Missing** |
| Host vs sandbox separation | ✅ | N/A | Different model |
| Shell command execution | ✅ | ❌ | **Missing** |
| Timeout handling | ✅ `timeouts` | ❌ | **Missing** |

#### Assessment
**This is a significant gap.** Sandcastle's hook system is well-designed with host/sandbox separation and timeout control. Foreman should implement similar hooks.

---

### 5. Prompt System

#### Sandcastle Approach
- `promptFile` for file-based prompts
- `promptArgs` for `{{KEY}}` substitution
- `` !`command` `` for dynamic context (runs in sandbox)
- `{{SOURCE_BRANCH}}` / `{{TARGET_BRANCH}}` built-in args
- Inline prompts via `prompt` (no substitution)

#### Foreman Approach
- `{{key}}` substitution in templates
- 7-tier prompt resolution
- Phase-specific prompts (developer.md, reviewer.md, etc.)
- VCS context injection (`{{vcsPushCommand}}`, etc.)

#### Gap Analysis
| Feature | Sandcastle | Foreman | Gap |
|---------|------------|---------|-----|
| File-based prompts | ✅ `promptFile` | ✅ `prompt-loader.ts` | Parity |
| Variable substitution | ✅ `{{KEY}}` | ✅ `{{key}}` | Parity |
| Inline prompts | ✅ `prompt` | ⚠️ Limited | Foreman less flexible |
| Dynamic commands | ✅ `` !`cmd` `` | ❌ None | **Sandcastle leads** |
| Built-in variables | ✅ Branches | ✅ VCS context | Different focus |
| Strict variable checking | ✅ (error on missing) | ❌ Warning | **Sandcastle leads** |

#### Assessment
Sandcastle's **`` !`command` ``** dynamic context is powerful — it runs arbitrary shell commands in the sandbox and injects the output into the prompt. Foreman lacks this capability.

---

### 6. Structured Output

#### Sandcastle Approach
```typescript
output: Output.object({
  tag: "result",
  schema: z.object({ summary: z.string(), score: z.number() }),
})
```

#### Foreman Approach
- ❌ **No structured output extraction**
- Raw agent output handling in phases

#### Gap Analysis
| Feature | Sandcastle | Foreman | Gap |
|---------|------------|---------|-----|
| Schema validation | ✅ Zod/Valibot/Arktype | ❌ None | **Major** |
| Tag-based extraction | ✅ `<result>` tags | ❌ None | **Major** |
| Error recovery | ✅ `resumeSession` | ❌ None | **Sandcastle leads** |
| Session replay | ✅ `resumeSession` | ❌ None | **Sandcastle leads** |

#### Assessment
**Foreman needs structured output** for reliable downstream processing. Sandcastle's `<tag>` + schema validation is a proven pattern.

---

### 7. State & Persistence

#### Sandcastle Approach
- **Ephemeral by design** — each `run()` is independent
- `resumeSession` for replaying a specific session
- No persistent state between runs
- Log files under `.sandcastle/logs/`

#### Foreman Approach
- **Persistent daemon** with PostgreSQL/SQLite
- Track run history, retries, token usage
- Bead state machine (queued → running → done)
- Rate limit tracking

#### Gap Analysis
| Feature | Sandcastle | Foreman | Gap |
|---------|------------|---------|-----|
| Run history | ❌ Logs only | ✅ Database | **Foreman leads** |
| Retry tracking | ❌ Manual | ✅ Built-in | **Foreman leads** |
| Token accounting | ⚠️ Per-run only | ✅ Aggregate | **Foreman leads** |
| Rate limit tracking | ❌ None | ✅ Built-in | **Foreman leads** |
| Session persistence | ✅ `resumeSession` | ❌ None | **Sandcastle leads** |
| State machine | ❌ None | ✅ Bead lifecycle | **Foreman leads** |

#### Assessment
**Foreman has superior persistent state.** Sandcastle intentionally avoids state but has a clever `resumeSession` for session replay.

---

### 8. Concurrency & Scheduling

#### Sandcastle Approach
- Sequential by default (one `run()` at a time)
- Multi-run via `createSandbox()` — same container, different prompts
- No global concurrency control
- User handles parallelism via Promise.all()

#### Foreman Approach
- **Dispatcher** manages global concurrency (`maxAgents`)
- **Poller** triggers dispatches on cadence
- **Per-state limits** (via `foremanTag`)
- **Parallel dispatch** of multiple issues

#### Gap Analysis
| Feature | Sandcastle | Foreman | Gap |
|---------|------------|---------|-----|
| Global concurrency | ❌ None | ✅ `maxAgents` | **Foreman-only** |
| Per-state limits | ❌ None | ✅ Via config | **Foreman-only** |
| Background polling | ❌ None | ✅ `JiraIssuesPoller` | **Foreman-only** |
| Parallel runs | Manual Promise.all | ✅ Built-in | **Foreman-only** |
| Queue management | ❌ None | ✅ Bead queue | **Foreman-only** |

#### Assessment
**Foreman is designed for continuous operation.** Sandcastle is a library for running one-off agents.

---

### 9. Branch Strategy

#### Sandcastle Approach
- **Head** — write directly to host (no worktree)
- **Merge-to-head** — temp branch → merge back
- **Branch** — explicitly named branch in worktree

#### Foreman Approach
- Git worktrees with `foreman/<bead-id>` branches
- Git Jujutsu backend alternative
- Rebase/merge strategies configurable
- Stale worktree detection

#### Gap Analysis
| Feature | Sandcastle | Foreman | Gap |
|---------|------------|---------|-----|
| Worktree creation | ✅ Built-in | ✅ `WorktreeManager` | Parity |
| Branch naming | ✅ Explicit | `foreman/<id>` | Different style |
| Merge strategy | ✅ Merge-to-head | ✅ Configurable | Parity |
| Worktree reuse | ✅ ADR 0003 | ✅ | Parity |
| Rebase on rerun | ⚠️ Via merge-to-head | ✅ Built-in | Parity |
| Stale detection | ❌ None | ✅ `doctor.ts` | **Foreman leads** |

#### Assessment
**Parity** — both handle worktrees well, just different naming conventions.

---

### 10. Observability

#### Sandcastle Approach
- File-based logging: `.sandcastle/logs/<run>.log`
- `onAgentStreamEvent` callback for custom forwarding
- stdout logging option
- Per-run log file path in result

#### Foreman Approach
- Structured logging via harness
- `doctor.ts` health checks
- tRPC status endpoints
- Token/cost tracking

#### Gap Analysis
| Feature | Sandcastle | Foreman | Gap |
|---------|------------|---------|-----|
| Run logs | ✅ File + callback | ⚠️ Basic | Parity |
| Stream forwarding | ✅ `onAgentStreamEvent` | ❌ None | **Sandcastle leads** |
| Health checks | ❌ None | ✅ `doctor.ts` | **Foreman leads** |
| Status API | ❌ None | ✅ tRPC | **Foreman leads** |
| Token tracking | ⚠️ Per-run | ✅ Aggregate | **Foreman leads** |
| Cost tracking | ❌ None | ✅ Built-in | **Foreman leads** |

#### Assessment
**Different strengths.** Sandcastle has better real-time streaming observability. Foreman has better aggregate metrics and health checks.

---

### 11. Templates & Scaffolding

#### Sandcastle Approach
- `sandcastle init` wizard
- Template selection: blank, simple-loop, sequential-reviewer, parallel-planner
- Auto-detects package manager
- Image building

#### Foreman Approach
- Manual project setup
- Workflow YAML configuration
- Phase template files

#### Gap Analysis
| Feature | Sandcastle | Foreman | Gap |
|---------|------------|---------|-----|
| Init wizard | ✅ `sandcastle init` | ❌ Manual | **Sandcastle leads** |
| Template selection | ✅ 5 options | ⚠️ Manual | **Sandcastle leads** |
| Auto package manager | ✅ Detected | ❌ Manual | **Sandcastle leads** |
| Container build | ✅ `build-image` | ❌ N/A | Different model |

#### Assessment
**Sandcastle has a better developer experience** for getting started. Foreman could learn from `sandcastle init`.

---

## Summary Matrix

| Category | Winner | Key Difference |
|----------|--------|----------------|
| Isolation | Sandcastle | Docker/Podman containers vs git worktrees |
| Issue Tracking | Foreman | Built-in polling vs manual templates |
| Workflows | Foreman | Multi-phase pipelines vs single prompt |
| Lifecycle Hooks | Sandcastle | Full hook system vs none |
| Prompt System | Sandcastle | `` !`cmd` `` dynamic context |
| Structured Output | Sandcastle | Schema validation vs none |
| Persistence | Foreman | Database vs ephemeral |
| Concurrency | Foreman | Daemon + dispatcher vs manual |
| Branch Strategy | Tie | Both use worktrees well |
| Observability | Tie | Different strengths |
| Developer Experience | Sandcastle | Init wizard vs manual |

---

## Recommendations for Foreman

### High Priority

#### 1. Lifecycle Hooks
**Reference:** Sandcastle's `hooks` system
```typescript
// Implement in WorktreeManager
interface WorkspaceHooks {
  host?: {
    onWorktreeReady?: string[];
    onSandboxReady?: string[];
  };
  sandbox?: {
    onSandboxReady?: string[];  // npm install, etc.
  };
}
```

#### 2. Structured Output Extraction
**Reference:** Sandcastle's `Output.object()`
- Add `<result>` tag parsing
- Schema validation with Zod
- Session replay on parse failure

#### 3. Dynamic Command Expansion in Prompts
**Reference:** Sandcastle's `` !`command` ``
```markdown
# In prompt template
!`gh issue view {{ISSUE_NUMBER}} --json body`
```
Runs in sandbox, injects output into prompt.

#### 4. Init Wizard
**Reference:** `sandcastle init`
- Interactive setup for project config
- Template selection for common workflows
- Auto-detect VCS backend

---

### Medium Priority

#### 5. Container Sandboxing (Optional)
**Reference:** Sandcastle's Docker/Podman providers
- Optional container mode for untrusted workflows
- Could use Sandcastle as a provider

#### 6. Stream Event Callbacks
**Reference:** Sandcastle's `onAgentStreamEvent`
- Real-time event forwarding
- Custom observability integrations

---

### Not Applicable

- **Session resume** — different model (Foreman uses persistent state)
- **Merge-to-head** — Foreman already has rebase strategies
- **Completion signal** — Foreman uses phase completion instead

---

## Conclusion

**Foreman and Sandcastle solve different problems.**

- **Sandcastle** is a **library** for running agents in containers with excellent DX
- **Foreman** is a **platform** for continuous multi-agent orchestration

**Foreman should adopt from Sandcastle:**
1. Lifecycle hooks (high value, medium effort)
2. Structured output extraction (high value, medium effort)
3. `` !`command` `` prompt expansion (medium value, medium effort)
4. Init wizard (low value, low effort)

**Foreman's unique strengths to preserve:**
- Persistent state and retry logic
- Multi-phase pipelines
- Built-in issue tracker polling
- Daemon mode with background scheduling