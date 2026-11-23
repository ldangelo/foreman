# PLAN — foreman-zv8bi: add `base_ref_policy` project setting

## 0. Recovery note (phase 3, coderabbit-review)

The 215-line plan authored in phase 1 was committed at `9db30e48`, then
overwritten at `3c5aa4eb` by a 20-line phase-2 status summary (that summary is
reproduced verbatim as §5). CodeRabbit round 1 flagged the truncation as
`minor`; this fix restores the plan body from `git show 9db30e48:<path>` and
keeps the phase-2 note as a section instead of letting it replace the plan.
No production code was written by any phase of this run — see
`REVIEW_CODERABBIT_REPORT.md`.

## 1. Verdict

Real gap, feature absent. `grep -rn base_ref_policy packages/foreman_server/lib packages/foreman_server/test docs` → zero hits on `f0f3b083`. The setting whitelist `ForemanServer.Aggregates.Project.Settings.@keys` (`packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex:47-51`) ends at `notification_preference required_checks`.

Scope note: this bead adds **only the setting** (key + validator + typed event field + read model + dashboard form). The sibling bead ("fetch `origin/<base>` before creating the run worktree") is NOT part of this task; no run/worktree/PR code reads the new key yet, so this change is behaviour-neutral by design. Do not touch `run_executor.ex`, `vcs_adapter*`, `exec/git.ex`.

Wire-format decision: settings travel as typed JSON event fields, so atoms do not round-trip. Store the policy as the **strings** `"origin"` / `"checkout"`, exactly like `notification_preference` (`settings.ex:332-343`). Default is "unset", which readers must treat as `origin`; do not write a default value into config.

## 2. Root cause

No key is declared, so `project.update` with `base_ref_policy` is rejected by the open-config whitelist (`{:unknown_setting, "base_ref_policy"}`, `settings.ex:221`). Every downstream surface derives from `Settings.keys/0` except the typed event struct and the LiveView field lists, which are hand-maintained and must be extended.

## 3. Failing check first

Add to `packages/foreman_server/test/foreman_server/aggregates/project_settings_test.exs`, immediately after the `describe "notification_preference"` block (ends line 188), mirroring it:

```elixir
  describe "base_ref_policy" do
    test "accepts origin and checkout, normalising case and whitespace" do
      for policy <- ~w(origin checkout) do
        assert {:ok, %{base_ref_policy: ^policy}} =
                 Settings.normalize(%{base_ref_policy: " " <> String.upcase(policy) <> " "})
      end
    end

    test "rejects anything else with a distinct tuple listing the allowed values" do
      assert {:error, {:base_ref_policy_invalid, "upstream", allowed}} =
               update(registered(), %{base_ref_policy: "upstream"})

      assert allowed == Settings.base_ref_policies()
    end
  end
```

Run narrow first, then the repo's full gate.

## 4. The eleven edits

### 4.1 `lib/foreman_server/aggregates/project/settings.ex` — no length attribute

`base_ref_policy` is a closed enum, so it needs no length attribute. There is no generic string-attribute table in `settings.ex`: free-text limits are per-key constants (`@max_goal_chars` 29, `@max_instructions_chars` 30, `@max_model_chars` 31) enforced by `text/3` (481-503), and the other enum-ish settings (`notification_preference` 332-343, `coordinator_provider` 274-285, `thread_model`/`coordinator_model` 273/286) are validated purely by membership. `base_ref_policy` follows the latter: the value is bounded by the allowed-values list, so a length cap would be dead code.

### 4.2 `settings.ex` — whitelist the key

Append `base_ref_policy` to `@keys` (47-51). This single list drives `keys/0` (135), and every consumer below reads that list, so the new key needs no per-key code anywhere else: the aggregate accepts and normalises it (`aggregates/project.ex:909` `setting_keys = Settings.keys()`, `:941` `Enum.reduce(Settings.keys(), config, ...)`), the projection folds it into the projected config (`projection_store.ex:4979`), the read model derives its struct from it (`project_settings.ex:7` `@keys ForemanServer.Aggregates.Project.Settings.keys()`), and `check_config_keys/1` (`settings.ex:221-233`) stops rejecting it as `{:unknown_setting, key}` (232). MCP is the exception: `foreman_project_settings_update` has a hand-written JSON schema (`mcp/tools.ex:502-580`) plus an allowlist `@settings_update_keys` (2502-2506) — see 4.10.

### 4.3 `settings.ex` — `@type key`

Add `| :base_ref_policy` to `@type key` (lines 58-76). Required: `@keys` is not derivable from the typespec, and `normalize/1` (202) is specified `{:ok, %{optional(key()) term() | nil}}` — a key in `@keys` with no `key()` alternative is a typespec error that `mix test --warnings-as-errors` surfaces via dialyzer in CI.

### 4.4 `settings.ex` — `@type error`

Add `| {:base_ref_policy_invalid, term(), [String.t()]}` next to `{:notification_preference_invalid, term(), [String.t()]}` (line 102). `term()` (not `String.t()`) because a non-string value is refused with the same tuple — the value is echoed back as-is.

### 4.5 `settings.ex` — allowed-values list

```elixir
  @base_ref_policies ~w(origin checkout)
  @doc "Allowed values for `:base_ref_policy` (stored as strings; unset means `\"origin\"`)."
  def base_ref_policies, do: @base_ref_policies
```

The attribute sits next to `@notification_preferences` (line 45) and the function next to `notification_preferences/0` (lines 130-131). Needed by the validator, the error tuple, the test, the dashboard select, and `user-guide.md`.

### 4.6 `settings.ex` — validator clause

In `validate/2` (clauses start line 271), next to the `:notification_preference` clause (332-343):

```elixir
  defp validate(:base_ref_policy, nil), do: {:ok, nil}

  defp validate(:base_ref_policy, value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> {:ok, nil}
      policy when policy in @base_ref_policies -> {:ok, policy}
      _ -> {:error, {:base_ref_policy_invalid, value, @base_ref_policies}}
    end
  end

  defp validate(:base_ref_policy, value),
    do: {:error, {:base_ref_policy_invalid, value, @base_ref_policies}}
```

Trim + lowercase like the `notification_preference` clause (334-340); `nil` and a blank string both mean "unset" (`{:ok, nil}`), matching how the LiveView submits an empty select as `nil`. The last clause refuses a non-string with the same tuple, as `notification_preference` does (342-343). `normalize/1` (line 202) is the only caller of `validate/2` and needs no edit.

### 4.7 `lib/foreman_server/events/project_updated.ex` — typed event field

`@type t` (12-35) gains `base_ref_policy: String.t() | nil` (next to `notification_preference` 32) and `defstruct` (37-60) gains `:base_ref_policy` (next to `:notification_preference` 57). Both lists are hand-maintained and must match `Settings.keys/0` exactly, or the aggregate parity test ("keys/0 is the single table the typed event mirrors", `test/foreman_server/aggregates/project_settings_test.exs:431-434`) fails. The projection fold is key-driven (`projection_store.ex:4979`) and the aggregate's `project.update` handler is key-driven (`aggregates/project.ex:178-198`) — neither needs an edit.

### 4.8 `lib/foreman_server/project_settings.ex` — read model

`@type t` (9-27) gains `base_ref_policy: String.t() | nil` (next to `notification_preference` 26). `defstruct @keys` (line 30) picks the field up automatically because `@keys` is `ForemanServer.Aggregates.Project.Settings.keys()` (line 7), and `from_config/1` (44-46) maps over `@keys` — no per-key code.

### 4.9 `lib/foreman_server_web/project_settings_live.ex` — whitelist + form

(Verified path: `packages/foreman_server/lib/foreman_server_web/project_settings_live.ex` — there is no `live/` subdirectory under `foreman_server_web`; `find packages -name project_settings_live.ex` yields exactly this file.)

One hand-maintained list must gain the key:
- `@text_fields` (lines 57-58, the list ending `coordinator_effort notification_preference)a`): add `:base_ref_policy`. This single list drives the whole form path: `load_form/1` (line 434-452) builds the form from `@text_fields ++ @int_fields ++ @bool_fields ++ @list_fields` via `Map.new(..., fn key -> {Atom.to_string(key), form_value(Map.get(settings, key))} end)`, so the field is populated from the read model automatically; `changed_settings/2` (507-509) and `to_settings/1` (514-521) both read that same list, so the value is submitted as a string and `blank_to_nil(raw)` turns an empty selection into `nil` (unset). Without the `@text_fields` entry the key can neither be shown nor submitted, and the save silently drops it.

Render it with the module's own `field/1` helper, one line below `notification_preference` (line 880). The helper takes `name`, `label`, `errors`, `form`, `kind`, `options`, `help`, `described_by` (attrs at 1081-1088), derives the input id as `"settings_#{@name}"` and, when `options` is non-nil, emits a `<select>` whose first option is `<option value="">(default)</option>` (1098-1104). No custom markup and no ids to mint:

```heex
<.field name="base_ref_policy" label="PR base ref" errors={@errors} form={@form} options={@base_ref_policies} help="Where a run's PR base is taken from. (default) is origin: the remote-tracking branch. checkout uses the branch checked out in the run worktree. Registered only: no run code reads it yet (the sibling bead that consumes it is not in this task)." />
```

and add `base_ref_policies: Settings.base_ref_policies(),` to the `assign(...)` block at the head of `render/1` (828-838), the same way line 833 already supplies `notification_preferences: Settings.notification_preferences(),`.

The `help` text says the setting is registered only and not yet read by run code — it must not imply the PR base already follows it (§1 scope note).

`error_field/1` (591-606) maps error atoms by prefix rule — `:base_ref_policy_invalid` starts with `"base_ref_policy_"`, and the rule looks the tag up in `Settings.keys()`, so no new clause is needed once 4.2 adds the key.

### 4.10 Tests

- Aggregate accept/reject test from §3 in `test/foreman_server/aggregates/project_settings_test.exs`.
- Parity test at `test/foreman_server/aggregates/project_settings_test.exs:431-434` asserts `ProjectUpdated` struct fields == `Settings.keys()`; it passes for free once 4.7 is done — verify it, don't duplicate it.
- `test/foreman_server/project_settings_read_model_test.exs`: extend the `describe "ProjectSettings.from_config/1"` block (line 84) with `base_ref_policy: "checkout"` so the read model is pinned too.
- `test/foreman_server_web/live/project_settings_live_test.exs`: two existing tests pin the form path and must stay green — "the notification preference saves and (default) clears it" (line 324) is the template for a select-backed enum (save, then clear with the empty selection), and "labelled controls: every settings field has a label bound by for/id" (line 516) requires the new field to carry a `for`/`id` pair, which the `field/1` helper supplies. There is no `Settings.keys()`-vs-form parity test in this file, so no allow-list needs editing.
- `test/foreman_server/mcp/tools_project_settings_test.exs`: add `base_ref_policy` to the `operator_only` list in "every project setting is either settable over MCP or declared operator-only" (line 243) — the key is not an MCP argument, and that test compares `settable ++ operator_only` against `Settings.string_keys()`, which contains every `@keys` member. It fails otherwise.

### 4.11 Docs (documentation gate)

Externally visible identifier added: config key `base_ref_policy`.
- `docs/user-guide.md`: add a row to the project-settings table after `notification_preference` (line ~731) documenting `origin` (default) / `checkout`, that unset behaves as `origin`, and that the setting is registered only — no run code reads it yet (the consumer is a sibling bead), so operators must not expect it to change PR bases in this release.
- `CLAUDE.md:1240`: add `base_ref_policy` to the `Settings.keys()` list, and to the "operator-only via the settings form" parenthetical at 1246-1251 alongside `notification_preference`.
- `README.md`: no edit — it never enumerates setting keys (grep `notification_preference` → no hits).
- `docs/cli-reference.md`: no edit — no new CLI flag or MCP argument is introduced; `foreman project update` already passes whitelisted keys through generically.
- No Go source change ⇒ `usage_drift_test.go` stays green.

## 5. Phase-2 note (verbatim, preserved from the overwritten plan)

Advisor unavailable (Anthropic refresh token expired — known env issue, noted in scratchpad).

### Done: plan written

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
