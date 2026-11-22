Phase 4 (repo-rules review) complete.

**Review engine** — repo-rules reviewer, diff range `796c888c...HEAD` (`$FOREMAN_BASE_BRANCH`=796c888c, main). Branch diff = 3 added Markdown files, **zero code**.

**Fixed** (1)
- `docs/reports/foreman-beads:foreman:foreman-tepov/REVIEW_CODERABBIT_REPORT.md` — HEAD's blob was a 14-line model recap (leaked `<think>` tag) with **no** findings/judgement block, so `CLAUDE.md` reads the branch's own review record as absent (not clean) and the two `major` findings were invisible to the gate. Restored the pre-truncation body from `git show 0ee73fcb^:<path>` — diff empty (byte-identical).

**Carried forward** (4, from `REVIEW_CODERABBIT_REPORT.md`)
- 2× `minor` FIX_REPORT.md — fixed already by the prior phase (fabricated "6 files/+352/-8/9 tests in run_cancel_test.exs" claims; `git cat-file -e HEAD:...run_cancel_test.exs` → exit 128, never existed; §1–§6 byte-identical to `96f162d0`).
- `major` command_gateway.ex:221 (promotion wins the race) — **declined, stale**: current code has `release_if_promoted/4` (command_gateway.ex:244) + `start_promoted_run/2` guard (dispatcher.ex:1452-1457) refusing a run whose task carries `acknowledged_run_id`.
- `major` command_gateway.ex:257 (failed `task.run_terminated` after committed `run_slots.remove_waiter` ⇒ task stuck `in_progress`, retry can't re-ack) — **declined but still live**: pre-existing on main (PR #904/#918), PLAN.md §6 forbids editing that file for this bead, needs its own bead + failure-injection test.

**Open** (1, minor) — PLAN.md:116 / FIX_REPORT.md advise `unset DATABASE_URL`; the durable rule is per-run DB isolation (per-database advisory lock, `mix.exs:141`→`claim_database!/2`). Not fixed (rewriting another phase's signed records is out of scope).

**Verification** — dedicated DB `foreman_test_tepov` @127.0.0.1:55432 (shared `foreman_test` held by run foreman-laju1; nothing killed, no DB dropped):
- `mix test test/foreman_server/command_gateway_cancel_queued_run_test.exs --warnings-as-errors` → 5 passed, exit 0
- 4-file set (+ `projection_store_run_slots_test.exs`, `projection_store_queue_status_test.exs`, `aggregates/run_slots_release_test.exs`) → 56 passed, exit 0, no warnings
- restore diff empty; both JSON blocks re-parsed (6 findings, MEDIUM risk); no formatter applies (.md only, no code)

Operator note sent (`msg_luC2zTZlxBqOd80TcoERIQ`) + task Work Log comment added. Kata issue `ttty` created/closed. Fixes left uncommitted (` M REVIEW_CODERABBIT_REPORT.md`, `?? REVIEW_REPORT.md`) for Foreman to commit.

Doc gate: no externally visible identifier added/removed/renamed; `docs/cli-reference.md` already documents queued-run `run cancel` — no doc edits needed.