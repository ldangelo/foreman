# CodeRabbit review — `beads:foreman:foreman-p7asb`

Run: `run-094b44822fad0645a866d2f5a6cef3ec` · Workflow: `fix` · Phase: `coderabbit-review` (index 3)
Base branch: `main` (from `FOREMAN_BASE_BRANCH`)

## 1. Review engine

Command run (from the run worktree root), twice:

```
coderabbit review --agent --base main
```

`coderabbit` was on `PATH` (`/Users/ldangelo/.local/bin/coderabbit`), both invocations exited `0` with
`{"type":"complete","status":"review_completed","outcome":"completed"}`. The engine reviewed the same
tracked diff as the GitHub PR bot (`main...HEAD` plus the working tree):

```
docs/reports/foreman-beads:foreman:foreman-p7asb/FIX_REPORT.md
docs/reports/foreman-beads:foreman:foreman-p7asb/PLAN.md
ops/herdr-sidebar/keys.layout-foreman.json
ops/herdr-sidebar/mods/foreman-run/main.js
packages/foreman_server/lib/foreman_server/agents/operator_question_dispatcher.ex
packages/foreman_server/test/foreman_server/agents/operator_question_dispatcher_test.exs
```

## 2. Rounds

**Round 1** — 2 findings, both severity `major`, both in
`packages/foreman_server/test/foreman_server/agents/operator_question_dispatcher_test.exs`:

1. *Assert the event fields with a map pattern.* (line 393) — `assert atomized(data) =~ question_id`
   applies `=~` to a **map**; `Kernel.=~/2` has no clause for a map left-hand side, so the assertion
   raises `FunctionClauseError` instead of checking anything. Verified locally: `Kernel.=~(%{a: 1}, :a)`
   raises `FunctionClauseError`. **Fixed.**
2. *Move both tests inside the question-opening describe block.* (line 357) — the two tests added by
   the previous phase sat at module top level while binding `%{question_id: …, agent_id: …}` in their
   heads. Only the `describe "dispatch/1 opens the question (question.open)"` setup supplies those
   keys (the module-level setup returns `:ok`), so both tests failed with
   `** (FunctionClauseError) no function clause matching in …"test name"/1` before this review.
   **Fixed.**

**Round 2** — re-ran the same command after the fixes: `findings: 0`, `outcome: "completed"`, exit `0`.
No `Critical`/`Major` finding remained, so the loop stopped (2 of the 3 permitted rounds used).

## 3. Fixed

1. `packages/foreman_server/test/foreman_server/agents/operator_question_dispatcher_test.exs:393`
   — **Wrong:** `assert atomized(data) =~ question_id` asserted on a map with the `=~` operator, which
   raises `FunctionClauseError` for maps; the test could never assert anything.
   **Changed:** replaced with a precise map pattern matching the `QuestionOpened` event fields —
   `assert %{run_id: "global", question_id: ^question_id, agent_id: ^agent_id, timeout_ms: 300_000} = atomized(data)`
   — mirroring the sibling assertions already present in the same describe block (lines 204-207,
   228-233). `run_id: "global"` is the no-task fallback of the dispatcher payload; `timeout_ms:
   300_000` is the default operator timeout (`@operator_timeout_ms_default`).

2. `packages/foreman_server/test/foreman_server/agents/operator_question_dispatcher_test.exs:357`
   — **Wrong:** the two new tests ("a failed question.open is retried by the next delivery of the same
   signal" and "the operator timeout is armed once, by the ingest that started the item") were defined
   at module top level but bound `question_id`/`agent_id` from the context, which only the
   `describe "dispatch/1 opens the question (question.open)"` setup provides — both failed on the
   context match.
   **Changed:** moved both tests inside that describe block (their bodies are otherwise unchanged), so
   the scoped setup supplies `question_id`/`agent_id` and the `on_exit` that cancels the operator
   timeout timer.

No other file was modified by this phase.

## 4. Declined

None. Both CodeRabbit findings were real and were fixed; no finding was stale or out of scope.

## 5. Verification

| Command | Exit | Result |
| --- | --- | --- |
| `DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test test/foreman_server/agents/operator_question_dispatcher_test.exs --warnings-as-errors` (before the fixes) | 2 | 15/17 passed, 2 failed — both new tests failed on the context match (baseline captured) |
| `DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test test/foreman_server/agents/operator_question_dispatcher_test.exs --warnings-as-errors` (after the fixes) | 0 | `Result: 17 passed` |
| `MIX_ENV=test mix format test/foreman_server/agents/operator_question_dispatcher_test.exs` | 0 | file formatted (no diff left) |
| `coderabbit review --agent --base main` (round 2) | 0 | `findings: 0`, `outcome: "completed"` |

Fixes are left uncommitted for Foreman to commit.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/test/foreman_server/agents/operator_question_dispatcher_test.exs", "line": 393, "description": "The QuestionOpened assertion applied the =~ operator to a map, which raises FunctionClauseError, so it asserted nothing.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/test/foreman_server/agents/operator_question_dispatcher_test.exs", "line": 357, "description": "The two new dispatcher tests were defined at module top level while binding question_id and agent_id from a context only the question-opening describe supplies, so both failed on the context match.", "disposition": "fixed", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->
<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "The production change is a two-line behavioural fix in the question dispatcher (record the question on a deduped ingest, arm the operator timeout only on :started) and this phase only corrected two broken test assertions. The affected file's suite passes 17/17 and a second CodeRabbit pass found nothing; no public identifier, route, config key or event type changed."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
