

Phase 3 (repo-rules-review) complete.

**Reviewed**: `git diff main...HEAD` — 3 files (2 phase report artifacts + `packages/foreman_server/priv/defaults/workflows/fix.yaml`).

**Fixed (3, left uncommitted per phase contract)**
1. **major** — `fix.yaml`: commit `dd0c239b` had replaced the bundled manifest with 2 raw `command:` phases (`/ensemble:fix-issue`, `/ensemble:pr-merge`), deleting the bundled `coderabbit-review` + `repo-rules-review` phases, bypassing `validator.ex`'s `/skill:` allowlist, and leaving the workflow suite red (1561/1564). Restored byte-for-byte to merge base `4099cce4` → `git diff 4099cce4 -- <path>` empty, so the branch contributes no change and main's plan-first manifest wins on merge. Deliberately did **not** adopt main's model pins (branch lacks `BundledWorkflowModelsTest` allowlist + `prompts/fix-plan.md`; pins would hard-fail preflight `model_not_found`).
2. **major** — `REVIEW_CODERABBIT_REPORT.md`: claimed both machine-read blocks parsed; file had **zero** marker blocks. Blocks added (2 findings, LOW); false claim + wrong "pre-existing failure" attribution corrected.
3. **minor** — `FIX_REPORT.md`: false "sole content" claim; line 1 now the exact `Blocked: no plan found` token.

**Open (operator)** — bead's 5-point objective unimplemented: `PI_SUBAGENT_CHILD` = 0 hits under `packages/`; no effective-model assertion, no model surfacing, no `stopReason=length` handling. Root cause upstream: run executed installed `~/.foreman/workflows/fix.yaml` but no PLAN.md ever produced (no phase-0 prompt in `~/.foreman/runs/run-2f7c.../archive/`), so phase 1 stopped honestly and phases 2–3 reviewed an empty diff. Remedy: `foreman init --force`, rebase onto main, re-run bead.

**Declined (3)** — stale-branch pin (9 commits behind main), installed-copy drift, untracked `.pi-subagents/`.

**Verification** (all exit 0): `mix test --warnings-as-errors test/foreman_server/workflow` → **1564 passed** (was 1561/1564); `catalog_test.exs` → 29 passed; both artifacts re-parsed with `ReviewFindings.read/1` + `PrRisk.parse_judgement/1` → `{:recorded,…}`, judgements LOW/MEDIUM, one marker pair each. Doc gate: no externally visible identifier changed; greps of CLAUDE.md/README.md/docs/user-guide.md/docs/cli-reference.md → no hits, none needed edits. No `.ex/.exs` edited ⇒ formatter N/A.

Report: `docs/reports/foreman-beads:foreman:foreman-g9mlf/REVIEW_REPORT.md` (8 findings, MEDIUM). Kata `9j92` created + closed. `ask_advisor` unavailable (Anthropic `invalid_grant`); `contact_supervisor` refused (not a subagent) — both noted in the report.