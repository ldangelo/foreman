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