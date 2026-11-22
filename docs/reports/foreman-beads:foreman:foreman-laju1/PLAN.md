Plan written. Advisor unavailable (Anthropic refresh token expired — known env issue).

**Artifact:** `docs/reports/foreman-beads:foreman:foreman-laju1/PLAN.md` (273 lines). Only file touched; no code edits, no commits.

**Verdict in plan:** partly real.
- **(a) already covered** — `test/foreman_server/command_gateway_cancel_queued_run_test.exs:42` asserts waiter removal + task ack + `pending_run == nil`. Ran it: `5 passed`, exit 0. No new test needed.
- **(b) real gap** — `dispatcher.ex:1436 start_promoted_run/2` refuses only `acknowledged_run_id`; a `closed`/`failed` task falls through at :1460 and is admitted.
- **(c) real gap** — `mcp/tools.ex:1881 tool_foreman_run_status/1` → NOT_FOUND whenever run projection nil; HTTP already answers `queued` via `ProjectionStore.pending_run/1`.

**Plan content:** 2 failing-first tests + 2 narrow prod fixes (deny-list clause in `start_promoted_run/2`; `pending_run_status_dto/1` fallback in the MCP tool), exact code blocks and insertion points, doc edits at `docs/cli-reference.md:1599` + `docs/user-guide.md:2200` (CLAUDE.md/README.md not needed, reasons stated), out-of-scope fencing against sibling beads (foreman-lxb0m, re_dispatch_promoted).

**Env gotchas recorded in plan:** worktree had no deps (`mix deps.get` needed, done); ambient `DATABASE_URL`=:55434 breaks `mix test` with `FATAL 28P01` from `mix.exs:203 claim_database!/2` — must `unset DATABASE_URL` so test config uses :55432/`foreman_test`.