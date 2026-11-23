

**Phase done — repo-rules review, run-0c30344c (bead foreman-qdt14)**

**Scope**: `git diff "$FOREMAN_BASE_BRANCH"...HEAD` = `main...4a8a7bec` (merge-base f0f3b083), 13 files. Base set, no substitute. Carried-forward findings: **none** — prior `REVIEW_CODERABBIT_REPORT.md` is empty (2 B).

**Findings (5): 3 fixed / 2 declined**

| sev | location | issue | disp |
|---|---|---|---|
| major | `packages/foreman_server/lib/foreman_server/projects/recommendations/facts.ex:8` | moduledoc safety rules still claimed repo content never read / no command runs in repo — new in-repo `git rev-list` probe contradicts it | fixed |
| minor | `docs/cli-reference.md:336` | probe sentence still said only `gh auth status` runs, "nothing from the repository is executed" | fixed |
| minor | `.plan_full.md:1` | stray root copy of committed report `PLAN.md`, zero refs | fixed (deleted) |
| minor | `docs/acceptance/parity-audit.md:48` | detector counts stale | declined — point-in-time audit pinned `origin/main@126ff019`, outside doc-gate set |
| nitpick | `packages/foreman_server/lib/foreman_server/projects/source_branch.ex:22` | `..` allowed in branch name reaches rev-list range arg | declined — argv not shell, `..` not a legal branch name, state unreachable |

**Fixes** (uncommitted, per phase): facts.ex moduledoc bullet + new bullet documenting the single read-only, never-fetching, `core.fsmonitor`/`extensions.partialclone`-cleared command; cli-reference.md:336 probe sentence; `git rm .plan_full.md`.

**Verification** (from `packages/foreman_server`)
- `DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors <4 files>` → exit 0, **40 passed** (first attempt died on ambient `DATABASE_URL` → wrong container, not a code failure)
- `mix format --check-formatted` → exit 0; `MIX_ENV=test mix compile --warnings-as-errors` → exit 0 (all 5 `Probe` impls satisfy new `cmd_out/3`); credo `--min-priority higher` → exit 0. dialyzer/doctor skipped (comment/Markdown-only).
- Artifact `docs/reports/foreman-beads:foreman:foreman-qdt14/REVIEW_REPORT.md` — both machine blocks checked with the **real** parsers: `ReviewFindings.read/1` → `:recorded` (5 findings), `PrRisk.parse_judgement/1` on contents → `:recorded`, level LOW.
- Re-read of the fixed diff: no new violation introduced.

**Doc gate**: my phase added **no** externally visible identifiers. `branch.behind_origin` already documented in `docs/user-guide.md:686` + `docs/cli-reference.md:336`; `CLAUDE.md`/`README.md` carry no detector-id list → no edits needed.

**Notes**: `foreman_inbox_send` / `foreman_task_add_comment` not exposed in this phase → no operator notes sent. `ask_advisor` failed again (Anthropic oauth `invalid_grant`, refresh token expired) — the LOW judgement rests on my own reasoning. kata `pzx2` created, claimed, closed with test evidence.