

Repo-rules review phase complete.

**Review range:** `git diff main...HEAD` (merge-base `0988b071`, HEAD `169b8d4a`) — 5 files.

**Findings (4 own + 1 carried, 3 fixed / 1 declined):**

| # | Sev | File | Disposition |
|---|---|---|---|
| R1 | major | `packages/foreman_server/test/.../skill_resolver_test.exs:147` | fixed — test never seeded the skill, so `:unverifiable` couldn't distinguish unusable home from absent skill. Now seeds `put_skill!` and asserts `:available` under the usable home first |
| R2 | minor | `.../FIX_REPORT.md:1` | fixed — fix phase committed an 86-byte tool-error fragment; rewritten with `fix.md`'s six sections |
| R3 | minor | `.../PLAN.md:1` | fixed — fix phase overwrote the 134-line plan with a 10-line summary, though `fix.md` says "Do not commit `PLAN.md` and do not edit it."; restored byte-identical from `40c1d78a` |
| R4 | nitpick | `docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md:645` | declined — AGENTS.md keeps point-in-time PRD/TRD claims as written; no limitation entry for this raise exists there |
| C1 | major | `skill_resolver_test.exs:147` | carried from the CodeRabbit phase (prose-only report, no machine block) — undefined `base_ctx/0` CompileError, already fixed in phase 3 |

**Fixes left uncommitted** for Foreman's phase commit: `FIX_REPORT.md`, `PLAN.md`, `skill_resolver_test.exs` (+6); new `REVIEW_REPORT.md`.

**Verification (exit codes):** `skill_resolver_test.exs` 53 passed / 0 · `run_executor_skill_preflight_test.exs` 18 passed / 0 · `mix format --check-formatted` 0 · AGENTS.md full gate 9255 passed / 0 (822 s; needs `DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test` — the default devbox URL fails `28P01`). Regression probe with the pre-fix resolver from `main`: 52/53, exit 2, `** (FunctionClauseError) no function clause matching in Path.type/1` (`lib/path.ex:249` ← `skill_resolver.ex:128` ← `skill_resolver_test.exs:153`) → the seeded test bites.

**Artifact:** `docs/reports/foreman-beads:foreman:foreman-ttc4i/REVIEW_REPORT.md`, validated by the real pipeline readers — `Workflow.ReviewFindings.read/1` ⇒ `:recorded` (5 findings), `PrRisk.parse_judgement/1` ⇒ `status recorded`, `level MEDIUM`, `defect nil`.

**Doc gate:** no externally visible identifier added/removed/renamed; greps of `SkillResolver`/`user_home`/`:skill_home` in CLAUDE.md, README.md, docs/user-guide.md, docs/cli-reference.md found no stale reference → none of those four needed edits; only the run's own `PLAN.md`/`FIX_REPORT.md` did.

**Notes:** kata issue `vw0g` created + closed with evidence; memory updated (3 new lessons: `System.user_home/0` is boot-time captured, `git checkout --` can revert intended test edits, devbox full-suite needs DATABASE_URL). `foreman_inbox_send` / `foreman_task_add_comment` are not exposed in this phase, so no operator note was sent. `ask_advisor` still unusable (Anthropic oauth 400 `invalid_grant`, "Refresh token expired").