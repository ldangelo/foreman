# Closed-bead cross-check ledger (E16-S9-T2, `foreman-roeu9`)

Closed Claude Projects programme beads (labels `claude-projects-parity`, `spike`, `parity-gap`; `br list --status=closed`)
whose stated deliverable is absent or different on the code base, and that have no bead of their own. Capability-level gaps
have their own beads in [`parity-audit.md`](parity-audit.md); this file holds the remainder so none is lost.

Every "Observed" cell below was checked by grep or read against branch `foreman/parity-gaps` at `16cb2b3c`
(paths relative to the repository root; `S/` is `packages/foreman_server/lib/foreman_server/`). No bead was edited.
"Disposition" is a recommendation for the maintainer; it changes nothing by itself.

## Closed beads whose deliverable differs from the code

| Closed bead | Stated deliverable | Observed | Disposition |
|---|---|---|---|
| `foreman-nb8w2.2.3` (E16-S1-T3) | "entries for project and thread verbs" in the agent command inventory | `packages/foreman_cli/cmd/foreman/agent_commands.go` `buildAgentCommandInventory` (:266) holds 6 entries (`foreman-run-submit`, `-run-list`, `-run-get`, `-project-memory-list`, `-project-memory-read`, `-project-chat`, lines 268-273); none for thread verbs or other project verbs | decide: the inventory is agent-facing only (amend the bead) or add entries |
| `foreman-nb8w2.8.5` (E16-S7-T5) | a mix task that renders the MCP tool table from `Tools.list_tools/0` | `packages/foreman_server/lib/mix/tasks/` holds only `foreman/` (the `foreman.mcp.stdio` task); no renderer. `test/foreman_server/mcp/tool_inventory_test.exs` (doc-coverage) is the substitute | amend the bead to name the test as the deliverable |
| `foreman-nb8w2.10.5` (E16-S9-T5) | README, `CLAUDE.md` and `docs/cli-reference.md` link to the parity audit | README.md:38 and `CLAUDE.md` (section 26 and the acceptance bullet, lines 830 and 887) link it; `docs/cli-reference.md` has no link | none needed (cli-reference carries CLI facts only); amend the bead |
| `foreman-uym4.6` (E1-S6) | command id hashes payload plus idempotency key | `packages/foreman_cli/cmd/foreman/project.go:764-766` (`projectUpdateCommandID`): with `--idempotency-key` the id hashes only `"project.update." + key`; without a key it hashes the full payload | decide: a retry with the same key and a different payload is meant to be the same command (amend the bead) or hash both |
| `foreman-slyt.1`, `.2` (spikes S1, S2) | measured provider behaviour | `docs/spikes/S1.md` records claude as "not measurable, recorded as failing" (:54); `docs/spikes/S2.md` carries 9 `UNVERIFIED` cells. Claude coordinator and steering were exercised later (`parity-gaps-live-run.md`, `live-steering-live-run.md`) but the spike tables were not updated | update the spike tables from the live runs, or amend the beads |
| `foreman-slyt.4` (spike S4) | webhook latency, force-push, check re-run, conflict and thread capture observed | `docs/spikes/S4.md` still marks them `[UNVERIFIED]` (9 occurrences, e.g. :103 "not measured"); later observed on real GitHub in `github-live-run.md` | tracked by `foreman-i97tz` |
| `foreman-ipiw4.1` (E6-SP1) | scratch run of steering | `docs/spikes/E6-SP1.md` "Limits" (:33): code-read trace only; the run_steering test is the executable evidence. `S/threads/thread.ex:13-15` still says "Live mid-turn steering is not built" although steering is live by default | fix the moduledoc; amend the bead |
| `foreman-h3u75.8`, `.9` (E12-S8, S9) | jobsite multi-repo; per-repo task-provider binding, BeadsWatcher stamping, BeadSink targeting | dropped by the S3 decision (`docs/spikes/S3.md:18-19`); `S/jobsite/spec.ex:48,136-140` refuses `repositories`; `S/aggregates/project.ex:830-833` refuses a per-repo provider with `:repo_task_provider_unsupported` | documented decision, not a defect: amend the beads |
| `foreman-d9aps.4` (E3-S4) | door-level test that a memory topic written between phase 1 and phase 2 of one run reaches only phase 2's system prompt | `test/foreman_server/workflow/run_executor_project_context_test.exs` has 8 tests (instructions reach `system_prompt`, empty project, unregistered project, covered command phases, no-`system_prompt` provider, append, template assigns); none writes memory between phases. `project_context_test.exs` covers the builder only | add the test (small, `foreman-q9zzo` territory) |
| `foreman-he09d.3` (E8-S3) | ACP `live` approvals (opencode/kimi) | `S/approvals/live.ex:30` `register/5` has no caller in `lib/` (only `Live` as a supervised child, `S/application.ex:304`, and its docs in `S/approvals/deliverer.ex:11`); `test/foreman_server/approvals/deliverer_test.exs:244,255` is the only caller | documented limitation (`docs/user-guide.md`, approvals section); amend the bead |

## Stale statements still present

| Where | What it says | What is true |
|---|---|---|
| `docs/plans/inflight-approvals.md:26` (design item 8) | "The server consumes `Jido.Harness` from the Sunstone-Partners git fork pinned in `mix.exs`, not the vendored `packages/jido_harness`" | `packages/foreman_server/mix.exs:99` uses `{:jido_harness, path: "../jido_harness", override: true}` |
| `S/threads/thread.ex:13-15` | "Live mid-turn steering is not built, so every thread reports `pause_resume`" | `packages/foreman_server/config/config.exs:274` sets `:live_steering, enabled: true`; `pause_resume` is the fallback the HTTP reply reports |
| `S/mcp/tools.ex:313-315` (`foreman_thread_steer`) | "The work is paused and resumed with the message in its next prompt" | live in-session steering is the default; pause/resume is the fallback |
| `S/overview.ex:9-10` | "`Overview.Signals` (E8 counts, zero until E8 lands)" | E8 is on the branch (`Overview.Signals` is fed by approvals and questions) |

## Resolved elsewhere

The audit PR already fixed the stale statements it found: `CLAUDE.md` section 26 ("Multi-repo (E12) is not on main"), the
UNVERIFIED-live list and the `docs/cli-reference.md` steering paragraph (see "Corrections" in `parity-audit.md`).
