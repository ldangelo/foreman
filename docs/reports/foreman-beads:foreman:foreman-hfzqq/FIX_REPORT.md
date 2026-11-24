# Fix report — bead `beads:foreman:foreman-hfzqq`

Launch Foreman pi workers with `PI_SUBAGENT_CHILD=1`.

## 1. Root cause

Foreman resolves the model for every phase itself (phase `models.default` >
project `thread_model` > provider default) and passes it to the pi worker in the
launch environment. A pi extension installed machine-wide in
`~/.pi/agent/settings.json` can still take that model away: `pi-advisor-flow`
calls `setExecutorModel`/`setThinkingLevel` at activation unless the session is
marked as a child. Verified in `~/.pi/agent/npm/node_modules/pi-advisor-flow/dist/index.js`:
`var isMarkedSubagent = () => process.env.PI_SUBAGENT_CHILD === "1"` (`:288`)
gates only that override (`:290`, `:295`, `:4799`, `:4845`, `:4855`, `:4887`).
Foreman launched its pi phase workers without the marker, so a machine-wide
extension silently replaced the model Foreman had resolved.

The bead's premise that the marker also disables the advisor gates
(`advisorCompletionGate`, `advisorPlanGate`, `advisorBlockOnBlocked`) is
incorrect: those are plain config booleans (`:51`, `:53`, `:57`) and are not
keyed on the marker. This run documents the verified behaviour instead.

## 2. Change

- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` — new
  private helper `maybe_put_pi_child_marker/2` (`Map.put(env,
  "PI_SUBAGENT_CHILD", "1")` for `:pi`, no-op otherwise) and one extra step in
  the launch-env pipeline inside `build_agent_launch/10`:
  `|> maybe_put_pi_child_marker(JidoHarness.request_provider(request))`.
  The marker is merged after `foreman_env/4`, so a project environment cannot
  shadow it. The provider used for the marker is read with the same
  `JidoHarness.request_provider(request)` expression that `launch_opts` uses,
  so the marker and the launched provider cannot disagree.
- `packages/foreman_server/test/foreman_server/workflow/run_executor_command_test.exs`
  — the namespace assertion "every delivered env key starts with `FOREMAN_`"
  was unsatisfiable next to the new marker; it now exempts
  `PI_SUBAGENT_CHILD` explicitly.
- `packages/foreman_server/test/foreman_server/workflow/run_executor_pi_subagent_env_test.exs`
  — new test: a pi phase launch carries `PI_SUBAGENT_CHILD=1`, a non-pi phase
  does not.
- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`
  (comment above `maybe_put_pi_child_marker/2`) — states the trade-off
  explicitly: the marker suppresses the extension's model/effort override, not
  the advisor gates.
- Documentation: `docs/user-guide.md` §7.3 (operator-facing explanation),
  `CLAUDE.md`, `README.md`, `docs/cli-reference.md` ("Phase worker
  environment"), `docs/lessons/phase-execution-and-pr-mechanics.md` (verified
  scope limit, extension line references).

## 3. Deviations from the plan

- The plan (`PLAN.md` §4, Edit 1) placed the new pipeline step in
  `prepare_agent_launch/5`. It landed in `build_agent_launch/10`, the function
  that actually merges `foreman_env/4` and the library env; `prepare_agent_launch/5`
  only calls it. The documentation was corrected to name the real injection
  point.
- The plan's Edit 4 text (and the first draft of the `CLAUDE.md` and
  `docs/lessons/` paragraphs) said "every pi worker Foreman launches". The
  implementation marks pi *phase* workers only: the review evaluator
  (`ForemanServer.Review.Evaluator.Agent`) launches pi in a separate path and
  the coordinator harness runs with `no_extensions: true`, so neither is
  affected by a machine-wide extension in the first place. All four gate
  documents now say "phase worker".
- The plan assumed the phase-3 review report would stay machine-readable. The
  phase-3 commit `b8040fbf` ("Foreman run … phase 3") replaced the phase
  agent's compliant 204-line report with a 21-line prose summary that dropped
  both machine-readable blocks. The report was restored from the phase agent's
  own commit `40e8db7a`; no finding was re-authored.
- This report was committed by phase 3 as a 63-byte fragment ("Now Edit 3 …
  and Edit 4 (docs)."), which does not satisfy the six-section contract of
  `priv/defaults/workflows/prompts/fix.md`. It is rewritten here with those
  six sections.

## 4. Tests

- `packages/foreman_server/test/foreman_server/workflow/run_executor_pi_subagent_env_test.exs`
  — new (pi phase carries the marker, non-pi phase does not).
- `packages/foreman_server/test/foreman_server/workflow/run_executor_command_test.exs`
  — existing, corrected namespace assertion.
- Regression set (this phase): `run_executor_pi_subagent_env_test.exs`,
  `run_executor_command_test.exs`, `run_executor_project_model_test.exs`,
  `run_executor_project_context_test.exs`, `run_executor_resume_test.exs`,
  `run_executor_fork_test.exs`,
  `test/foreman_server/overwatch/adapters/jido_harness_worker_env_test.exs`,
  `test/foreman_server/library_delivery_test.exs` — 87 tests, 0 failures.

## 5. Local verification

```
devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55433/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/run_executor_pi_subagent_env_test.exs test/foreman_server/workflow/run_executor_command_test.exs'
# => 25 tests, 0 failures, exit 0

devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55433/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/run_executor_pi_subagent_env_test.exs test/foreman_server/workflow/run_executor_command_test.exs test/foreman_server/workflow/run_executor_project_model_test.exs test/foreman_server/workflow/run_executor_project_context_test.exs test/foreman_server/workflow/run_executor_resume_test.exs test/foreman_server/workflow/run_executor_fork_test.exs test/foreman_server/overwatch/adapters/jido_harness_worker_env_test.exs test/foreman_server/library_delivery_test.exs'
# => 87 tests, 0 failures, exit 0

devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
# => exit 0

devbox run -- bash -c 'cd packages/foreman_cli && go build ./cmd/foreman && go vet ./... && go test ./...'
# => exit 0 (includes usage_drift_test.go, which parses docs/cli-reference.md)
```

The database used here is the `foreman-pg-phase0` container published on port
`55433`; the port in `PLAN.md` §5 (`55432`, container `foreman-postgres`) was
not running in this worktree.

## 6. Follow-ups

- The review evaluator (`ForemanServer.Review.Evaluator.Agent`) starts pi on a
  separate path and is therefore *not* marked. A machine-wide extension can
  still override the reviewer's model. `PLAN.md` §6 puts that path out of
  scope; if the operator wants it covered, it needs its own change.
- The advisor gates are unaffected by the marker, by design. Operators who
  want them off must configure the extension, not Foreman.
- `ask_advisor` could not be consulted in this run: the extension returned
  HTTP 400 `{"error": "invalid_grant", "error_description": "Refresh token
  expired"}`. The operator has to re-authenticate the extension.
