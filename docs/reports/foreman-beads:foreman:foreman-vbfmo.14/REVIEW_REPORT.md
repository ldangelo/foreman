# Review Report — repo-rules review (phase 7)

## Review engine

Reviewer: this phase, against this repository's own rules (`AGENTS.md`, the
`docs/lessons/*` it points at, `.coderabbit.yaml` `path_instructions` as the repo's
written review criteria, and the documentation gate). No external CLI.

Diff range reviewed: `git diff main...HEAD` with `FOREMAN_BASE_BRANCH=main`
(base `4ee1b417`, HEAD `5c3c3293` = phase 6 commit). It contained **one** file:
`docs/reports/foreman-beads:foreman:foreman-vbfmo.14/REVIEW_CODERABBIT_REPORT.md`
(+15 lines, prose status summary). No PRD, no TRD, no code — phases 1–5 were
blocked/noop (phases 2/4/5 PR records: `status: noop`, `reason: no_commits_ahead`).

Second read after fixes: `git diff main...HEAD` plus the uncommitted working-tree
change (`docs/PRD/PRD-2026-f7a50d75-workspace-nav-run-provenance-links.md`,
+13 lines) — no new violation of the rules above.

## Findings

**No findings block was received from the previous phase.** The carry-forward
source `docs/reports/foreman-beads:foreman:foreman-vbfmo.14/REVIEW_CODERABBIT_REPORT.md`
**is present** (15 lines) but carries **neither marker at all**, so
`ForemanServer.Workflow.ReviewFindings.extract/1` returns `:none` for it — verified
by running the real function on the file, and reproduced below. There was therefore
no bullet to copy verbatim. Its prose does name one unresolved issue (its line 11:
the run's task subject does not match the delivered `FOREMAN_SOURCE_PRD_PATH`); I
carry that issue forward as Major finding 1, sourced from the prose rather than a
findings block.

Contract verification, run against this phase's own artifact and the sibling
(`MIX_ENV=test mix run`, exit 0):

    REVIEW_CODERABBIT_REPORT.md -> :none
    REVIEW_REPORT.md            -> {:ok, "- `docs/reports/...` Major - ...\n"
                                       <> "- `packages/foreman_server/mix.exs:203` Major - ..."}

The extracted block is 1492 bytes, inside `@max_bytes 4000`
(`packages/foreman_server/lib/foreman_server/workflow/review_findings.ex:32`), so no
bullet gets truncated in the PR body. The block this phase must hand the PR builder
is present and parseable; the one it was supposed to inherit is not.

Findings raised by my own rules pass, all triaged:

- **R1** — the delivered PRD carries no record of this run's mismatched subject,
  which `.coderabbit.yaml` says is fixed "with a forward-pointing note". **Fixed**.
- **R2** — `ReviewFindings.extract/1` cannot tell "no markers" from "markers, empty
  block", so a review phase that forgets its block drops findings silently (§5.3
  "absent ≠ malformed"). **Declined** as out of scope; see ## Declined.
- **R3** — earlier daily-log note claims phase 6's report was left untracked for
  Foreman to commit; `git status` was clean at phase start, so it was committed.
  **Declined** (stale note, no code impact).
- **R4** — documentation gate: this diff adds/removes/renames no command type, MCP
  tool, route, CLI verb, env var or config key. **Declined** (no doc edits needed;
  stated per gate rule 4).

## Fixed

- `docs/PRD/PRD-2026-f7a50d75-workspace-nav-run-provenance-links.md:21-26` (R1) — the
  file is a point-in-time spec, so per `.coderabbit.yaml` (`docs/PRD/**`: "do not
  report them as stale… a forward-pointing note is the only correct fix") and the
  AGENTS.md documentation gate, the only correct repo change for R1 is a note.
  Added a 6-line blockquote directly under the `# PRD: Workspace nav …` title
  recording that run-c5530c375ee791d5dd62d0817eb65f12 delivered this PRD as
  `FOREMAN_SOURCE_PRD_PATH` for an unrelated task subject, that that run's
  PRD/TRD/implement phases blocked and landed nothing, and that the mismatch is in
  the *task's* pointer rather than in this spec.
- Same file, `:608-612` — one `### 2026-11-06 — note added (no requirement change)`
  changelog entry, matching the file's existing changelog style. `Version: 1.0.0`,
  `Status: Draft`, requirement counts and readiness score untouched; no requirement,
  AC or score changed.

## Declined

- **R2** — `packages/foreman_server/lib/foreman_server/workflow/review_findings.ex:39-46`
  (`extract/1`, `@spec` at `:38` = `{:ok, String.t()} | :none | {:error, :unterminated_block}`;
  readers `workflow/phase_pr.ex:353` and `workflow/auto_pr.ex:378`) —
  §5.3 asks that "no markers" be distinguishable from "markers with an empty block".
  Declined for this phase: the current three outcomes are deliberate, documented and
  tested (moduledoc lines 13-20; `:32-36` states outright that a missing/unreadable file
  is "not surfaced as a distinct error here"; `test/foreman_server/workflow/review_findings_test.exs`
  pins the sibling cases), both callers already emit a visible empty
  `## Unresolved review findings` section when a report is present, and phase 6's own
  prompt never requires emitting markers at all — so adding a fourth outcome would
  make a legitimate no-findings review look like a defect. That trade (contract change
  in a shared boundary used by both PR paths, plus a phase-prompt change) is separate
  work outside this run's subject, not a violation this diff introduced. Reported as
  Major finding 2 so the call is not lost.
- **R3** — `docs/reports/foreman-beads:foreman:foreman-vbfmo.14/REVIEW_CODERABBIT_REPORT.md`
  was committed by phase 6, so there is nothing to fix about its tracking status; the
  stale note lives in a personal daily log, not in this repository.
- `docs/PRD/PRD-2026-f7a50d75-workspace-nav-run-provenance-links.md` — no requirement
  rewrites, no renumbering of REQ/AC IDs, no `Status: Draft → Approved` change:
  `docs/PRD/*` are point-in-time specs and AGENTS.md forbids restating them.
- `AGENTS.md` — untouched: 10382 bytes, already over its own "~10 KB" ceiling, so the
  fix for that lives in `docs/lessons/*`, not in a line added here.
- `packages/foreman_cli/cmd/foreman/main.go` — no new verb; `usage`/dispatch drift test
  not applicable.

## Verification

- `git diff "main"...HEAD --stat` → one file, +15 lines (exit 0). After fixes: `git diff --stat`
  → `docs/PRD/PRD-2026-f7a50d75-workspace-nav-run-provenance-links.md`, +13 lines (exit 0).
- `grep -n "FOREMAN_REVIEW_FINDINGS" docs/reports/foreman-beads:foreman:foreman-vbfmo.14/REVIEW_CODERABBIT_REPORT.md`
  → exit **1** (no markers). `grep -n` on this report → markers present (exit 0).
- `.coderabbit.yaml` `path_instructions` read; both diff ranges re-read against it and AGENTS.md §5.
- Documentation gate greps: `FOREMAN_SOURCE_PRD_PATH` unchanged (added nowhere, removed
  nowhere), no new/renamed identifiers, so CLAUDE.md, README.md, docs/user-guide.md and
  docs/cli-reference.md needed **no** edits — the diff adds no operator-visible surface.
- `devbox run -- bash -c 'cd packages/foreman_server && mix compile --warnings-as-errors'`
  → exit **0** ("Compiling 706 files (.ex)", zero warnings). This is the lint gate for the
  diff: `.formatter.exs` inputs are `{mix,.formatter}.exs`, `lib/**/*.ex`, `test/**/*.exs`
  only, so no file in this diff is a formatter input and there is no Markdown linter here
  (the one `mix format --check-formatted` invocation against a non-input path printed only
  the Mix banner; not a pass worth claiming).
- **`mix test` could not run: environment defect, not a red build.**
  `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/workflow/review_findings_test.exs'`
  → exit **1** before any test case, from `mix.exs:203 claim_database!/2`:
  `** (DBConnection.ConnectionError) [] connection not available and request was dropped from queue after 5995ms`
  with `FATAL 28P01 (invalid_password) password authentication failed for user "postgres"`
  against the default `postgres://postgres:postgres@localhost:55432/foreman_test`
  (`config/test.exs:7`). Verified independently: `PGPASSWORD=postgres psql -h localhost -p 55432 -U postgres`
  connects, `PGPASSWORD=wrongpass` fails identically, and `devbox.json` declares no
  `services` block — the run worktree's devbox never starts `foreman-postgres`, so the
  shared container's password does not match the repo default here. I did **not** widen
  `test_helper.exs`'s rescue to let the suite "pass" without a database (AGENTS.md: that
  is exactly the silent-success failure mode §5 forbids).
- Verification of the boundary this phase hands the PR builder, since the ExUnit file
  covering it could not boot: `devbox run -- bash -c 'cd packages/foreman_server &&
  MIX_ENV=test mix run ~/.foreman/phase7-verify/selfcheck.exs <abs path>'` calls
  `ReviewFindings.extract/1` on the real files → exit **0**,
  `REVIEW_CODERABBIT_REPORT.md` = `READ=yes EXTRACT=:none`,
  `REVIEW_REPORT.md` = `READ=yes EXTRACT=ok bytes=1492 bullets=3` (under `@max_bytes 4000`,
  so nothing truncates in the PR body). A temp-file matrix confirms the remaining clauses:
  markers → `{:ok, block}`; no markers → `:none`; start-without-end →
  `{:error, :unterminated_block}`; `nil` path → `:none`; unreadable file → `:none`.
  (Paths must be absolute — relative ones resolve under `packages/foreman_server` and
  return `:none`, which would have masked a missing block.)
- Fixes left **uncommitted** for Foreman to commit for this phase (`git status` →
  ` M docs/PRD/PRD-2026-f7a50d75-workspace-nav-run-provenance-links.md`).
- Operator status tools: `foreman_inbox_send` and `foreman_task_add_comment` were not
  exposed in this phase, so this artifact is the only status channel. Escalation paths
  named in the run's environment were also unavailable: `ask_advisor` →
  `Advisor model not found: openai-codex/gpt-5.5`, `contact_supervisor` → "works only
  inside a subagent" (both attempted in this phase).

<!-- FOREMAN_REVIEW_FINDINGS_START -->
- `docs/reports/foreman-beads:foreman:foreman-vbfmo.14/REVIEW_CODERABBIT_REPORT.md:11` Major — the task subject ("Bridge the agent ask tool to Telegram/Slack so Foreman can ask the operator a question and get an answer") does not match the delivered `FOREMAN_SOURCE_PRD_PATH` (`docs/PRD/PRD-2026-f7a50d75-workspace-nav-run-provenance-links.md`, a different feature already merged as PR #833/#834), so this run's PRD/TRD/implement phases all halted and produced zero code; an operator must either point the task at the PRD that actually describes the ask bridge (or author it) and re-run phases 1–4, or correct the title and abandon this run.
- `docs/reports/foreman-beads:foreman:foreman-vbfmo.14/REVIEW_CODERABBIT_REPORT.md:1` Major — that report carries neither findings marker, so `ReviewFindings.extract/1` answers `:none` exactly as for a clean review and nothing was machine-readable to carry forward (`review_findings.ex:38-46`); an owner must decide whether emitting the block is mandatory in the review-phase prompts.
- `packages/foreman_server/mix.exs:203` Major — `MIX_ENV=test mix test` cannot boot in this run worktree: `claim_database!/2` aborts with `FATAL 28P01 (invalid_password)` against `postgres://postgres:postgres@localhost:55432/foreman_test` (`config/test.exs:7`) because `devbox.json` declares no `services`; AGENTS.md's "a failing test is a failed build" gate is unprovable for dispatched runs until the Postgres service or a per-run `DATABASE_URL` is wired.
<!-- FOREMAN_REVIEW_FINDINGS_END -->
