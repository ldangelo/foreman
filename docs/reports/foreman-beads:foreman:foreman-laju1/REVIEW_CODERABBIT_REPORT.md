Phase complete.

## CodeRabbit review — `beads:foreman:foreman-laju1` (run-ea2a2369059c083d826f0a32d81edd98)

**Review engine:** `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` (`FOREMAN_BASE_BRANCH=main`), CLI 0.9.6, exit 0 every round. 3 rounds (max).

**Findings: 5 — 5 fixed, 0 declined, 0 open.**

| # | Severity | File | Fix |
|---|---|---|---|
| 1 | minor | `docs/reports/.../FIX_REPORT.md` | File held a chat reply ("I'll start by reading the plan.") → rewritten as a real report |
| 2 | major | `docs/reports/.../PLAN.md` | Branch had a 12-line chat summary instead of the 273-line plan → restored verbatim from `git show c5e41c70:...` |
| 3 | minor | `docs/reports/.../PLAN.md:255` | Gate command now `unset DATABASE_URL` |
| 4 | minor | `docs/reports/.../FIX_REPORT.md:5` | Report body rewritten to match the actual implementation |
| 5 | major | `test/.../dispatcher_slot_promoted_test.exs:356` | Leaked global `:meck.new(ForemanServer.CommandGateway, [:no_link])` → `[:passthrough, :no_link]` + `on_exit` unload |

Finding 5 mattered: the `:no_link` mock replaced `CommandGateway` process-wide and broke **168 unrelated tests** (`command_gateway_tool_call_test.exs:58` → `UndefinedFunctionError ... CommandGateway.dispatch_operator/1 is undefined or private`). That suite run was killed as invalid.

**Implementation (bead):**
- `packages/foreman_server/lib/foreman_server/workflow/dispatcher.ex:1460` — `start_promoted_run/2` now refuses a run whose task is `closed`/`failed`/`merged` (`terminate_slot(run_id, "run_cancelled")`). Deny-list, because legacy task projections carry no `:status` key.
- `packages/foreman_server/lib/foreman_server/mcp/tools.ex:1886` + new `pending_run_status_dto/1` (`:3620`) — `foreman_run_status` falls back to `ProjectionStore.pending_run/1` and answers `queued` (`deferred` while deferred), `terminal: false`, instead of `NOT_FOUND`.
- (a) was already covered by `command_gateway_cancel_queued_run_test.exs:42` → no duplicate added; (b) and (c) got new tests in `dispatcher_slot_promoted_test.exs` and `mcp/tools_test.exs`.

**Verification:** red first — exit 2, `Result: 37/39 passed`, the 2 new tests failed for the right reason; green — 3-file run exit 0, `Result: 44 passed`. Full suite `MIX_ENV=test mix test --warnings-as-errors` → **exit 0, `Result: 9172 passed (8 properties, 9164 tests), 11 excluded`** (`DATABASE_URL=...@localhost:55432/foreman_test_laju1`; the advisory lock in `mix.exs:203` is per-database, so a cloned DB was required). `mix format --check-formatted` exit 0.

An earlier full-suite run exited 2 with 3 failures, all environmental: `config_test.exs:73,87` assert `url =~ "localhost"` and I had pointed `DATABASE_URL` at `127.0.0.1`; `ProjectMemory.StoreTest` hit a 60 s file-I/O timeout that did not reproduce in isolation (both files alone: `Result: 21 passed`, exit 0). Both are documented in the report.

**Artifacts:** `docs/reports/foreman-beads:foreman:foreman-laju1/REVIEW_CODERABBIT_REPORT.md` (new; findings + risk blocks JSON-validated, risk `MEDIUM`) and `FIX_REPORT.md`/`PLAN.md`; doc wording updated in `CLAUDE.md`, `docs/cli-reference.md`, `docs/user-guide.md`. Nothing committed — 9 modified files + 1 new report left for Foreman to commit.

**Caveats:** `ask_advisor` could not be consulted — Anthropic refresh token expired (`invalid_grant`). Operator progress was delivered via MCP after re-initializing an expired session (`msg_iR8CiJdT88vx2k1DSqV33Q` + task comment).