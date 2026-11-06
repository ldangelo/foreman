Phase 7 complete.

**Review engine**: repo-rules pass over `git diff main...HEAD` (`FOREMAN_BASE_BRANCH=main`, base `4ee1b417`, HEAD `5c3c3293`). That range was **one file** — phase 6's `REVIEW_CODERABBIT_REPORT.md` (+15 lines). Zero code, zero PRD/TRD: phases 1–5 halted on the task-title vs `FOREMAN_SOURCE_PRD_PATH` mismatch.

**Carry forward**: the sibling report is present but carries **neither findings marker** → `ReviewFindings.extract/1` returns `:none` (verified by running the real function). Its prose finding (line 11, the mismatch) is carried forward as Major 1.

**One fix, uncommitted** (13 lines): `docs/PRD/PRD-2026-f7a50d75-workspace-nav-run-provenance-links.md` — forward-pointing note under the h1 + changelog entry, per `.coderabbit.yaml` (`docs/PRD/**`: a stale/mismatched PRD is fixed *only* by a forward-pointing note). No requirements, scores or `Status` touched.

**Declined**: a 4th outcome for `review_findings.ex:39-46` (§5.3 "absent ≠ malformed") — its `@spec`/moduledoc deliberately fold missing-file/no-markers into `:none`, both callers already render a visible empty section, and phase 6's prompt never mandates markers; that's a boundary contract + phase-prompt decision outside this run's subject. Also declined: doc-gate edits (no identifier added/renamed), `AGENTS.md` (10382 B, already over its ceiling — belongs in `docs/lessons/`).

**Verification**: `mix compile --warnings-as-errors` exit 0 (706 files, no warnings). `MIX_ENV=test mix test review_findings_test.exs` **exit 1 before any test** — `mix.exs:203 claim_database!/2`: `FATAL 28P01 (invalid_password) user "postgres"` vs `config/test.exs:7`, because `devbox.json` declares no `services`; reported as Major 3 rather than hiding it behind a widened rescue. Substitute proof: extract on my report → `EXTRACT=ok bytes=1492 bullets=3` (under `@max_bytes 4000`), on the coderabbit report → `:none`.

Report at `docs/reports/foreman-beads:foreman:foreman-vbfmo.14/REVIEW_REPORT.md`, 3 Major unresolved findings for an operator: point the task at (or author) the real ask-bridge PRD and re-run phases 1–4, decide whether the findings block is mandatory, and fix test-DB boot in run worktrees.