# Repository-rules review — beads:foreman:foreman-i3qol

## Review engine

- Reviewer: the `repo-rules` review phase agent of the `foreman` orchestrator
  (repository-rules reviewer for this run; no external review CLI is available
  in this phase).
- Diff range reviewed: `git diff "$FOREMAN_BASE_BRANCH"...HEAD` with
  `FOREMAN_BASE_BRANCH=main` (the branch the run was cut from;
  `git merge-base --is-ancestor main HEAD` is true), i.e. `main...HEAD`
  (commits `a09b884e` → `fdb0f9ca`), **plus** the uncommitted working-tree
  changes (`git diff HEAD`), because the previous phase left most of its
  implementation uncommitted in the run worktree: the producers
  (`workflow/run_executor.ex`, `workflow/repo_attach.ex`), the projection
  (`projection_store.ex`), the two extended test files and the documentation
  edits. Every changed line therefore traces to this run.
- Rules applied: the repository's own `AGENTS.md` (working rules, documentation
  gate, §5 typed boundaries — 5.1 typed returns, 5.3 absent ≠ malformed,
  5.4 one key convention per boundary, 5.4b whitelist-normalize map params)
  together with the conventions already established in the files this run
  touches.
- Previous phase's report: `docs/reports/foreman-beads:foreman:foreman-i3qol/REVIEW_CODERABBIT_REPORT.md`
  exists but holds only two blank lines (2 bytes) — it has **no readable
  findings block**, so there is nothing to carry forward. No prior judgement
  block was copied.
- Operator progress updates: `foreman_inbox_send` and
  `foreman_task_add_comment` are not exposed in this phase, so no progress
  notes were sent; this report is the phase's operator-visible record.

## Findings

1. **critical** — `packages/foreman_server/lib/foreman_server/aggregates/run.ex`
   (committed apply arm, `main...HEAD` line 434): the committed
   `RunBaseBranchRecorded` apply path called `base_sha_payload_value(payload)`,
   a function that exists nowhere in the repository, so the branch did not
   compile at all. → **fixed**
2. **major** — `packages/foreman_server/lib/foreman_server/aggregates/run.ex`
   (committed accessor, `main...HEAD` line 113): the new `base_sha/1` accessor
   documented itself as "Read by `AutoPR.resolve_base_ref/1`" — no such
   function exists in the tree and nothing read the aggregate's SHA. → **fixed**
3. **minor** — `packages/foreman_server/lib/foreman_server/aggregates/run.ex`
   (line 73 in the committed file): the `State` struct declared a `:base_sha`
   field that, once the apply arm stopped folding a SHA into it, no code wrote
   and no code read — a declared value nothing consumes. → **fixed**
4. **major** — `packages/foreman_server/lib/foreman_server/events/run_base_branch_recorded.ex`
   (committed moduledoc): the event's documentation claimed
   "`RunExecutor.foreman_env/3` exports it as `FOREMAN_BASE_SHA`". No
   `FOREMAN_BASE_SHA` exists anywhere in `packages/`, `docs/`, `CLAUDE.md` or
   `README.md`, and `foreman_env/3` does not export it — documentation that
   describes behaviour the code does not have. → **fixed**
5. **major** — `packages/foreman_server/lib/foreman_server/aggregates/run.ex`
   (line 809): the command forwarded the caller's whole payload into the
   event, so any key the event does not declare made
   `ForemanServer.EventCodec.decode!/2` raise on replay — an untyped,
   unvalidated pass-through at the command boundary (AGENTS.md §5.4b). →
   **fixed**
6. **minor** — `packages/foreman_server/lib/foreman_server/aggregates/run.ex`
   (line 799): the new `base_sha` value was accepted unvalidated, so a
   non-binary value reached the stream and only broke at replay, instead of
   being reported as a malformed input where it entered. → **fixed**
7. **minor** — `packages/foreman_server/lib/foreman_server/aggregates/run.ex`
   (line 800): with the payload whitelisted, a malformed `repo_id` would be
   dropped, and a secondary repository's branch would be recorded as the run
   primary's — a wrong success value instead of a loud failure. → **fixed**
8. **minor** — `.dev/b3.txt` (line 1): the branch committed 669 lines of the
   fix phase's own captured agent session transcript (its prompt, verbatim)
   into the repository root — machine-local scratch, never review material. →
   **fixed**
9. **minor** — `docs/reports/foreman-beads:foreman:foreman-i3qol/FIX_REPORT.md`
   (line 1): the run's own fix report was a truncated agent utterance
   ("Now the edits. Starting with edit 1 (event module):") and described none
   of the change it was supposed to report. → **fixed**
10. **nitpick** — `packages/foreman_server/lib/foreman_server/events/run_base_branch_recorded.ex`
    (line 34): the event declares a `sequence` field that this run's producers
    never set, so `Run.State.last_sequence` does not advance on this event.
    Pre-existing vocabulary (the field and the aggregate's `last_sequence`
    tracking predate this run); the diff adds `base_sha`, not `sequence`. →
    **declined** (out of this run's scope)

## Fixed

- **`packages/foreman_server/lib/foreman_server/aggregates/run.ex`**
  (apply arm, line 416) — *what was wrong:* the committed apply path called
  the non-existent `base_sha_payload_value(payload)`, so the branch did not
  compile. *What changed:* the call was dropped; the SHA is no longer folded
  into aggregate state, and the arm now says so in a comment ("`base_sha` is
  deliberately not folded into the aggregate: it is a read-model fact the
  projection surfaces on the run view, and the aggregate keeps no field for
  it"). `base_branch` continues to be folded as before.
- **`packages/foreman_server/lib/foreman_server/aggregates/run.ex`**
  (`base_sha/1`, committed line 113) — *what was wrong:* an accessor nothing
  read, whose doc pointed at a function that does not exist. *What changed:*
  the accessor was removed together with the struct field it exposed.
- **`packages/foreman_server/lib/foreman_server/aggregates/run.ex`**
  (line 73) — *what was wrong:* the `State` struct still declared
  `:base_sha` (and `initial_state/0` still set it) although no code wrote
  or read it. *What changed:* the field, its comment and the `initial_state`
  entry were removed; `grep -rn base_sha` over the aggregate now shows only
  comments, the two validation guards and the payload whitelist.
- **`packages/foreman_server/lib/foreman_server/events/run_base_branch_recorded.ex`**
  (moduledoc, line 15) — *what was wrong:* the documentation asserted an
  export (`FOREMAN_BASE_SHA`) and an inheritance ("inherited from
  `RunStarted`") that do not exist. *What changed:* the moduledoc now names
  the real producers (`RunExecutor` for the primary and for a secondary
  repository, `Workflow.RepoAttach` for a secondary repository) and the real
  reader (`ProjectionStore`, which surfaces the SHA on the run view), and
  states the absent-not-`nil` rule. The `base_sha` and `repo_id` fields were
  added to the struct, the `@type t` and `@enforce_keys`
  (`[:run_id, :base_branch]` — `base_sha` stays optional).
- **`packages/foreman_server/lib/foreman_server/aggregates/run.ex`**
  (line 809) — *what was wrong:* the whole caller payload went into the
  event, so an undeclared key made `EventCodec.decode!/2` raise on replay.
  *What changed:* the event payload is now whitelisted by
  `base_branch_payload/3` (line 1595) and `put_optional_binary/3` (line 1603)
  to the declared fields only (`run_id`, `base_branch`, `base_sha`, `repo_id`),
  with atom keys and no `nil` inserted for an absent key (AGENTS.md §5.4b).
- **`packages/foreman_server/lib/foreman_server/aggregates/run.ex`**
  (lines 799-800) — *what was wrong:* `base_sha` and `repo_id` were accepted
  unvalidated; a wrong value surfaced later as a broken replay or as a
  silently mis-attributed branch. *What changed:* both are validated with the
  existing `require_optional_binary/2` helper (line 1580) and refused with
  `{:error, {:missing_or_invalid, key, value}}` at the boundary where they
  enter; an absent value stays absent (AGENTS.md §5.3).
- **`.dev/b3.txt`** — *what was wrong:* 669 lines of the fix phase's own
  captured agent session transcript were committed to the branch.
  *What changed:* the file was removed from the branch (staged deletion) and
  deleted from the worktree; `/.dev/` was added to the root `.gitignore` with
  a comment saying why.
- **`docs/reports/foreman-beads:foreman:foreman-i3qol/FIX_REPORT.md`** —
  *what was wrong:* the report was a truncated agent utterance that described
  none of the change. *What changed:* it now records what was implemented
  (event, aggregate, producers, projection, documentation), the
  documentation-gate statement and the verification commands.

## Declined

- **`packages/foreman_server/lib/foreman_server/events/run_base_branch_recorded.ex`**
  (line 34) — *finding:* the event declares a `sequence` field that this
  run's producers never set, so `Run.State.last_sequence` does not advance on
  this event. *Reason:* pre-existing event vocabulary that predates this run
  (the diff adds `base_sha` and `repo_id`, not `sequence`); changing how the
  aggregate counts sequences would be a separate change to the run's scope.

## Verification

- `git diff "$FOREMAN_BASE_BRANCH"...HEAD` (base `main`) and `git diff HEAD`
  — both ranges read in full, twice: once to triage, once after the fixes to
  confirm the fixes introduce no new violation. No new violation found in the
  second pass.
- `MIX_ENV=test mix compile --warnings-as-errors` (in
  `packages/foreman_server`) → exit 0 (`Compiling 13 files (.ex)`).
- `mix format --check-formatted` on the eight touched Elixir files
  (`aggregates/run.ex`, `events/run_base_branch_recorded.ex`,
  `projection_store.ex`, `workflow/repo_attach.ex`, `workflow/run_executor.ex`,
  `test/foreman_server/aggregates/run_base_branch_test.exs`,
  `test/foreman_server/projection_store_run_repositories_test.exs`,
  `test/foreman_server/workflow/run_executor_pr_base_branch_test.exs`) →
  exit 0.
- `DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test_i3qol
  TEST_DB_POOL_SIZE=5 MIX_ENV=test mix test
  test/foreman_server/aggregates/run_base_branch_test.exs
  test/foreman_server/projection_store_run_repositories_test.exs
  test/foreman_server/workflow/run_executor_pr_base_branch_test.exs` → exit 0,
  `Result: 21 passed`, `ProjectionLeakGuard: judged 2 of 2 modules, no run
  left behind`.
- `DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test_i3qol
  TEST_DB_POOL_SIZE=5 MIX_ENV=test mix test --warnings-as-errors` (full suite,
  the repository's own command from `AGENTS.md`) → exit 0, `Result: 9261
  passed (8 properties, 9253 tests), 11 excluded`, `ProjectionLeakGuard:
  judged 461 of 559 modules, no run left behind`; no warning lines and no
  failure blocks in the log.
- Documentation gate: `grep` over `CLAUDE.md`, `README.md`,
  `docs/user-guide.md` and `docs/cli-reference.md` for `base_branch`,
  `base_sha` and `FOREMAN_BASE_SHA` — `docs/user-guide.md:1362-1367` (the
  `GET /api/runs/{id}` response now documents `base_branch` and, when
  resolved, `base_sha`) and `docs/lessons/architecture-and-events.md:222` (the
  event row) needed edits and got them; `README.md`, `docs/cli-reference.md`
  and `CLAUDE.md` needed none — no route, CLI verb, env var, config key or
  MCP tool was added, removed or renamed, and the `RepoPr.finalize` context
  still reads only `base_branch`, so `CLAUDE.md`'s list of context fields is
  still accurate.
- All fixes are left uncommitted for Foreman to commit.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "critical", "path": "packages/foreman_server/lib/foreman_server/aggregates/run.ex", "line": 416, "description": "The committed RunBaseBranchRecorded apply arm called base_sha_payload_value(payload), a function that exists nowhere in the repository, so the branch did not compile.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/aggregates/run.ex", "line": 416, "description": "The new base_sha/1 accessor documented itself as read by AutoPR.resolve_base_ref/1, a function that does not exist and whose value nothing read.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/aggregates/run.ex", "line": 73, "description": "The Run State struct declared a base_sha field that no code wrote and no code read once the apply path stopped folding a SHA into it.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/events/run_base_branch_recorded.ex", "line": 15, "description": "The event moduledoc claimed RunExecutor.foreman_env/3 exports the SHA as FOREMAN_BASE_SHA, an identifier that exists nowhere in the repository.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/aggregates/run.ex", "line": 809, "description": "The command forwarded the caller's whole payload into the event, so any undeclared key made EventCodec.decode!/2 raise on replay.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/aggregates/run.ex", "line": 799, "description": "The new base_sha value was accepted unvalidated, so a non-binary value reached the stream and only broke at replay.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "packages/foreman_server/lib/foreman_server/aggregates/run.ex", "line": 800, "description": "A malformed repo_id would have been dropped by the payload whitelist, recording a secondary repository's branch as the run primary's.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": ".dev/b3.txt", "line": 1, "description": "The branch committed 669 lines of the fix phase's own captured agent session transcript into the repository root.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "minor", "path": "docs/reports/foreman-beads:foreman:foreman-i3qol/FIX_REPORT.md", "line": 1, "description": "The run's fix report was a truncated agent utterance and described none of the change it was meant to report.", "disposition": "fixed", "source": "repo-rules"}, {"severity": "nitpick", "path": "packages/foreman_server/lib/foreman_server/events/run_base_branch_recorded.ex", "line": 34, "description": "The event declares a sequence field that this run's producers never set, so the aggregate's last_sequence does not advance on this event.", "disposition": "declined", "source": "repo-rules"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->
<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "The change adds an optional base_sha to one event, validates and whitelists the command payload, and surfaces the SHA in the run projection and view; the aggregate keeps no new state, no route or CLI verb changes, and the full suite is green (9261 passed)."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
