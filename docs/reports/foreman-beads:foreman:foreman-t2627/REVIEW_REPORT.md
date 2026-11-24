Phase complete.

**Repo-rules review — `beads:foreman:foreman-t2627`**

**Core finding:** the run's committed diff (`main...HEAD`, merge base `c209f8b4`) held **zero product code** — only the 3 phase artifacts plus the operator's pre-existing `ops/herdr-sidebar/` change (already on `main` as `ddb31e80`/PR #960 → declined, out of scope). The bead was unimplemented, and this last phase would have opened an empty PR. Fixed here from the run's own committed `PLAN.md`.

**Fixed**
- `packages/foreman_server/lib/foreman_server/questions/deliverer.ex` — outcome no longer discarded; bounded retry while the server is up: `@retry_delays_ms [1_000, 5_000, 30_000, 120_000]`, `:retry_delays_ms` start option, `handle_info({:questions_retry, attempt}, state)`, `recover_outcomes/1` (recovery pass now returns its outcomes), `arm_retry/2` + `schedule_retry/1` (`Process.send_after`; one `:error` log `questions: answer delivery still failing after N retries; it is retried again at the next start` when exhausted). Idempotent: deterministic `question-steer:`/`question-resume:` ids, `paused?`/`steer_pending?` gates; bus replies not replayed.
- `test/foreman_server/questions/deliverer_test.exs` — `FlakySteerGateway` double + "transient steer failure is retried without restart" + "the retries are bounded and the last one says so".
- `CLAUDE.md:1164` — deliverers' recovery semantics now document the retry.
- `docs/decisions/phase-0-durable-execution-engine.md:151` — forward pointer to the closure; point-in-time claim left as written.

**Declined** — `docs/TRD/TRD-2026-a804d1c7-phase-0-durable-execution.md:641/:733` (point-in-time spec per AGENTS.md); the two `ops/herdr-sidebar/` files (pre-existing operator commit).

**Verification** (all exit 0): `mix compile --warnings-as-errors` clean · `mix test --warnings-as-errors test/foreman_server/questions/deliverer_test.exs` 33 passed · `.../questions/ .../approvals/` 109 passed · `mix format --check-formatted` clean · diff re-read after fixes → no new violation. Report JSON blocks validated by parser check (5 findings: 3 fixed / 2 declined; risk MEDIUM).

No progress notes were sent — `foreman_inbox_send` / `foreman_task_add_comment` are unavailable in this phase. Fixes left uncommitted for Foreman.