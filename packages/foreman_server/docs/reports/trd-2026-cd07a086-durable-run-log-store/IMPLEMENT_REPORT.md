# Implement Report — Durable Run Log Store

## Summary

Implemented a durable worker stdout/stderr path for `foreman_run_get_logs`:

- Added worker log normalization/redaction/cap policy.
- Extended `WorkerStdout` / `WorkerStderr` events with optional timestamps.
- Projected worker log events in `ProjectionStore` and changed known-empty runs to return empty success.
- Wired `JidoHarnessWorker` to emit captured Jido run output events through `WorkerProtocol`.
- Updated MCP error mapping and user/developer docs.

## Files Changed

- `packages/foreman_server/lib/foreman_server/overwatch/worker_log_policy.ex`
- `packages/foreman_server/lib/foreman_server/overwatch/adapters/jido_harness_worker.ex`
- `packages/foreman_server/lib/foreman_server/projection_store.ex`
- `packages/foreman_server/lib/foreman_server/events/worker_stdout.ex`
- `packages/foreman_server/lib/foreman_server/events/worker_stderr.ex`
- `packages/foreman_server/lib/foreman_server/mcp/tools.ex`
- `packages/foreman_server/test/foreman_server/overwatch/worker_log_policy_test.exs`
- `packages/foreman_server/test/foreman_server/projection_store_test.exs`
- `packages/foreman_server/test/foreman_server/mcp/tools_test.exs`
- `packages/foreman_server/test/support/test_application.ex`
- `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`, `CLAUDE.md`, `AGENTS.md`

## Verification

Passed:

```bash
git diff --check
elixir -e 'Enum.each(System.argv(), fn p -> Code.string_to_quoted!(File.read!(p)); IO.puts("ok #{p}") end)' \
  packages/foreman_server/lib/foreman_server/overwatch/worker_log_policy.ex \
  packages/foreman_server/lib/foreman_server/overwatch/adapters/jido_harness_worker.ex \
  packages/foreman_server/lib/foreman_server/projection_store.ex \
  packages/foreman_server/lib/foreman_server/mcp/tools.ex \
  packages/foreman_server/test/foreman_server/projection_store_test.exs \
  packages/foreman_server/test/foreman_server/overwatch/worker_log_policy_test.exs
elixir -r packages/foreman_server/lib/foreman_server/overwatch/worker_log_policy.ex \
  -e 'ExUnit.start(); Code.require_file("packages/foreman_server/test/foreman_server/overwatch/worker_log_policy_test.exs"); ExUnit.run()'
```

Blocked/incomplete locally:

```bash
cd packages/foreman_server && mix test test/foreman_server/overwatch/worker_log_policy_test.exs test/foreman_server/projection_store_test.exs
```

The run repeatedly timed out while compiling/verifying the dependency `ex_mcp` (`Verifying ExMCP.Authorization.FullOAuthFlow`). `mix deps.get` completed, with pre-existing Hex security advisories for Cowboy/Cowlib/Phoenix LiveView/Postgrex.

## Beads Notes

`br init` succeeded and `bv --robot-plan --format toon` succeeded, but the vendored TRD parser returned zero tasks for `docs/TRD/TRD-2026-cd07a086-durable-run-log-store.md` because the TRD uses table task rows. No per-task bead scaffold was created to avoid false task state.
