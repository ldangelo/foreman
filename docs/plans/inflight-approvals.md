# In-flight tool approvals (bead foreman-exofh)

Status: GO for Claude. pi stays on the phase-pause path (it has no per-call permission mechanism: spike S2, `docs/spikes/S2.md`).

## Today (E8)
A Claude phase run with `approval_mode: prompt` is denied every non-allowed tool (headless one-shot CLI has no prompt channel, S2 §E8-S3). The run ends with `permission_denials`, `PhasePause` records `tool.request` events and pauses the run (`awaiting_approval`); an operator `tool.approve` queues a steer with an `approval_mode_override` and the phase **re-runs**. There is no UI control, and the agent loses its in-flight context.

## Mechanism (proven against the real CLI, claude 2.1.308)
`claude --print --permission-mode default --mcp-config <cfg> --permission-prompt-tool mcp__<server>__<tool>` routes every tool call that would prompt to an MCP tool. The tool receives `{tool_name, input, tool_use_id}`, may block for as long as it likes, and answers with a text content block holding JSON: `{"behavior":"allow","updatedInput":<input>}` or `{"behavior":"deny","message":"…"}`.

Throwaway probe (`foreman-wt/inflight-probe`, not committed), prompt "use the Write tool to create hello.txt":
- stdio MCP server, allow after a 4 s delay: the `tools/call` arrived at 01:05:55, the reply was sent at 01:05:59, `hello.txt` was created and the SAME session finished ("Done."); one `claude` process, no phase re-run.
- same, deny: tool_result `Denied by operator probe` (`is_error: true`), the file was not created, the model quoted the message back.
- HTTP MCP (`{"type":"http","url":…,"headers":{"Authorization":"Bearer …"}}`) with plain `application/json` responses works the same; claude sends `initialize`, `notifications/initialized`, `tools/list`, `tools/call`, plus a `server/discover` request that must be answered (an unanswered one costs 5 s) and a `GET` that may be refused with 405.
- On deny the final `result` record STILL lists the tool in `permission_denials` (observed), so the phase-pause path must not re-request a tool whose denial was decided in flight.

## Design
1. **Permission endpoint** `POST /agent-permission/:run_id` (`ForemanServerWeb.AgentPermissionController`), a minimal JSON-RPC-over-HTTP MCP server exposing ONE tool, `approve`. It is a separate route from the operator MCP (`/mcp`): auth is a per-run bearer token (HMAC of the run id with the endpoint secret), so the agent never holds the operator token and the token only opens that run's prompt tool. A run that is not active gets an in-band deny (never an allow).
1b. **Keep-alive**: claude abandons a silent HTTP reply after ~60 s (probed: `The operation timed out`). `tools/call` therefore replies as `text/event-stream` and emits `notifications/progress` for the request's `progressToken` every 15 s (`:inflight_progress_ms`) until the decision; a probe held one call for 100 s this way. A closed connection releases the blocked call (`client_gone`, request expired).
2. **Request**: `tools/call approve` records a `tool.request` through the existing `Approvals.Requester` (same `ToolCall` aggregate/events/projection; `delivery: "inflight"`, id derived from `tool_use_id`, so a redelivered call is idempotent), then blocks in `Approvals.Inflight.await/3`.
3. **Decision**: the operator's existing `tool.approve` / `tool.deny` (CLI `foreman approvals approve|deny`, `POST /api/commands`, and NEW approve/deny buttons in the workspace thread card) emits `ToolCallApproved/Denied`; `Approvals.Deliverer` (existing, reacts to those events) delivers `inflight` decisions through `Inflight.respond/3`, which wakes the blocked call; the controller answers allow/deny and the call finishes (`tool.finish`, existing).
4. **Never self-approved**: resolution stays `tool.approve|deny`, operator-only (not in `Approvals.Dispatch`, not an MCP tool). The prompt tool can only create a request and wait; calling it by hand grants nothing.
5. **Timeout → deny**: after `Approvals.Config.approval_timeout_ms()` the controller dispatches `tool.deny` (`decided_by: "system"`, reason `timeout`), receives it through the same delivery path, and answers deny. Deny-by-default also for: unknown/inactive run, malformed input, any internal error.
6. **Run ends / stop / pause while blocked**: `Inflight` subscribes to projection events; a terminal run event (completed, failed, cancelled) wakes its waiters with deny and `tool.expire`s still-open requests, so no pending request outlives its agent.
7. **Server restart**: the agent process dies with the server; requests left `requested` are expired by the existing `Sweeper`; a late operator approve of such a request finishes as `delivery_failed` (no waiter), visibly, never silently.
8. **Enable**: only when the phase's effective `approval_mode` is `prompt`, the provider is `claude` and `config :foreman_server, :approvals, inflight: true` (default true; false in test). Foreman passes `mcp_config` plus `cli_path: priv/bin/foreman-claude-permission`, a one-line wrapper that execs claude with `--permission-prompt-tool mcp__foreman_permission__approve` ahead of the adapter's own arguments. (The server consumes `Jido.Harness` from the Sunstone-Partners git fork pinned in `mix.exs`, not the vendored `packages/jido_harness`, and the adapter has no option for that flag; `cli_path` is its supported seam. A live run failed with `unknown provider option` when an option was added to the vendored copy only.) Everything else (pi, other providers, `approval_mode` unset) keeps the E8 phase-pause path.
9. **Phase pause interplay**: tools whose in-flight request was already decided/expired in this run are dropped from the post-hoc denial list, so a denied call never raises a second request; a phase that ends with only in-flight-denied tools fails through the ordinary failure path (the operator said no).

## Out of scope
pi per-call approvals; resuming after a server restart; approving on the user's own machine.
