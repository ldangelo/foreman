

**Phase 4 `repo-rules-review` — done.** Task `beads:foreman:foreman-uvzfs`, run `run-a9ee2749eb92b7d7896ed91d3155995d`.

**Range reviewed**: `git diff "$FOREMAN_BASE_BRANCH"...HEAD` (`main` set) → merge-base `4099cce4` → HEAD `eeb9fec9`; 10 files, +198/−50. Nothing excluded.

**Findings (4)**
1. **major — FIXED** `docs/reports/.../REVIEW_CODERABBIT_REPORT.md:15` — Foreman's phase-3 commit `eeb9fec9` (+7/−74) rewrote the agent's 80-line artifact into 13 lines and stripped BOTH machine-read blocks, while the file still claimed "re-parsed → `:recorded`, MEDIUM". Result: `ReviewFindings.read/1` = `:absent` (not a clean review) and PR Review section = only the "review evidence is missing" notice — the exact symptom in the bead. Repaired: prose untouched, both blocks re-appended verbatim from `git show 7231b23c:…` → re-parses `{:recorded, 2 findings}` + `recorded/MEDIUM`.
2. **major — OPEN** `packages/foreman_server/lib/foreman_server/workflow/phase_pr.ex:345` — bead feature still unimplemented on branch AND main: title hardcoded `feat(phase): <phase>`, absolute artifact path leaked at `:349`, no `## PR body` / `pr_body_template` support. Root cause = this run: no `PLAN.md` ever produced (fix phase wrote only `Blocked: no plan found`) because bundled `fix.yaml` at base `4099cce4` had no plan phase. Not implemented here: no plan, needs a project-settings schema decision + one shared body builder across `PhasePR`/`AutoPR`/`RunExecutor.maybe_record_phase_pr` (§5.7). **Remedy: rebase onto main + re-run the bead** — main's `fix.yaml` now carries the plan phase (line 44 → `PLAN.md`).
3. **major — FIXED (earlier phase, re-verified)** `fix.yaml:35` bogus `/enseble:merge-pr --foreman` → restored prompt-driven 4-phase manifest; every phase key inside `PhaseSpec.@fields`; pins read by `RunExecutor.phase_model/2` + enumerated in `bundled_workflow_models_test.exs` + documented in user-guide §7.3.
4. **major — DECLINED** `prompts/fix.md:22` (carried, coderabbit) — byte-identical to upstream `main` ⇒ pre-existing, ships via `foreman init --force`, outside this run's scope.

**Verification**
- `mix test --warnings-as-errors test/foreman_server/workflow/` → `1564 passed`, 0 failures (348.3 s), exit 0.
- `mix format --check-formatted` → exit 0 (only Markdown changed).
- Both artifacts re-parsed: `{:recorded, …}` + `recorded/MEDIUM`.
- Doc gate: `fix.yaml`/`claude-opus-5`/`qwen-flash-next` hit only `docs/user-guide.md`; `CLAUDE.md`, `README.md`, `docs/cli-reference.md` need no edit (no route/CLI verb/MCP tool/env/config change). `enseble`/`merge-pr` gone repo-wide.

**State**: changes uncommitted (Foreman commits) — `M REVIEW_CODERABBIT_REPORT.md`, `?? REVIEW_REPORT.md`. Base staleness: branch is *behind* main (`git diff main -- packages/foreman_server/priv/defaults/workflows/` empty), not divergent. Kata `583v` commented + closed with test evidence.

**Escalation blocked**: `foreman_inbox_send` / `foreman_task_add_comment` not exposed; `contact_supervisor` → "works only inside a subagent". No operator note sent — this artifact is the only channel.