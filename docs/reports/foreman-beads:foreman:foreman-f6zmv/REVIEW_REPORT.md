Phase 4 done. Summary:

**Reviewed** (`git diff main...HEAD`, merge-base `c209f8b4` → `5c0d080f`, 7 files) against `AGENTS.md`. The bead fix (`approvals/sweeper.ex` +20/-2, `sweeper_test.exs` +37/-0) was already implemented by phase 2 — `on_timeout` resolved+validated in `Sweeper.init`, raising `ArgumentError` at start instead of `Config.on_timeout/0` raising mid-sweep. Complies with §5.2/5.3/5.4/5.7, surgical-change, doc-gate, testing rules.

**Fixed (2)** — report artifacts only:
- `FIX_REPORT.md` was 1 line of plan narration → rewritten with defect, per-file change, doc-gate outcome, verification.
- `REVIEW_CODERABBIT_REPORT.md:14` claimed its machine blocks parsed as recorded + file untracked → both false (`ReviewFindings.read/1` → `:absent`; `PrRisk.parse_judgement/1` → `status: "absent"`; committed by `5c0d080f`). Dated correction appended.

**Open (1)** — branch carries unrelated commit `018da6b1` (herdr-sidebar next/prev tab keys), already merged upstream as PR #960 → merge with `main` conflicts in `ops/herdr-sidebar/keys.layout-foreman.json` (probe: exit 1, 1 conflicted file). Fixing needs branch surgery that rewrites phase commit SHAs → operator call.

**Declined (2)** — nitpicks: raise message doesn't say option-vs-config source; policy resolved once at init (no runtime writer exists in `lib/`).

**Written**: `docs/reports/foreman-beads:foreman:foreman-f6zmv/REVIEW_REPORT.md` — 5 findings + `foreman.review_findings/1` (validated `{:recorded, 5 findings}`) + `foreman.risk_judgement/1` (validated `recorded LOW`).

**Validation**: `mix format --check-formatted` 0, `mix compile --warnings-as-errors` 0, `mix test --warnings-as-errors test/foreman_server/approvals/` 0 (75 passed).

**Doc gate**: no identifiers added/removed/renamed; only `docs/user-guide.md:3427` mentions `on_timeout` and stays accurate → no doc edit needed; point-in-time decision/TRD limitation lists left as written.

Fixes left uncommitted for Foreman. kata issue `bazm` closed with evidence. Two notes: `ask_advisor` unavailable (Anthropic oauth `invalid_grant` — operator re-auth needed); one accidental in-worktree merge during conflict probing was recovered via `git merge --abort` (lesson saved to memory).