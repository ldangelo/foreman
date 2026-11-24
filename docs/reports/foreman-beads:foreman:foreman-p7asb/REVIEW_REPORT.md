# Repo-rules review — beads:foreman:foreman-p7asb

## 1. Review engine

Reviewer: this phase (the repository-rules reviewer defined by
`packages/foreman_server/priv/defaults/workflows/prompts/review-repo-rules.md`), applying this repository's own
rules from `AGENTS.md` (Working Rules, Documentation Gate, §5 Typed Boundaries / Loud Failures, Invariants) plus
the bundled artifact contracts in `packages/foreman_server/priv/defaults/workflows/prompts/fix.md` and
`review-repo-rules.md`.

Diff range reviewed: `git diff main...HEAD` (`$FOREMAN_BASE_BRANCH` = `main`), i.e. merge-base
`db20c66a68146f172a3ef7feee295a96da8b73ec`...HEAD `9d022987`, which at review time was these three files only:

```
docs/reports/foreman-beads:foreman:foreman-p7asb/FIX_REPORT.md               |   1 +
docs/reports/foreman-beads:foreman:foreman-p7asb/PLAN.md                     | 245 +++++
docs/reports/foreman-beads:foreman:foreman-p7asb/REVIEW_CODERABBIT_REPORT.md |  26 +++
```

**The reviewed range did not contain the code the task asked for.** `PLAN.md` §1 states the range as
`main...HEAD` (2-dot) and records that the production change was already present at branch creation; the
`ingest/1` `[:started, :deduped]` change and its two tests are reachable only through that 2-dot range (they come
in through the base's own history: `26467648`, `e5f772a4`, `6f46d735`). The code was therefore reviewed against
`AGENTS.md` in the state the working tree holds it, and it is consistent with the task prompt and with `PLAN.md`
§4 Edits 1–4 verbatim. `.beads/issues.jsonl` and `docs/lessons/run-logs-known-issues.md` appear in the 2-dot
diff but were touched only by commits already on `main` (`0988b071`, `8a87a312`), not by this branch.

## 2. Findings

Received from the previous phase (`coderabbit`, both **major**, both disposition `fixed` — the code they name
already reflects them, verified at `packages/foreman_server/test/foreman_server/agents/operator_question_dispatcher_test.exs:356,403`):
1. `…/operator_question_dispatcher_test.exs:393` — the `QuestionOpened` assertion applied `=~` to a map, which raises `FunctionClauseError`, so it asserted nothing. **fixed** (prior phase).
2. `…/operator_question_dispatcher_test.exs:357` — the two new dispatcher tests were defined at module top level while binding `question_id`/`agent_id` from a context only the `describe "dispatch/1 opens the question (question.open)"` supplies, so both failed on the context match. **fixed** (prior phase; both now live inside that `describe`).

Found by this review (all fixed or declined below): 3 — `REVIEW_CODERABBIT_REPORT.md` lost both machine-read
blocks; `FIX_REPORT.md` is not the artifact its contract requires; the new `:deduped` behavior is undocumented in
`CLAUDE.md` and `docs/user-guide.md`. Two further observations declined as out of this run's scope (see §4).

## 3. Fixed

| file | what was wrong | what changed |
| --- | --- | --- |
| `docs/reports/foreman-beads:foreman:foreman-p7asb/REVIEW_CODERABBIT_REPORT.md` | The phase-3 commit step replaced the CodeRabbit report with 26 lines of prose, dropping the `foreman.review_findings/1` block (so `run_executor.record_review_findings/3` saw `:absent` and the two findings reached nobody) and overwriting the `foreman.risk_judgement/1` block with a second `review_findings/1` document. | Restored byte-identical from commit `5a187245` (`git checkout 5a187245 -- <path>`), which carries both blocks: findings at line 84, risk judgement at line 87. No prose was re-authored. |
| `docs/reports/foreman-beads:foreman:foreman-p7asb/FIX_REPORT.md` | Contained one stray narration line ("Now the tests. Let me read the end of the question.open describe.") instead of the six sections `priv/defaults/workflows/prompts/fix.md` requires. No earlier version exists in any ref (`git log --all --diff-filter=A -- '*foreman-p7asb*'` returns only the report-creation commit and the `9d022987` replacement). | Authored the six required sections (Root cause, Change, Deviations from the plan, Tests, Local verification, Follow-ups) from `PLAN.md` §2/§4/§5, the diff, and this phase's own test/format runs; §5 records the commands actually run with their exit codes, §6 records the residual gap rather than papering over it. |
| `CLAUDE.md:1164` (E8 approvals/questions bullet) | The bullet documents `question.open`, the 200-char `question_id` cap and the HTTP 422 path, but nothing stated that a deduped delivery now opens the question or that the fast-path timer is armed by one delivery only — `grep -n dedup CLAUDE.md` hit only the Notifier's `dedupe_window_ms`. | Added one clause: `SharedInbox.ingest/2` answers `:deduped`, the question is still opened (`question.open` idempotent, so a repeat retries a failed open), and `Agents.OperatorTimeout.schedule/3` is armed only by the `:started` delivery. |
| `docs/user-guide.md:3425` (Questions bullet) | Same gap on the operator-facing surface. | Added one sentence: posting the same question twice is safe — the repeat is deduped but still opens the question, and the expiry timer is armed once. |

Documentation-gate record: this diff adds, removes or renames **no** externally visible identifier (no command or
event type, MCP tool, HTTP route, CLI flag/verb, env var or config key), so no identifier needed a replacement
grep. Of the four gate files: `CLAUDE.md` **edited** (behavior of an existing documented endpoint changed),
`docs/user-guide.md` **edited** (same, operator-facing), `README.md` **not edited** (documents no question-ingest
dedupe semantics), `docs/cli-reference.md` **not edited** (no CLI verb or flag changed; `foreman questions answer`
behavior is unchanged). `AGENTS.md` **not edited** per its own rule that it is not a doc-update target; no
`docs/lessons/` file added (nothing in this run's diff is a reusable rule or post-mortem beyond what the run's own
artifacts now record).

## 4. Declined

| file | finding | reason |
| --- | --- | --- |
| `packages/foreman_server/lib/foreman_server/agents/operator_question_dispatcher.ex:61,63,65,75` | `Map.get(data, "question_id") \|\| Map.get(data, :question_id)` (and the same shape for `question`/`agent_id`/`task_id`) is the dual-key read `AGENTS.md` §5.4 forbids ("Never `Map.get(a, :k) \|\| Map.get(a, "k")`"). | Pre-existing on the base at every one of those lines — it is unchanged context in this run's diff, not work this run introduced, and `PLAN.md` §6 explicitly puts "the other key lookups in `dispatch/1`/`ingest/1`" out of scope. Changing a signal-parsing boundary the task never touched would be the bundled adjacent improvement the review contract forbids. Flagged here so it is visible, not silently ignored. |
| `packages/foreman_server/lib/foreman_server/agents/operator_question_dispatcher.ex:126-160` | `record_question/4` swallows a failed `question.open` behind `:ok` — `AGENTS.md` §5.2/§5.3 asks for a typed result rather than a generic success. | Exactly what `PLAN.md` §6 rules out ("do NOT make `record_question/4` raise, return a typed error, or change its return shape"). The task's remedy for the hidden failure is the `:deduped` retry this run added; the residual case (failure on the last delivery inside the dedupe window, with `Approvals.Sweeper` as the only backstop) is now recorded in `FIX_REPORT.md` §6 instead of being fixed under a plan that forbids it. |

## 5. Verification

| command | exit |
| --- | --- |
| `devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/agents/operator_question_dispatcher_test.exs test/foreman_server/agents/operator_question_flow_test.exs test/foreman_server_web/controllers/webhook_controller_test.exs test/foreman_server/mcp/tool_inventory_test.exs test/foreman_server/observability/docs_test.exs'` | 0 — 36 passed, 0 failed (`--warnings-as-errors` clean) |
| `devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'` | 0 |

The three files named by `PLAN.md` §5 are the narrowest affected set; `test/foreman_server/mcp/tool_inventory_test.exs`
and `test/foreman_server/observability/docs_test.exs` were added to that set because they are the two tests that
parse `CLAUDE.md` / `docs/user-guide.md`, which this phase edited. The full suite was not run, per the phase
contract. The final re-read of `git diff main` (working tree, to include these uncommitted fixes) found no new
violation: the only additions are the restored artifact (byte-identical to `5a187245`) and the two documentation
clauses. All fixes are left uncommitted for Foreman to commit.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/test/foreman_server/agents/operator_question_dispatcher_test.exs", "line": 393, "description": "The QuestionOpened assertion applied the =~ operator to a map, which raises FunctionClauseError, so it asserted nothing.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/test/foreman_server/agents/operator_question_dispatcher_test.exs", "line": 357, "description": "The two new dispatcher tests were defined at module top level while binding question_id and agent_id from a context only the question-opening describe supplies, so both failed on the context match.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "docs/reports/foreman-beads:foreman:foreman-p7asb/REVIEW_CODERABBIT_REPORT.md", "line": 1, "description": "The committed CodeRabbit report dropped its `foreman.review_findings/1` block and overwrote the risk-judgement block with a second findings document, so its two findings reached neither Foreman nor the operator.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "major", "path": "docs/reports/foreman-beads:foreman:foreman-p7asb/FIX_REPORT.md", "line": 1, "description": "The fix artifact was a single stray narration line instead of the six sections `priv/defaults/workflows/prompts/fix.md` requires, so the PR attached no root cause, change, test or verification record.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "CLAUDE.md", "line": 1164, "description": "The E8 bullet documents `question.open` and the ingest 422 path but never stated that a deduped delivery now opens the question or that the `OperatorTimeout` timer is armed by one delivery only.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/user-guide.md", "line": 3425, "description": "The operator-facing Questions bullet does not tell an operator that posting the same question twice is safe or that its expiry timer is armed once.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/agents/operator_question_dispatcher.ex", "line": 61, "description": "`Map.get(data, \"question_id\") || Map.get(data, :question_id)` is the dual-key read `AGENTS.md` §5.4 forbids, and the same shape recurs at lines 63, 65 and 75.", "disposition": "declined", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/agents/operator_question_dispatcher.ex", "line": 150, "description": "`record_question/4` reports only a log line for a failed `question.open` and returns `:ok`, so a failure on the last delivery inside the dedupe window is still invisible to the operator.", "disposition": "declined", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The behavioral change sits in the operator question-ingest path: deduped deliveries now emit a `question.open` command and the fast-path expiry timer is now armed only by the delivery that started the inbox item. It depends on `question.open` staying idempotent (deterministic command_id plus the aggregate's re-open guard), and a regression would surface as a missing or double-opened operator question. Scope is one function plus two tests, verified by the 36-test narrowed run with `--warnings-as-errors`; the rest of the diff is report artifacts and two documentation clauses."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
