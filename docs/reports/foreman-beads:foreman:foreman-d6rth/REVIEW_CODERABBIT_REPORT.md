Phase 3 (coderabbit-review) done.

**Engine:** CodeRabbit CLI 0.9.6, `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` (base=main) — exit 0, 2 rounds.

**Findings: 6 (1 major, 5 minor) — all fixed, 0 declined, 0 open.**
- Major: phase 2 truncated PLAN.md 154→25 lines (lost section 3 + Out of scope) → restored byte-identically from `534a5150`.
- Minor: PLAN.md greps self-matched the plan's own quoted strings → added `:(exclude)docs/reports` pathspec.
- Minors ×3: docs/user-guide.md paragraph wording (missing-`Artifact:`-line has two causes; `commit: false` phase PRs open before the artifact is committed; task-backed vs title-only AutoPR body rules) → rewritten.
- Minor: my own FIX_REPORT.md had `-run 'TestUserGuide\|TestUsageDrift'` — the escaped pipe matched no test, so exit 0 proved nothing → unescaped alternation + `-v`, plus a note that `TestUsageDrift` doesn't exist.

**Bead deliverable (phase 2 produced only a tool-error fragment, no later phase implements):** documented the one real gap — the generated PR body's `Artifact:` line is repo-relative or omitted, never an absolute host path — in `docs/user-guide.md` lines 3010-3024. `## PR body` / `pr_body_template` confirmed non-existent; not implemented (out of scope). Doc gate: no new identifiers; CLAUDE.md:1216, README.md:288, docs/cli-reference.md:622 already carry counterparts.

**Verification (exit codes):**
- `go test ./cmd/foreman/ -run 'TestUserGuide|TestUsageAdvertises…|TestCLIReferenceDocuments…|TestAgentCommandSpecs…|TestCLIReferenceNotImplemented…' -v` → 0 (6 PASS)
- `mix test --warnings-as-errors test/foreman_server/observability/docs_test.exs` (DATABASE_URL=…55432/foreman_test) → 0 (3 passed)

**Report:** `docs/reports/foreman-beads:foreman:foreman-d6rth/REVIEW_CODERABBIT_REPORT.md` — 5 sections + findings block (6 entries, source `coderabbit`, all `fixed`) + risk judgement LOW. JSON blocks validated (raw, outside fences, standalone markers).

Fixes **uncommitted** (Foreman commits): FIX_REPORT.md 117/1, PLAN.md 150/18, docs/user-guide.md 16/0, report untracked. Kata `ancq` closed; operator notified via inbox (`msg_JOhiPrN3r2Yyirp9kYebmg`).