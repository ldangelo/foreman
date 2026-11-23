# PLAN — foreman-f6zmv: validate `on_timeout` in `Approvals.Sweeper.init/1`

## 1. Verdict

Real bug, present on this tree (HEAD `018da6b1`).

Evidence:

- `packages/foreman_server/lib/foreman_server/approvals/sweeper.ex:47-58` — `init/1` only
  does `policy_opts: Keyword.take(opts, [:on_timeout, :gateway])`. When `:on_timeout` is not
  in `opts` the key is simply absent; nothing is validated at init.
- `packages/foreman_server/lib/foreman_server/approvals/timeout_policy.ex:37` —
  `apply(:tool_call, ...)` does `Keyword.get_lazy(opts, :on_timeout, &Config.on_timeout/0)`,
  i.e. the config is read lazily, per tool call, inside the sweep.
- `packages/foreman_server/lib/foreman_server/approvals/config.ex:44-53` —
  `Config.on_timeout/0` raises `ArgumentError` for any value other than `:surface`/`:deny`
  (pinned by `test/foreman_server/approvals/config_test.exs:15`).
- `packages/foreman_server/lib/foreman_server/approvals/sweeper.ex:84-97` — `do_sweep/1`
  runs `Enum.each(overdue_calls, ...)` **before** `Enum.each(overdue_questions, ...)`, and
  `apply_policy/3` only rescues nothing: the raise escapes `do_sweep/1`.

Consequence: with a misspelled `config :foreman_server, :approvals, on_timeout:` value and at
least one overdue tool call, the boot sweep (`handle_continue(:recover)`,
`sweeper.ex:61-64`) raises before any question is expired, the sweeper crashes, the
supervisor restarts it, and it raises again at the same point — no question ever expires,
and the failure is reported as a repeating sweeper crash rather than as a config error.

## 2. Root cause

`ForemanServer.Approvals.Sweeper.init/1` carries `:on_timeout` lazily into `policy_opts`
instead of resolving and validating it once at start. The invalid-config failure therefore
surfaces deep inside `TimeoutPolicy.apply/3` during a sweep (after partial work), not at
process start.

## 3. Failing check first

New test in the existing file
`packages/foreman_server/test/foreman_server/approvals/sweeper_test.exs`, inserted
immediately after the test `"a restarted sweeper over the same log expires nothing twice"`
(ends at line 155). It calls the `init/1` callback directly — pure, no DB, no process:

```elixir
  describe "on_timeout validation at init" do
    setup do
      previous = Application.get_env(:foreman_server, :approvals, [])
      on_exit(fn -> Application.put_env(:foreman_server, :approvals, previous) end)
      %{previous: previous}
    end

    test "an invalid :on_timeout option is rejected at init, not mid-sweep" do
      assert_raise ArgumentError, ~r/on_timeout/, fn ->
        Sweeper.init(interval_ms: :manual, on_timeout: :dney)
      end
    end

    test "an invalid configured on_timeout is rejected at init", %{previous: previous} do
      Application.put_env(
        :foreman_server,
        :approvals,
        Keyword.put(previous, :on_timeout, "deny")
      )

      assert_raise ArgumentError, ~r/on_timeout/, fn -> Sweeper.init(interval_ms: :manual) end
    end

    test "a valid policy is resolved once into policy_opts", %{previous: previous} do
      Application.put_env(:foreman_server, :approvals, Keyword.put(previous, :on_timeout, :deny))
      assert {:ok, state, {:continue, :recover}} = Sweeper.init(interval_ms: :manual)
      assert Keyword.fetch!(state.policy_opts, :on_timeout) == :deny

      assert {:ok, explicit, {:continue, :recover}} =
               Sweeper.init(interval_ms: :manual, on_timeout: :surface)

      assert Keyword.fetch!(explicit.policy_opts, :on_timeout) == :surface
    end
  end
```

Before the fix the first two tests fail (no raise: `init/1` returns `{:ok, state, ...}`) and
the third fails on `Keyword.fetch!(state.policy_opts, :on_timeout)` raising `KeyError`
(the key is absent when not passed in opts).

Command that shows the failure (see §5 for the env prerequisites):

```
devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test test/foreman_server/approvals/sweeper_test.exs'
```

## 4. Edits

### Edit 1 — `packages/foreman_server/lib/foreman_server/approvals/sweeper.ex`

**4a.** In the `start_link/1` doc (lines 27-31), change the option line

```elixir
  `:on_timeout`, `:gateway`.
```

to

```elixir
  `:on_timeout` (`:surface` or `:deny`; defaults to `Config.on_timeout/0` and is validated
  here, so a bad value fails the sweeper at start instead of mid-sweep), `:gateway`.
```

**4b.** In `init/1` (lines 47-58), replace the `policy_opts:` line

```elixir
      policy_opts: Keyword.take(opts, [:on_timeout, :gateway])
```

with

```elixir
      policy_opts:
        opts
        |> Keyword.take([:gateway])
        |> Keyword.put(:on_timeout, validated_on_timeout(opts))
```

**4c.** Immediately after the `end` of `init/1` (currently line 58), insert:

```elixir
  # Resolve and validate the policy once, at start: `TimeoutPolicy.apply/3` reads
  # `:on_timeout` lazily per subject, so an invalid value would otherwise raise inside a
  # sweep after some requests were already handled and before any question is expired.
  defp validated_on_timeout(opts) do
    case Keyword.get_lazy(opts, :on_timeout, &Config.on_timeout/0) do
      policy when policy in [:surface, :deny] ->
        policy

      other ->
        raise ArgumentError,
              "ForemanServer.Approvals.Sweeper :on_timeout must be :surface or :deny, got: #{inspect(other)}"
    end
  end
```

Notes for the implementer:

- `Config.on_timeout/0` already raises for an invalid *config* value; `validated_on_timeout/1`
  additionally rejects an invalid value passed directly as an option, and moves both failures
  to `init/1`.
- After this change `policy_opts` always carries a resolved `:on_timeout` atom, so
  `TimeoutPolicy.apply/3` never calls `Config.on_timeout/0` from the sweeper path.
- A misconfigured `on_timeout` now makes the sweeper fail at start (loud failure at boot)
  instead of silently never expiring questions. That is the intended behaviour; do not add
  a rescue, a fallback to `:surface`, or a log-and-continue path.

### Edit 2 — `packages/foreman_server/test/foreman_server/approvals/sweeper_test.exs`

Insert the `describe "on_timeout validation at init"` block from §3 after line 155 (after the
`"a restarted sweeper over the same log expires nothing twice"` test, before
`test "an open question past its own timeout expires; ..."`). No other test changes.

## 5. Verification

Fresh run worktrees need deps and a reachable DB first (the exported
`DATABASE_URL` on port 55434 rejects `postgres/postgres`):

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix deps.get'
devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/approvals/sweeper_test.exs test/foreman_server/approvals/config_test.exs'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted lib/foreman_server/approvals/sweeper.ex test/foreman_server/approvals/sweeper_test.exs'
```

Success = both test files green with zero failures and zero warnings, and
`mix format --check-formatted` exits 0. These runs take well over 60 s; use a large
command timeout.

Documentation gate: no externally visible identifier is added, removed or renamed
(`validated_on_timeout/1` is private; the `:on_timeout` config key and its `:surface`/`:deny`
values are unchanged). `docs/user-guide.md:3427` is the only doc mention of `on_timeout` and
stays accurate. No edits needed in `CLAUDE.md`, `README.md`, `docs/user-guide.md` or
`docs/cli-reference.md` — state this explicitly in the fix report.

## 6. Out of scope

- Do not change `ForemanServer.Approvals.Config` (`config.ex`) or its test.
- Do not change `ForemanServer.Approvals.TimeoutPolicy` — leave its
  `Keyword.get_lazy(opts, :on_timeout, &Config.on_timeout/0)` default in place for its other
  caller, `lib/foreman_server/agents/operator_timeout.ex:37`.
- Do not reorder `do_sweep/1` (questions before tool calls), do not add retries, rescues or a
  per-subject `try` around `apply_policy/3`, and do not change the sweeper's timer, interval
  or boot-sweep behaviour.
- Do not touch `lib/foreman_server/application.ex`, config files, or any other approvals
  module. Do not add new config keys.
