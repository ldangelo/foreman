# RCA: foreman-f134d Finalize Failure — scope_guard_failed

**Date**: 2026-07-16
**Task**: foreman-f134d — Fix log view: render run log output in structured readable format
**Run ID**: 1560f07e-b08d-1b4b-5a26-5390ede61f8d
**Failure Phase**: finalize
**Failure Message**: `scope_guard_failed: docs/cli-reference.md, src/cli/__tests__/inbox-tui-contracts.test.ts, src/cli/__tests__/inbox.test.ts, src/cli/commands/inbox.ts, src/cli/super-tui/panes/DetailPane.ts`

---

## Summary

The `finalize` phase of run `1560f07e` failed with `scope_guard_failed`. The Foreman workflow's scope guard blocks finalize when files are modified outside the Explorer's declared "Edit First" scope, unless the developer justifies them in a `## Scope Expansions` section of `DEVELOPER_REPORT.md`. The developer's worktree commits modified 5 files that were not covered by the Explorer's scope and were not justified.

---

## Root Cause

**Proximate cause**: `findFinalizeScopeViolations()` in `src/orchestrator/finalize-guards.ts` found that 5 changed files were not in the Explorer's `Edit First` scoped paths and had no `## Scope Expansions` justification in `DEVELOPER_REPORT.md`:

| File | Purpose | Justification needed? |
|------|---------|-----------------------|
| `src/cli/commands/inbox.ts` | Log section rendering with async `renderLogSection()` | YES — core deliverable |
| `src/cli/super-tui/panes/DetailPane.ts` | Handle `Promise<string>` output for async log rendering | YES — required by inbox.ts |
| `src/cli/__tests__/inbox.test.ts` | Test coverage for `renderLogSection` async behavior | YES — test coverage |
| `src/cli/__tests__/inbox-tui-contracts.test.ts` | TUI contract tests for DetailPane async output | YES — test coverage |
| `docs/cli-reference.md` | CLI docs for `--logs` flag behavior | YES — documentation |

**Underlying cause**: The developer's implementation of "Fix log view" structurally required `inbox.ts` to call the new structured log API and `DetailPane.ts` to handle async output. The task's scope (defined by the Explorer's `## Edit First` section) did not include these files. The developer's `DEVELOPER_REPORT.md` lacked a `## Scope Expansions` section to formally justify the out-of-scope changes.

**Note on `allowedPaths.size === 0`**: `findFinalizeScopeViolations` returns `[]` (no violations) when the explorer report has no `Edit First` section at all. The failure indicates the explorer report DID exist with scoped paths, but those paths did not cover the 5 modified files.

---

## Why No Scope Expansion Was Added

Reviewing the developer's run (54 + 16 + 67 turns across 3 developer-phase iterations), the agent was focused on implementation correctness and test coverage. The `## Scope Expansions` mechanism is documented in `src/defaults/prompts/default/developer.md`, but the developer did not add it to `DEVELOPER_REPORT.md`. This is a workflow gap: the developer did not recognize that the scope guard would require formal scope expansion justification.

---

## What the Fixes Actually Did

The 5 modified files represent a coherent, minimal set for the feature:

1. **`src/cli/commands/inbox.ts`**: Added `renderLogSection()` async call path using `ElixirServerClient.logs()`, with stream coloring (`[stdout]`, `[stderr]`, `[AssistantMessage]`), timestamp formatting, truncation to terminal width, and raw log file fallback.

2. **`src/cli/super-tui/panes/DetailPane.ts`**: Extended to handle `Promise<string>` `detailOutput` from the inbox TUI by adding `useEffect`/`useState` async unwrapping (mirroring the same pattern already used in the InboxDashboard for task details).

3. **`src/cli/__tests__/inbox.test.ts`**: Added async test for `renderLogSection`, updated existing tests to async, verified 151 tests pass.

4. **`src/cli/__tests__/inbox-tui-contracts.test.ts`**: Updated `DetailPane` contract tests for async `detailOutput` behavior.

5. **`docs/cli-reference.md`**: Documented the new `foreman inbox task <id> --logs` flag.

---

## Remediation

### Immediate Fix (1 step)

Add a `## Scope Expansions` section to `DEVELOPER_REPORT.md` in the worktree:

```markdown
## Scope Expansions

The following files were modified beyond the Explorer's Edit First scope out of necessity:

- **src/cli/commands/inbox.ts**: Core deliverable — renders structured log output for `foreman inbox task <id> --logs`. Requires calling the new async `renderLogSection()` which calls `ElixirServerClient.logs()`.
- **src/cli/super-tui/panes/DetailPane.ts**: Required by inbox.ts — the DetailPane in the SuperTUI inbox surface must handle `Promise<string>` detail output to display async log content alongside task summaries.
- **src/cli/__tests__/inbox.test.ts**: Test coverage for the new async `renderLogSection()` path.
- **src/cli/__tests__/inbox-tui-contracts.test.ts**: TUI contract tests for DetailPane async output unwrapping.
- **docs/cli-reference.md**: CLI documentation for the new `--logs` flag behavior.
```

Then re-run finalize: the scope guard will pass because `reportJustifiesOutOfScope()` returns `true` for files listed under `## Scope Expansions`.

### Systemic Fix (prevent recurrence)

**Option A — Expand the Explorer's scope template** (recommended): Update `src/defaults/prompts/default/explorer.md` to include common log-view implementation files (`inbox.ts`, `DetailPane.ts`, `*inbox*.test.ts`) in the default `## Edit First` section, since this is a known pattern for this type of task.

**Option B — Make the developer prompt mention scope expansion automatically**: When the developer's implementation requires a file not in the Explorer's scope, the developer phase prompt should explicitly ask for `## Scope Expansions` to be populated.

**Option C — Soft scope guard**: Change `scope_guard` from a hard block (FAIL) to a warning that allows finalize to proceed with a note, for cases where the developer has made reasonable out-of-scope changes.

---

## Files

- Failure log: `~/.foreman/logs/1560f07e-b08d-1b4b-5a26-5390ede61f8d.log`
- Worktree: `~/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-f134d/`
- Scope guard: `src/orchestrator/finalize-guards.ts`
- Agent worker: `src/orchestrator/agent-worker.ts:1979-1996`
