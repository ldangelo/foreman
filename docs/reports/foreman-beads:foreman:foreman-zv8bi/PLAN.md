# PLAN — foreman-zv8bi: add `base_ref_policy` project setting

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

      assert allowed == ~w(origin checkout)

      assert {:error, {:base_ref_policy_invalid, true, _}} =
               update(registered(), %{base_ref_policy: true})
    end

    test "nil and blank clear the setting" do
      assert {:ok, %{base_ref_policy: nil}} = Settings.normalize(%{base_ref_policy: nil})
      assert {:ok, %{base_ref_policy: nil}} = Settings.normalize(%{"base_ref_policy" => "  "})
    end
  end
```


Shows red before the fix:

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/aggregates/project_settings_test.exs'
```

(expect `{:error, {:unknown_setting, "base_ref_policy"}}` instead of the typed tuple).

## 4. Edits

All paths are repository-relative.

**1. `packages/foreman_server/lib/foreman_server/aggregates/project/settings.ex` — module attributes.**
After line 45 (`@notification_preferences ~w(every_turn blocked_only off)`), insert:

```elixir

  # Which ref a run's worktree is cut from: the fetched remote branch or the
  # registered checkout's HEAD. Unset means `origin`.
  @base_ref_policies ~w(origin checkout)
```

In the `@keys` list (lines 47-51), change the last line from

```elixir
           notification_preference required_checks)a
```

to

```elixir
           notification_preference required_checks base_ref_policy)a
```

**2. same file — `@type key`.** After `| :required_checks` (line 76) add `          | :base_ref_policy`.

**3. same file — `@type error`.** After line 102 (`| {:notification_preference_invalid, term(), [String.t()]}`) add:

```elixir
          | {:base_ref_policy_invalid, term(), [String.t()]}
```

**4. same file — public accessor.** After line 131 (`def notification_preferences, do: @notification_preferences`) add:

```elixir

  @doc "Values accepted for the `base_ref_policy` setting."
  @spec base_ref_policies() :: [String.t()]
  def base_ref_policies, do: @base_ref_policies
```

**5. same file — validator.** After line 343 (the catch-all `defp validate(:notification_preference, value), do: ...`) and before line 345 (`defp validate(:required_checks, nil)`) insert:

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

**6. `packages/foreman_server/lib/foreman_server/events/project_updated.ex` — typed field.**
In `@type t` after line 33 (`required_checks: [map()] | nil,`) add `          base_ref_policy: String.t() | nil,`. In `defstruct` after line 57 (`:required_checks,`) add `    :base_ref_policy,`. (`project_settings_test.exs:431-434` pins that every `Settings.keys/0` entry is a struct field.)

**7. `packages/foreman_server/lib/foreman_server/project_settings.ex` — read-model type.**
In `@type t`, change line 27 from `          required_checks: [map()] | nil` to:

```elixir
          required_checks: [map()] | nil,
          base_ref_policy: String.t() | nil
```

(`defstruct @keys` already picks the field up; only the typespec is hand-written.)

**8. `packages/foreman_server/lib/foreman_server_web/project_settings_live.ex` — form whitelist and control.**
Line 57-58: append the key to `@text_fields` (it is a select over string values, like `notification_preference`):

```elixir
  @text_fields ~w(goal instructions thread_model thread_effort coordinator_provider coordinator_model
                  coordinator_effort notification_preference base_ref_policy)a
```

In `render/1`'s `assign/2` call, after line 833 (`notification_preferences: Settings.notification_preferences(),`) add:

```elixir
        base_ref_policies: Settings.base_ref_policies(),
```

After the `notification_preference` field (line 880) add:

```heex
        <.field name="base_ref_policy" label="Run base ref" errors={@errors} form={@form} options={@base_ref_policies} help="Which ref a run's worktree is cut from. (default) is origin: the fetched remote branch. checkout bases the run on the registered checkout's HEAD." />
```

No `error_field/1` change: the tag `:base_ref_policy_invalid` is matched by the prefix rule at `project_settings_live.ex:596-604`.

**9. `packages/foreman_server/test/foreman_server/mcp/tools_project_settings_test.exs:243` — MCP parity.**
The setting is operator-only (it decides what code a run is cut from, like `repo_allowlist`); do not add it to the MCP schema or `@settings_update_keys` in `lib/foreman_server/mcp/tools.ex`. Change line 243 to:

```elixir
    operator_only = ~w(repo_allowlist max_repos_per_run required_checks base_ref_policy)
```

**10. LiveView test** — add to `packages/foreman_server/test/foreman_server_web/live/project_settings_live_test.exs`, after the test ending line 352, two tests copied from the `notification_preference` pair at lines 324-352 with the key and values swapped:

```elixir
  test "the run base ref policy saves and (default) clears it", %{id: id} do
    {view, _} = mount_view(id)

    html =
      view
      |> form("#settings-form", settings: %{base_ref_policy: "checkout"})
      |> render_submit()

    assert html =~ "Settings saved."
    assert settings(id).base_ref_policy == "checkout"

    view |> form("#settings-form", settings: %{base_ref_policy: ""}) |> render_submit()
    assert settings(id).base_ref_policy == nil
  end

  test "an invalid run base ref policy is refused at its field", %{id: id} do
    {view, _} = mount_view(id)
    html = render_submit(view, "save", %{"settings" => %{"base_ref_policy" => "upstream"}})

    assert html =~ ~s(id="base_ref_policy-error")
    assert html =~ "base_ref_policy_invalid"
    assert settings(id).base_ref_policy == nil
  end
```

**11. Docs (documentation gate — added identifier `base_ref_policy`).**
- `docs/user-guide.md`: in the project settings table, after the `notification_preference` row (line 731), add this row verbatim:

```
| `base_ref_policy` | `origin` (default when unset) or `checkout` | Operator-only: which ref a run's worktree is cut from. `origin` means the fetched remote base branch, `checkout` the registered checkout's HEAD. Not settable over MCP; clearable with `--clear` |
```

- `CLAUDE.md` line 1240: add `` `base_ref_policy` `` to the `Settings.keys/0` enumeration and to the parenthetical naming the operator-only keys (`repo_allowlist`, `max_repos_per_run`, `required_checks`).
- `README.md`, `docs/cli-reference.md`: no edit. No CLI flag and no MCP argument is added, so the flag tables and the MCP argument lists stay accurate (`docs/cli-reference.md:24`, `:320-331`, `:1656` list only flags/MCP args).

## 5. Verification

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors \
  test/foreman_server/aggregates/project_settings_test.exs \
  test/foreman_server/project_settings_read_model_test.exs \
  test/foreman_server/mcp/tools_project_settings_test.exs \
  test/foreman_server_web/live/project_settings_live_test.exs'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
```

Success = all four files green with zero warnings and a clean format check. Then the full suite:
`devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'`.

## 6. Out of scope

- The origin-fetch behaviour itself: `workflow/run_executor.ex`, `vcs_adapter.ex`, `vcs_adapter/default.ex`, `exec/git.ex`, `exec/worktree.ex`. No reader of `base_ref_policy` is added by this bead.
- `events/run_base_branch_recorded.ex`, `aggregates/run.ex`, `projects/recommendations.ex` (separate beads).
- MCP: no new property in `lib/foreman_server/mcp/tools.ex` and no change to `@settings_update_keys` (line 2506) or `refuse_clearing_operator_only/1`.
- Go CLI: no `--base-ref-policy` flag, no change to `projectSettingNames` (`packages/foreman_cli/cmd/foreman/project.go:481-490`) or the `usage` const — deliberately deferred until the behaviour bead lands, so `docs/cli-reference.md` and `usage_drift_test.go` need no edit.
- Do not refactor the `notification_preference` code the new validator is modelled on.
