Advisor unavailable (Anthropic refresh token expired — known env issue, noted in scratchpad).

## Done: plan written

`docs/reports/foreman-beads:foreman:foreman-zv8bi/PLAN.md` (215 lines). No code touched, no commit, no branch ops.

**Verdict:** real gap. `base_ref_policy` absent everywhere on `f0f3b083` (zero grep hits in lib/test/docs). Whitelist `Settings.@keys` (`settings.ex:47-51`) ends at `notification_preference required_checks`.

**Key plan decisions:**
- Store as **strings** `"origin"`/`"checkout"`, not atoms — settings ride as typed JSON fields on `Events.ProjectUpdated`; atoms don't round-trip. Mirrors `notification_preference` (`settings.ex:332-343`).
- Default = unset (nil), read as origin. No default written into config.
- **Operator-only**: not an MCP arg; instead added to `operator_only` in `tools_project_settings_test.exs:243` (that parity test fails the build otherwise).
- **Scope = registration only.** No reader added; `run_executor.ex`, `vcs_adapter*`, `exec/git.ex`, `run_base_branch_recorded.ex`, `recommendations.ex` are sibling beads, explicitly out of scope.
- No Go CLI flag → no `cli-reference.md` edit → `usage_drift_test.go` stays green.

**11 numbered edits:** `settings.ex` (attr, `@keys`, `@type key`, `@type error`, `base_ref_policies/0`, validator clause), `events/project_updated.ex` (typespec + defstruct — pinned by `project_settings_test.exs:431-434`), `project_settings.ex` (typespec only; `defstruct @keys` auto-picks), `project_settings_live.ex` (`@text_fields`, assign, select field; `error_field/1` prefix rule already covers `:base_ref_policy_invalid`), 5 new tests, docs.

**Doc gate (stated in plan §4.11):** added identifier `base_ref_policy`. `docs/user-guide.md` → new settings-table row after :731. `CLAUDE.md:1240` → add to `Settings.keys/0` list + operator-only parenthetical. `README.md` / `docs/cli-reference.md` → no edit, no CLI flag or MCP arg added.

**Verification command in plan:** 4 narrow test files + `mix format --check-formatted`, then full `MIX_ENV=test mix test --warnings-as-errors`. Not run — this phase writes no code.