# Agent Mail-Driven Phase Transitions: Implementation Plan

> **Status:** Draft — awaiting approval
> **Date:** 2026-03-21
> **Scope:** (1) Make Agent Mail the primary transport for inter-phase report content in Foreman's pipeline, replacing disk-file reads with inbox reads (disk retained as fallback). (2) Externalize phase prompts to user-editable markdown files and pipeline configuration to JSON config files, enabling custom workflows per seed type (bug, feature, chore) without code changes.

---

## Context

Foreman's pipeline runs four sequential phases — Explorer → Developer ⇄ QA → Reviewer → Finalize — and each phase hands off context to the next via disk files (`EXPLORER_REPORT.md`, `QA_REPORT.md`, `REVIEW.md`). Agent Mail is already wired in: every phase *sends* its report as a message to the next phase's inbox. But the pipeline still *reads* from disk.

The goal is to flip that: messages become the primary transport, disk files become the fallback.

Additionally, when the Reviewer triggers a Developer retry, its findings are currently passed only through a local variable — never into the Developer's inbox. This closes that gap.

---

## What Already Works (No Changes Needed)

| Already Implemented | Subject | From → To |
|---|---|---|
| Explorer report send | `"Explorer Report"` | worker → `developer-{seedId}` |
| QA feedback send (on fail) | `"QA Feedback - Retry N"` | worker → `developer-{seedId}` |
| QA report send (on pass) | `"QA Report"` | worker → `reviewer-{seedId}` |
| Phase-complete events | `"phase-complete"` | worker → `foreman` |
| `developerPrompt(feedbackContext?)` | — | accepts any feedback text |
| `fetchInbox()` registry resolution | — | resolves logical role names |

---

## What's Missing

1. **QA feedback read path** — after `runPhase("qa")`, the code reads `QA_REPORT.md` from disk. Should read from the developer inbox first (the message is already there), fall back to disk.

2. **Reviewer→Developer inbox send** — when the Reviewer triggers a dev retry, its findings go nowhere except a local variable. Need to send them as `"Review Findings"` to `developer-{seedId}`.

3. **Reviewer findings read path** — same pattern as QA: read from inbox first, fall back to the local extracted variable.

4. **`acknowledgeMessage()` registry fix** — `fetchInbox()` already resolves logical role names through the internal `agentRegistry`; `acknowledgeMessage()` does not. One-line fix.

---

## Architecture Decision: Option A (Message-Triggered Sequential)

Four options were evaluated:

| | **Option A ✓** | Option B (Daemons) | Option C (Central SM) | Option D (Threads) |
|---|---|---|---|---|
| New code (lines) | ~60 | ~800+ | ~500+ | ~200+ |
| New processes | 0 | 4 daemons | 0 | 0 |
| Schema changes | none | `pipeline_state` | new table | none |
| Phase transition latency | 0 ms | 0 ms | up to 30 s/phase | 0 ms |
| Backward compat (no mail) | Full (disk fallback) | None | None | None |
| `foreman status` unchanged | Yes | Needs update | Needs update | Yes |
| Requires new Agent Mail API | No | No | No | Yes (`fetchThread`) |

**Why not Option D (threads)?**
Thread history retrieval (`fetchThread`) is not in the current `AgentMailClient` and not confirmed to exist on the Agent Mail server. Even if it did, the sequential TypeScript driver still needs to call `runPhase()` per phase — the thread doesn't drive transitions, the TypeScript loop does. Option A achieves the same message-body transport without any new API surface.

**Why Option A:**
Sequential `await`-chain stays unchanged. No new processes. No SQLite schema changes. Disk files remain as fallback. The entire change is ~60 lines of new code plus targeted modifications in `runPipeline()`.

---

## Message Flow (After Implementation)

```
Explorer ─── sdk.query() ───────────────────────────────────────────────────►
  └─► sendMailText → "developer-{seedId}"  "Explorer Report"        [already done]
  └─► writes EXPLORER_REPORT.md                                       [kept as fallback]

Developer ◄── feedbackContext from prior QA or Review message (or null on first run)
  └─► writes implementation files

QA ─── sdk.query() ─────────────────────────────────────────────────────────►
  [FAIL] └─► sendMailText → "developer-{seedId}"  "QA Feedback - Retry N"  [already done]
  [PASS] └─► sendMailText → "reviewer-{seedId}"   "QA Report"              [already done]

Developer (retry) ◄── fetchLatestPhaseMessage("developer-{seedId}", "QA Feedback")   [NEW read]
                  ◄── fallback: QA_REPORT.md on disk

Reviewer ─── sdk.query() ───────────────────────────────────────────────────►
  [issues] └─► sendMailText → "developer-{seedId}"  "Review Findings"      [NEW send]
  └─► sendMailText → "foreman"  "Review Complete"                           [already done]

Developer (retry) ◄── fetchLatestPhaseMessage("developer-{seedId}", "Review Findings") [NEW read]
                  ◄── fallback: local reviewFeedback variable

Finalize ─► sends "branch-ready" to refinery                               [already done]
```

---

## Implementation Steps

### Step 1 — Fix `acknowledgeMessage()` registry resolution

**File:** `src/orchestrator/agent-mail-client.ts`

`fetchInbox()` resolves logical role names (e.g. `"developer-bd-abc1"`) to their registered Agent Mail name via `this.agentRegistry`. `acknowledgeMessage()` does not. Without this fix, the helper added in Step 2 will read the message successfully but fail to acknowledge it.

```typescript
async acknowledgeMessage(agent: string, messageId: number): Promise<void> {
  const agentName = this.agentRegistry.get(agent) ?? agent;  // ADD THIS LINE
  // ... rest of existing implementation, replace `agent` with `agentName`
}
```

---

### Step 2 — Add `fetchLatestPhaseMessage()` helper

**File:** `src/orchestrator/agent-worker.ts` (module scope, alongside `sendMail`/`sendMailText`)

This function is the primary read path for all phase messages. It is intentionally non-throwing — any failure returns `null` and the caller falls back to disk.

```typescript
/**
 * Read the most recent unacknowledged message from an Agent Mail inbox
 * whose subject starts with the given prefix. Acknowledges before returning.
 *
 * Returns null when:
 *   - client is null (Agent Mail not configured)
 *   - no matching unacknowledged message exists
 *   - any network/API error occurs
 *
 * Callers should fall back to disk reads on null.
 */
async function fetchLatestPhaseMessage(
  client: AgentMailClient | null,
  inboxRole: string,
  subjectPrefix: string,
): Promise<string | null> {
  if (!client) return null;
  try {
    const messages = await client.fetchInbox(inboxRole, { limit: 20 });
    const match = messages
      .filter(m => !m.acknowledged && m.subject.startsWith(subjectPrefix))
      .sort((a, b) => b.receivedAt.localeCompare(a.receivedAt))[0];
    if (!match) return null;
    await client.acknowledgeMessage(inboxRole, parseInt(match.id, 10));
    log(`[agent-mail] Fetched "${match.subject}" from inbox "${inboxRole}" (id=${match.id})`);
    return match.body;
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    log(`[agent-mail] fetchLatestPhaseMessage failed (non-fatal): ${msg}`);
    return null;
  }
}
```

---

### Step 3 — Update QA verdict resolution (primary read from inbox)

**File:** `src/orchestrator/agent-worker.ts` — inside the Dev↔QA retry loop, after `runPhase("qa")` returns

**Before:**
```typescript
const qaReport = readReport(worktreePath, "QA_REPORT.md");
qaVerdict = qaReport ? parseVerdict(qaReport) : "unknown";
```

**After:**
```typescript
// PRIMARY: QA phase already sent this message to the developer inbox
const qaMailBody = await fetchLatestPhaseMessage(
  agentMailClient,
  `developer-${seedId}`,
  "QA Feedback",
);
// FALLBACK: disk file when Agent Mail is unavailable
const qaReport = qaMailBody ?? readReport(worktreePath, "QA_REPORT.md");
qaVerdict = qaReport ? parseVerdict(qaReport) : "unknown";
// feedbackContext assignment and rest of loop logic unchanged
```

---

### Step 4 — Send Reviewer findings to Developer inbox

**File:** `src/orchestrator/agent-worker.ts` — in the post-Reviewer dev-retry block

**Before:**
```typescript
if ((reviewVerdict === "fail" || (reviewVerdict === "pass" && hasIssues)) && devRetries < MAX_DEV_RETRIES) {
  const reviewFeedback = reviewReport ? extractIssues(reviewReport) : "(Review failed but no issues listed)";
  devRetries++;
  // ... runPhase("developer", developerPrompt(..., reviewFeedback, ...))
}
```

**After:**
```typescript
if ((reviewVerdict === "fail" || (reviewVerdict === "pass" && hasIssues)) && devRetries < MAX_DEV_RETRIES) {
  const reviewFeedback = reviewReport ? extractIssues(reviewReport) : "(Review failed but no issues listed)";

  // NEW: send reviewer findings to developer inbox so Developer can read them as a message
  if (reviewReport) {
    sendMailText(agentMailClient, `developer-${seedId}`, "Review Findings", reviewFeedback);
  }

  devRetries++;
  // ... rest unchanged
}
```

---

### Step 5 — Update Reviewer→Developer feedback read path

**File:** `src/orchestrator/agent-worker.ts` — before calling `developerPrompt()` in the review-feedback dev cycle

**After the send in Step 4:**
```typescript
// PRIMARY: read review findings from developer inbox (just sent above)
const reviewMailBody = await fetchLatestPhaseMessage(
  agentMailClient,
  `developer-${seedId}`,
  "Review Findings",
);
// FALLBACK: local variable extracted from disk earlier
const reviewFeedbackForDev = reviewMailBody ?? reviewFeedback;
// Pass reviewFeedbackForDev to developerPrompt() in the retry call
```

---

### Step 6 — Add unit tests

**File:** `src/orchestrator/__tests__/agent-worker-mail.test.ts` (new file)

Test cases for `fetchLatestPhaseMessage()`:

| Case | Setup | Expected |
|---|---|---|
| Message found | `fetchInbox` returns matching unacknowledged message | Returns `message.body`, calls `acknowledgeMessage` |
| No matching message | `fetchInbox` returns messages with wrong subjects | Returns `null` |
| All messages acknowledged | `fetchInbox` returns `acknowledged: true` messages | Returns `null` |
| Multiple matches | Two messages with same subject prefix | Returns the most recent (by `receivedAt`) |
| `client === null` | Called with `null` client | Returns `null` immediately, no calls |
| `fetchInbox` throws | API error | Returns `null` (non-fatal) |
| `acknowledgeMessage` throws | Acknowledge fails | Returns body anyway (non-fatal) |

---

## Files Changed

| File | Type | Change |
|---|---|---|
| `src/orchestrator/agent-mail-client.ts` | Modify | Fix `acknowledgeMessage()` to resolve logical role names (1 line) |
| `src/orchestrator/agent-worker.ts` | Modify | Add `fetchLatestPhaseMessage()`; update QA and Reviewer read paths; add Reviewer→Developer send |
| `src/orchestrator/__tests__/agent-worker-mail.test.ts` | Create | Unit tests for `fetchLatestPhaseMessage()` |

**Unchanged:**
- `src/orchestrator/roles.ts` — `developerPrompt(feedbackContext?)` signature untouched
- `src/orchestrator/dispatcher.ts` — spawn strategy untouched
- `src/lib/store.ts` — SQLite schema untouched
- `src/orchestrator/foreman-inbox-processor.ts` — untouched

---

---

## Part 2: Externalized Prompts and Workflow Config

### Goals

- Phase system prompts (currently TypeScript template literals in `roles.ts`) move to user-editable markdown files in `~/.foreman/prompts/`
- Phase mechanical config (model, budget, tools) moves to `~/.foreman/phases.json`
- Pipeline phase sequences move to `~/.foreman/workflows.json`, keyed by seed type
- `foreman init` seeds all three locations with defaults on first run
- Missing files fall back to built-in defaults — no breakage for existing installs

---

### File Layout

```
~/.foreman/
  prompts/
    explorer.md       ← system prompt for Explorer phase
    developer.md      ← system prompt for Developer phase (supports {{variables}})
    qa.md             ← system prompt for QA phase
    reviewer.md       ← system prompt for Reviewer phase
    reproducer.md     ← system prompt for Reproducer phase (bug workflow)
  phases.json         ← model, budget, tools per phase
  workflows.json      ← phase sequence per seed type
```

---

### Template Variable Syntax

Prompt markdown files use `{{variableName}}` placeholders. All variables are optional — missing variables render as empty string, not as a literal `{{...}}`.

| Variable | Available in phases | Description |
|---|---|---|
| `{{seedId}}` | all | Bead/seed ID (e.g. `bd-abc1`) |
| `{{seedTitle}}` | all | One-line title of the task |
| `{{seedDescription}}` | explorer, developer, reviewer | Full task description |
| `{{seedComments}}` | explorer, developer, reviewer | Comments from the bead |
| `{{feedbackContext}}` | developer | QA or Reviewer findings injected on retry |
| `{{hasExplorerReport}}` | developer | `"true"` or `"false"` |

Conditional blocks use `{{#if variable}}...{{/if}}` (simple truthy check, no nesting required):

```markdown
{{#if feedbackContext}}
## Prior Feedback

{{feedbackContext}}
{{/if}}
```

---

### `~/.foreman/phases.json`

Replaces the `buildRoleConfigs()` function in `roles.ts`. Environment variable overrides (`FOREMAN_EXPLORER_MODEL` etc.) still take precedence over this file.

```json
{
  "explorer": {
    "model": "claude-haiku-4-5-20251001",
    "maxBudgetUsd": 1.00,
    "allowedTools": ["Glob", "Grep", "Read", "Write"],
    "reportFile": "EXPLORER_REPORT.md",
    "promptFile": "explorer.md"
  },
  "developer": {
    "model": "claude-sonnet-4-6",
    "maxBudgetUsd": 5.00,
    "allowedTools": ["Agent", "Bash", "Edit", "Glob", "Grep", "Read", "TaskOutput", "TaskStop", "TodoWrite", "WebFetch", "WebSearch", "Write"],
    "reportFile": "DEVELOPER_REPORT.md",
    "promptFile": "developer.md"
  },
  "qa": {
    "model": "claude-sonnet-4-6",
    "maxBudgetUsd": 3.00,
    "allowedTools": ["Bash", "Edit", "Glob", "Grep", "Read", "TodoWrite", "Write"],
    "reportFile": "QA_REPORT.md",
    "promptFile": "qa.md"
  },
  "reviewer": {
    "model": "claude-sonnet-4-6",
    "maxBudgetUsd": 2.00,
    "allowedTools": ["Glob", "Grep", "Read", "Write"],
    "reportFile": "REVIEW.md",
    "promptFile": "reviewer.md"
  },
  "reproducer": {
    "model": "claude-sonnet-4-6",
    "maxBudgetUsd": 1.50,
    "allowedTools": ["Bash", "Glob", "Grep", "Read", "Write"],
    "reportFile": "REPRODUCER_REPORT.md",
    "promptFile": "reproducer.md"
  }
}
```

---

### `~/.foreman/workflows.json`

Defines which phases run for each seed type, in order. The seed type comes from the bead's `type` field (already stored in SQLite). Unknown types fall back to `"feature"`.

```json
{
  "feature": ["explorer", "developer", "qa", "reviewer", "finalize"],
  "bug":     ["reproducer", "developer", "qa", "finalize"],
  "chore":   ["developer", "finalize"],
  "docs":    ["developer", "finalize"]
}
```

---

### Implementation Steps (Part 2)

#### Step 7 — Prompt loader utility

**File:** `src/lib/prompt-loader.ts` (new)

```typescript
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const FOREMAN_DIR = join(homedir(), ".foreman");
const PROMPTS_DIR = join(FOREMAN_DIR, "prompts");

/**
 * Load a phase prompt from ~/.foreman/prompts/{phase}.md,
 * falling back to the built-in default from roles.ts if absent.
 *
 * Substitutes {{variable}} and {{#if var}}...{{/if}} blocks.
 */
export function loadPrompt(
  phase: string,
  variables: Record<string, string | undefined>,
  fallback: string,
): string {
  const promptPath = join(PROMPTS_DIR, `${phase}.md`);
  const template = existsSync(promptPath)
    ? readFileSync(promptPath, "utf8")
    : fallback;
  return renderTemplate(template, variables);
}

function renderTemplate(template: string, vars: Record<string, string | undefined>): string {
  // Handle {{#if var}}...{{/if}} blocks
  let result = template.replace(
    /\{\{#if (\w+)\}\}([\s\S]*?)\{\{\/if\}\}/g,
    (_, key, content) => (vars[key] ? content : ""),
  );
  // Substitute {{variable}} placeholders
  result = result.replace(/\{\{(\w+)\}\}/g, (_, key) => vars[key] ?? "");
  return result.trim();
}
```

#### Step 8 — Phase config loader

**File:** `src/lib/phase-config-loader.ts` (new)

Reads `~/.foreman/phases.json`, validates schema, falls back to `ROLE_CONFIGS` from `roles.ts` if absent or invalid.

```typescript
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { ROLE_CONFIGS } from "../orchestrator/roles.js";
import type { RoleConfig } from "../orchestrator/roles.js";

const PHASES_PATH = join(homedir(), ".foreman", "phases.json");

export function loadPhaseConfigs(): Record<string, RoleConfig> {
  if (!existsSync(PHASES_PATH)) return ROLE_CONFIGS as Record<string, RoleConfig>;
  try {
    const raw = JSON.parse(readFileSync(PHASES_PATH, "utf8"));
    // Validate required fields per phase entry; throw on schema error
    validatePhaseConfig(raw);
    return raw;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.warn(`[foreman] phases.json invalid (${msg}) — using built-in defaults`);
    return ROLE_CONFIGS as Record<string, RoleConfig>;
  }
}
```

#### Step 9 — Workflow config loader

**File:** `src/lib/workflow-config-loader.ts` (new)

```typescript
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const WORKFLOWS_PATH = join(homedir(), ".foreman", "workflows.json");

const DEFAULT_WORKFLOWS: Record<string, string[]> = {
  feature: ["explorer", "developer", "qa", "reviewer", "finalize"],
  bug:     ["reproducer", "developer", "qa", "finalize"],
  chore:   ["developer", "finalize"],
  docs:    ["developer", "finalize"],
};

export function loadWorkflows(): Record<string, string[]> {
  if (!existsSync(WORKFLOWS_PATH)) return DEFAULT_WORKFLOWS;
  try {
    return JSON.parse(readFileSync(WORKFLOWS_PATH, "utf8"));
  } catch {
    console.warn("[foreman] workflows.json invalid — using built-in defaults");
    return DEFAULT_WORKFLOWS;
  }
}

export function getWorkflow(seedType: string): string[] {
  const workflows = loadWorkflows();
  return workflows[seedType] ?? workflows["feature"] ?? DEFAULT_WORKFLOWS.feature;
}
```

#### Step 10 — Wire into `runPipeline()`

**File:** `src/orchestrator/agent-worker.ts`

Replace the hardcoded phase sequence and `ROLE_CONFIGS` reference with the loaded configs:

```typescript
import { loadPhaseConfigs } from "../lib/phase-config-loader.js";
import { getWorkflow } from "../lib/workflow-config-loader.js";
import { loadPrompt } from "../lib/prompt-loader.js";

// Inside runPipeline():
const phaseConfigs = loadPhaseConfigs();
const phases = getWorkflow(seed.type ?? "feature");   // ["explorer", "developer", ...]

// Replace buildRoleConfigs() / ROLE_CONFIGS lookups with phaseConfigs[phaseName]

// Replace explorerPrompt(...) calls with:
const explorerSystemPrompt = loadPrompt("explorer", { seedId, seedTitle, seedDescription, seedComments }, explorerPrompt(seedId, seedTitle, seedDescription, seedComments));

// Replace developerPrompt(...) calls with:
const developerSystemPrompt = loadPrompt("developer", { seedId, seedTitle, seedDescription, feedbackContext, hasExplorerReport: String(hasExplorerReport) }, developerPrompt(seedId, seedTitle, seedDescription, hasExplorerReport, feedbackContext, comments));
```

The existing prompt functions in `roles.ts` serve as the fallback — `loadPrompt()` passes them as the `fallback` argument. No changes to `roles.ts` required.

#### Step 11 — `foreman init` seeds config files

**File:** `src/cli/commands/init.ts`

On `foreman init`, copy default config files to `~/.foreman/` if they don't already exist:

- Copy bundled `defaults/phases.json` → `~/.foreman/phases.json`
- Copy bundled `defaults/workflows.json` → `~/.foreman/workflows.json`
- Copy bundled `defaults/prompts/*.md` → `~/.foreman/prompts/*.md`
- Print: `Wrote default phase config to ~/.foreman/phases.json — edit to customize`

**New directory:** `src/defaults/` — shipped with the package, contains the canonical default files.

#### Step 12 — Validation on startup

**File:** `src/lib/phase-config-loader.ts`

`validatePhaseConfig()` checks each phase entry has: `model` (string), `maxBudgetUsd` (number), `allowedTools` (string[]), `reportFile` (string), `promptFile` (string). Logs a warning per invalid field; falls back to built-in defaults for the whole file on any error.

#### Step 13 — Tests for loaders

**Files:**
- `src/lib/__tests__/prompt-loader.test.ts`
- `src/lib/__tests__/workflow-config-loader.test.ts`
- `src/lib/__tests__/phase-config-loader.test.ts`

Key test cases:

| Loader | Case | Expected |
|---|---|---|
| `loadPrompt` | File exists, all vars present | Returns rendered markdown |
| `loadPrompt` | File exists, `{{#if feedbackContext}}` block, var absent | Block omitted |
| `loadPrompt` | File absent | Returns rendered fallback string |
| `loadWorkflows` | File exists, valid JSON | Returns parsed map |
| `loadWorkflows` | File absent | Returns `DEFAULT_WORKFLOWS` |
| `loadWorkflows` | File invalid JSON | Warns + returns `DEFAULT_WORKFLOWS` |
| `getWorkflow` | `seedType = "bug"` | Returns `["reproducer", "developer", "qa", "finalize"]` |
| `getWorkflow` | `seedType = "unknown"` | Falls back to `"feature"` workflow |
| `loadPhaseConfigs` | File valid | Returns parsed phase map |
| `loadPhaseConfigs` | File missing required field | Warns + returns `ROLE_CONFIGS` |

---

### Updated Files Summary (Part 2)

| File | Type | Change |
|---|---|---|
| `src/lib/prompt-loader.ts` | Create | Template loader with `{{var}}` and `{{#if}}` support |
| `src/lib/phase-config-loader.ts` | Create | Reads `~/.foreman/phases.json`, falls back to `ROLE_CONFIGS` |
| `src/lib/workflow-config-loader.ts` | Create | Reads `~/.foreman/workflows.json`, `getWorkflow(seedType)` |
| `src/defaults/phases.json` | Create | Bundled default phase config |
| `src/defaults/workflows.json` | Create | Bundled default workflow sequences |
| `src/defaults/prompts/*.md` | Create | Bundled default prompt files (one per phase) |
| `src/orchestrator/agent-worker.ts` | Modify | Use `loadPhaseConfigs()`, `getWorkflow()`, `loadPrompt()` |
| `src/cli/commands/init.ts` | Modify | Copy defaults to `~/.foreman/` on init |
| `src/lib/__tests__/prompt-loader.test.ts` | Create | Unit tests |
| `src/lib/__tests__/workflow-config-loader.test.ts` | Create | Unit tests |
| `src/lib/__tests__/phase-config-loader.test.ts` | Create | Unit tests |

**Unchanged by Part 2:**
- `src/orchestrator/roles.ts` — prompt functions kept as fallbacks, `ROLE_CONFIGS` kept as fallback; no deletions

---

## Verification

```bash
# Build + type check
npm run build && npx tsc --noEmit

# Run Part 1 tests
npm test -- agent-worker-mail

# Run Part 2 tests
npm test -- prompt-loader workflow-config-loader phase-config-loader

# Run full test suite
npm test

# --- Part 1: Agent Mail transport ---

# Integration smoke test (requires running Agent Mail server)
foreman run --seed <seed-id>
# Watch logs for:
#   [agent-mail] Fetched "QA Feedback - Retry 1" from inbox "developer-{seedId}" (id=...)
#   [agent-mail] Fetched "Review Findings" from inbox "developer-{seedId}" (id=...)

# Backward compat test (stop Agent Mail server first)
foreman run --seed <seed-id>
# Should complete normally using disk fallback — no errors logged

# --- Part 2: External prompts and workflow config ---

# Seed defaults
foreman init
# Verify: ~/.foreman/phases.json, ~/.foreman/workflows.json, ~/.foreman/prompts/*.md created

# Custom prompt test: edit ~/.foreman/prompts/explorer.md, add a line
# Re-run a seed and verify the custom line appears in the agent session log

# Bug workflow test: create a seed with type=bug
foreman run --seed <bug-seed-id>
# Verify: logs show phases ["reproducer", "developer", "qa", "finalize"] — no Explorer, no Reviewer

# Custom workflow test: add "chore" workflow to ~/.foreman/workflows.json
# Create a seed with type=chore, verify only ["developer", "finalize"] runs

# Validation test: corrupt ~/.foreman/phases.json, run foreman
# Should warn and fall back to built-in defaults — no crash
```
