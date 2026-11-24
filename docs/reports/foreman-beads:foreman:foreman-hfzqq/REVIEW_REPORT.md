

**Phase 4 `repo-rules-review` — done**

**Range:** `git diff 39303e89...HEAD` (merge-base origin/main↔HEAD; local `main` stale at `4f37fa96`). 11 files, +368/−2. Commits: `11abfc35` → `aca39923` → `67f73051` → `40e8db7a` → `b8040fbf`.

**Findings: 14** (6 carried coderabbit, 8 own repo-rules) — 13 fixed, 1 declined.

**Fixed (uncommitted, Foreman commits):**
- `docs/user-guide.md` §7.3 — injection point `prepare_agent_launch/5` → `build_agent_launch/10`; scope "every pi worker" → "every pi **phase** worker"
- `docs/lessons/phase-execution-and-pr-mechanics.md` — same two errors
- `CLAUDE.md:413` — same over-broad scope (README:308, cli-reference:759 were already right)
- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:1251` — comment narrowed
- `REVIEW_CODERABBIT_REPORT.md` — **restored** from `40e8db7a`; Foreman's own phase-3 commit `b8040fbf` had replaced the agent's compliant report with a prose-only file, dropping both machine-read blocks
- `FIX_REPORT.md` — was a 63-byte fragment; now fix.md's six sections

**Declined:** stale pre-existing `foreman_env/3` refs (lessons + AGENTS.md, not in diff); marking review evaluator's pi launch (PLAN.md §6 scope).

**Artifact:** `docs/reports/foreman-beads:foreman:foreman-hfzqq/REVIEW_REPORT.md` — parser-verified: `ReviewFindings.read/1` ⇒ recorded, 14 findings, 0 malformed, sources `{coderabbit: 6, repo-rules: 8}`; `PrRisk.parse_judgement/1` ⇒ recorded, MEDIUM, defect nil; markers 1× each.

**Verified:** 87 tests green (exit 0) · `mix format --check-formatted` exit 0 · `go build/vet/test` exit 0 (incl. `usage_drift_test.go`).

**Quirk:** DB here = `foreman-pg-phase0` on **55433**, not 55432 as PLAN.md §5 says.

**Sent:** inbox note `msg_BW8NF4JYc1FskO3QPvrDRQ` + task Work Log comment (both OK). Kata `7x01` closed w/ evidence.