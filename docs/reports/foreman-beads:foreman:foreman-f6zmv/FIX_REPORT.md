# Fix report — `beads:foreman:foreman-f6zmv`

> Written by the repo-rules review phase (phase 4) of run
> `run-ec499920490857a5227e8fbddb92d9d0`. The fix phase's own artifact was
> left with a single line of plan narration ("Now Edit 2 — insert the new
> `describe` block after line 155 in the test file.") and carried no report;
> this file replaces it and describes the branch as it actually stands.

## What was wrong

`ForemanServer.Approvals.Sweeper.init/1` carried the timeout policy lazily:

```elixir
policy_opts: Keyword.take(opts, [:on_timeout, :gateway])
```

`ForemanServer.Approvals.TimeoutPolicy.apply/3` therefore resolved `:on_timeout`
per subject through `Config.on_timeout/0`, which raises `ArgumentError` for any
value other than `:surface`/`:deny`. In `do_sweep/1` the tool-call expiry runs
before the question expiry, so one invalid configured `on_timeout` aborted
every sweep *before a single overdue question expired* — and it did so again on
every restart.

## What changed

- `packages/foreman_server/lib/foreman_server/approvals/sweeper.ex`
  - `init/1` resolves and validates the policy once, at start:
    `policy_opts: opts |> Keyword.take([:gateway]) |> Keyword.put(:on_timeout, validated_on_timeout(opts))`.
  - New private `validated_on_timeout/1` accepts `:surface`/`:deny` and raises
    `ArgumentError` ("ForemanServer.Approvals.Sweeper :on_timeout must be
    :surface or :deny, got: …") for anything else. The sweeper now fails at
    start — a loud failure instead of a poisoned sweep.
  - `start_link/1`'s `@doc` records the accepted values and the new failure
    point.
- `packages/foreman_server/test/foreman_server/approvals/sweeper_test.exs`
  - New `describe "on_timeout validation at init"` with three tests: an invalid
    `:on_timeout` option is rejected at init; an invalid configured
    `on_timeout` is rejected at init; a valid policy is resolved once into
    `state.policy_opts`.

## Documentation gate

Externally visible identifiers added, removed or renamed: **none**. No command
or event type, MCP tool, HTTP route, CLI verb, env var, config key, workflow or
prompt name changed. The `:approvals` → `:on_timeout` config key and its
accepted values (`:surface`/`:deny`) are unchanged; only the failure point
moved from mid-sweep to sweeper start.

- `docs/user-guide.md:3427` documents `on_timeout: :surface | :deny` — still
  accurate; no edit needed.
- `CLAUDE.md`, `README.md`, `docs/cli-reference.md` — no mention of
  `on_timeout`; no edit needed.
- `docs/decisions/phase-0-durable-execution-engine.md` and
  `docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md` list limitation
  (xiv) for `foreman-f6zmv`. Both are point-in-time records and are left as
  written, per AGENTS.md.

## Verification

- `MIX_ENV=test mix format --check-formatted lib/foreman_server/approvals/sweeper.ex test/foreman_server/approvals/sweeper_test.exs` → exit 0
- `MIX_ENV=test mix compile --warnings-as-errors` → exit 0
- `MIX_ENV=test mix test --warnings-as-errors test/foreman_server/approvals/sweeper_test.exs test/foreman_server/approvals/config_test.exs` → exit 0, 15 tests passed
