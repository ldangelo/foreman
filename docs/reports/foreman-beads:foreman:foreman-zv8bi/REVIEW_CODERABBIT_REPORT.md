Phase 3 (coderabbit-review) done.

**Engine**: `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` (base=main), exit 0 on all 3 rounds, CLI 0.9.6. Bodies re-read from CodeRabbit's own cache (`~/.coderabbit/reviews/…/*.json`) — CLI printed `<<ccr:…>>` placeholders.

**Findings**: 4, all `minor`, all on `docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md`, all fixed, none declined.
1. `PLAN.md:5` — phase-2 commit had overwritten the 215-line plan with a 20-line summary → restored full plan from `9db30e48` + §0 recovery note.
2. `PLAN.md:113` — HEEx used undefined `@base_ref_policy_id` → now `options={@base_ref_policies}` + `base_ref_policies: Settings.base_ref_policies()` assign.
3. `PLAN.md:84` — validator clause missing `when` → `defp validate(:base_ref_policy, value) when is_binary(value) do`.
4. `PLAN.md:116` — help text promised behavior no run code implements → now "Registered only: no run code reads it yet".

**Verification**: `mix format --check-formatted` exit 0; `mix test test/foreman_server/workflow/review_findings_test.exs test/foreman_server/pr_risk_test.exs --warnings-as-errors` → 105 passed, 0 failures; `ReviewFindings.read/1` → `{:recorded, findings: 4}` (all `:fixed`/`:minor`); `PrRisk.parse_judgement/1` → recorded / LOW.

**Artifact**: `docs/reports/foreman-beads:foreman:foreman-zv8bi/REVIEW_CODERABBIT_REPORT.md` (parser-verified, both marker blocks last). Fixes left uncommitted for Foreman.

**Noted**: the `base_ref_policy` feature itself is still unimplemented (zero hits in `packages/foreman_server/lib|test`) — that is the next phase's work, per PLAN.md §4.1–§4.11.

**Also**: kata issue `afjh` created/claimed/commented/closed; operator inbox note sent and task Work Log comment added (both tools worked).

**Restored in phase 4**: Foreman's phase-3 commit replaced this artifact with the summary above and dropped both machine-read blocks (the phase-3 agent's own version is in commit `c678205f`). The findings block below is restored verbatim from that commit. The judgement block keeps phase 3's level (`LOW`); its rationale is rewritten here, because the rationale stored in `c678205f` is a compression placeholder rather than text.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema":"foreman.review_findings/1","reviewed":true,"findings":[{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md","line":5,"description":"The phase-2 commit replaced the 215-line executable plan with a 20-line summary, so the plan path later phases read contained no plan.","disposition":"fixed","source":"coderabbit"},{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md","line":113,"description":"The proposed HEEx referenced an undefined @base_ref_policy_id assign and never supplied the option list, so the settings page would raise undefined assign.","disposition":"fixed","source":"coderabbit"},{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md","line":84,"description":"The validator clause omitted `when` before is_binary(value), so the snippet would not compile if copied into settings.ex.","disposition":"fixed","source":"coderabbit"},{"severity":"minor","path":"docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md","line":116,"description":"The form help text promised the selection controls the PR base although no run code reads the key, letting an operator choose checkout and see no effect.","disposition":"fixed","source":"coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema":"foreman.risk_judgement/1","level":"LOW","rationale":"Phase 3 reviewed only the plan document: the branch carried no production code, so the four minor findings were all plan-text fixes and no runtime behaviour was at risk."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
