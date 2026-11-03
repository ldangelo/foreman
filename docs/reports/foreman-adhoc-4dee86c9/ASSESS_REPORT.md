# ASSESS — Cost of re-reading a thread transcript on every worker output event

Task: `adhoc-4dee86c9` · Run: `run-f43d81536b78f53f51178f6ea6a6f64b` · Project: `foreman`
Mode: **READ-ONLY** static analysis. No source modified; only this artifact written.

All call counts below are **exact from code** (read line-by-line). All latency / byte
figures are **estimated from code structure** — nothing was benchmarked at runtime. Each
claim cites `file:line`.

---

## Headline: the premise does not match the current code

The task describes a hot path — `ProjectWorkspaceLive.load_log/1` →
`Threads.Transcript.full/2` → `ProjectionStore.run_logs/1, run_events/1,
phases_for_run/1`, re-run once per 250 ms while a run emits `WorkerStdout`/`WorkerStderr`
via `Workspace.Refresh.note_output/3`. **None of those four functions exist** in this
checkout:

- `load_log/1` — absent from `project_workspace_live.ex` (no `def load_log`); `git log -S load_log` returns **no commit ever**.
- `note_output/3` — absent from `refresh.ex`; `git log -S note_output` returns **no commit ever**. The real entry point is `Workspace.Refresh.note_event/3` (`lib/foreman_server_web/workspace/refresh.ex:55`).
- `Threads.Transcript.full/2` — does not exist. The module exposes `page/2` only (`lib/foreman_server/threads/transcript.ex:409`), a cursor-paginated read capped at `@max_limit 1000` (`transcript.ex:66`).

More decisive: **worker output events never trigger a workspace refresh.**
`Workspace.Refresh` ignores every event whose type starts with `"Worker"`:

- `@ignored_prefixes ["Worker"]` (`refresh.ex:24`), checked in `relevant?/2`: `not Enum.any?(@ignored_prefixes, &String.starts_with?(type, &1))` (`refresh.ex:88`).
- Event types are literally `"WorkerStdout"` / `"WorkerStderr"` (`projection_store.ex:3094,3098`), so both match the prefix and are dropped.
- Module doc, verbatim: *"Worker output events never trigger a refresh (they carry no state the workspace shows)."* (`refresh.ex:12-13`).

So the specific concern — "the dashboard re-reads the whole transcript on every stdout
line" — is **already mitigated by design**: a busy run spewing stdout wakes the
`ProjectWorkspaceLive` process **zero** times. The analysis below therefore (a) costs the
refresh that *does* happen, and (b) costs the transcript read where it *actually* lives
(MCP + HTTP), since that is the genuinely expensive read the task was worried about.

---

## 1. Scope — modules on the real refresh path

| Module | Role | File |
| --- | --- | --- |
| `ForemanServerWeb.ProjectWorkspaceLive` | LiveView; owns the refresh handler | `lib/foreman_server_web/project_workspace_live.ex` |
| `ForemanServerWeb.Workspace.Refresh` | coalescing + Worker-event filter | `lib/foreman_server_web/workspace/refresh.ex` |
| `ForemanServer.CoordinatorAPI` | `read_page/2`, `status_view/1` | `lib/foreman_server/coordinator_api.ex` |
| `ForemanServer.Overview` | `build/2` (thread cards) | `lib/foreman_server/overview.ex` |
| `ForemanServer.ProjectionStore` | **single GenServer** behind every read | `lib/foreman_server/projection_store.ex` |
| `ForemanServer.Threads.Transcript` | `page/2` — the real transcript read (NOT on the LiveView path) | `lib/foreman_server/threads/transcript.ex` |

### What one refresh reads and builds

Trigger: `handle_info(:workspace_refresh, …)` → `begin_refresh |> refresh_conversation |> load_state` (`project_workspace_live.ex:127-129`).

`refresh_conversation/1` (`:630`): one `CoordinatorAPI.read_page(after: cursor, limit: @page)` with `@page 200` (`:56`). `read_page/2` = `coordinator_conversation/2` + `coordinator_status/1` (`coordinator_api.ex:158-162`); each is one `coordinator_state/1` GenServer call (`projection_store.ex:655-662, 670-686`). Paging (`Conversation.page/3`) runs **in the caller**, bounded to ≤200 messages (`projection_store.ex:656-660`). Kept list clamped to `@max_kept 400` (`:57,:639`).

`load_state/1` (`:539`) reads, per refresh:
- `Overview.build(project_id, include_resolved: true)` (`:541`) — the heavy one (breakdown below).
- `status(project_id)` → `CoordinatorAPI.status_view` → 1 `coordinator_state` call.
- `project_view` → `ProjectStore.get` (separate process, 1 call).
- `proposals` → 1 `coordinator_state` call + 1 `task_projection` per proposed task.
- `questions` → `ProjectionStore.open_questions`.
- `memory_topics` → `ProjectMemory.list` (**disk**, `:563`).
- `library_entries` → `Library.list` (**disk**, `:570`).
- `schedules` → only when the active tab is `:scheduled`.

`Overview.build` call fan-out (`overview.ex:70-100, 236-333`):
- `ProjectionStore.thread_inputs` — 1 bulk read, then `build_all` in-process (`threads.ex:69-74`); window capped at `Threads.max_limit = 500` (`threads.ex:14,25`; `overview.ex:243`).
- `pr_states_for_project` + `repo_pr_states_for_project` — 2 bulk reads (`overview.ex:240-241`).
- `Signals.for_threads` — 1 bulk `needs_you_counts` + 1 `run_approvals` per thread that has pending signals (`signals.ex:43,85`).
- `pr_watch(run_id)` — 1 per thread whose head PR is `:open`/`:conflicted` (`overview.ex:290-293`).
- `pending_steering(run_id)` — 1 per `paused` workflow thread (`overview.ex:325-328`).
- `Tabs.build(project_id)` — ≥1 (`overview/tabs.ex:45`).

**Scaling.** Everything the refresh reads is **bounded and small**: coordinator page ≤200 msgs, thread window ≤500, no per-stdout-line work. Refresh frequency is bounded to **one per 250 ms** per non-Worker event burst (`refresh.ex:23-24,64`), and is **0** for stdout/stderr traffic.

---

## 2. Impact — GenServer calls per refresh and where they serialize

`ProjectionStore` is one `GenServer` (`projection_store.ex:28`); **every** read listed above is a `GenServer.call` serialized through that single process mailbox. One refresh issues, as an exact floor:

| Reader | ProjectionStore calls | Scales with |
| --- | --- | --- |
| `refresh_conversation` (read_page) | 2 (`coordinator_state` ×2) | — |
| `status_view` | 1 | — |
| `proposals` | 1 + 1·`task_projection` | # proposed tasks |
| `open_questions` | ≥1 | — |
| `Overview.build` | 4 fixed (`thread_inputs`, 2× pr_states, `needs_you_counts`) + `Tabs.build` | — |
| `Overview.build` per-thread | `run_approvals`·(signalled), `pr_watch`·(live PR), `pending_steering`·(paused) | # threads in window (≤500) |

**≈ 9–10 fixed `ProjectionStore` calls + O(threads) + O(proposals)** per refresh, plus 1 `ProjectStore.get` and **2 disk reads** (`ProjectMemory.list`, `Library.list`).

**Do any block the store for other callers?** Yes — all of them do, because they all run
in the one `ProjectionStore` process. But each refresh call is a **cheap in-memory map
read** served from GenServer state (e.g. `coordinator_state`, `thread_inputs`,
`run_logs_result` reads `state.run_logs[run_id]`). None of the refresh calls touch Postgres.

The **genuinely blocking** reads in `ProjectionStore` are **not on the refresh path**:
- `{:run_events, run_id}` → `EventStore.read_stream_forward("run:#{run_id}", 0, 99_999_999)` — a **full event-stream read from Postgres executed inside `handle_call`** (`projection_store.ex:1445-1457`). While it runs, **every other caller of the store blocks.**
- `{:run_logs, run_id}` → `:queue.to_list` + `Enum.sort_by` over up to `@run_logs_max_limit 5_000` entries, O(n log n) in-process but inside the GenServer (`projection_store.ex:5125,5227-5252`).

These two are reached only via `Threads.Transcript.page/2`, which calls `run/1 + run_logs/1 + run_events/1 + phases_for_run/1 + review/2` = **5 store calls, one of them a full DB stream read**, per workflow thread (`transcript.ex:445-457`). Call sites that hit it:
- MCP `foreman_thread_get` → `Transcript.page` (`mcp/tools.ex:1732`).
- HTTP `GET /threads/:id/transcript` and the SSE `GET /threads/:id/stream` (`router.ex:104-105`; `thread_transcript_controller.ex:32,99`). The SSE stream re-invokes `Transcript.page(after: cursor)` per poll — a **cursor** read, not a full re-read, but every poll still pays the `run_events` full-stream DB read.

**The `ProjectWorkspaceLive` dashboard is not among these call sites.** It never calls `run_logs`, `run_events`, `phases_for_run`, or `Transcript`.

---

## 3. Risks — ranked

| # | Risk | Severity | Where / why | Status |
| --- | --- | --- | --- | --- |
| R1 | `run_events` does `read_stream_forward(0, 99_999_999)` **inside** the single `ProjectionStore` `handle_call`, serializing a full Postgres stream read against every other store caller | **High** (latent) | `projection_store.ex:1445-1457` | Real, but **not** triggered by the dashboard. Triggered by MCP `foreman_thread_get` and the `/threads/:id/stream` SSE poll (`tools.ex:1732`, `thread_transcript_controller.ex:99`) |
| R2 | SSE `/threads/:id/stream` repeats `Transcript.page` (incl. the R1 DB read) per poll; N open stream clients on one run multiply R1 through the single store | Medium | `thread_transcript_controller.ex:99` | Real for the HTTP stream, not the LiveView |
| R3 | Premise drift: future work could re-add a per-output refresh by removing `@ignored_prefixes ["Worker"]` or routing worker events into `note_event` | Medium | `refresh.ex:24,88` | Guarded only by this one filter + its test; no structural barrier |
| R4 | `run_logs` O(n log n) sort over ≤5,000 entries per call inside the store | Low | `projection_store.ex:5227-5240` | Bounded by `WorkerLogPolicy`; in-memory |
| R5 | Dashboard refresh fan-out O(threads ≤500) serialized through the store | Low | `overview.ex:243,246` | Cheap in-memory reads; coalesced to 1/250 ms |

### Worst case: 10 dashboards open on one busy run

- **Worker-output storm (stdout/stderr):** each `WorkerStdout`/`WorkerStderr` is filtered by `@ignored_prefixes` (`refresh.ex:24,88`), so it arms **no** timer and does **no** read on any of the 10 views. **Cost of a busy run's output to 10 dashboards ≈ 0.** This is the direct answer to the task's worst-case question: the feared cost does not occur.
- **Non-Worker event burst (e.g. phase/PR/question events):** `ProjectionStore.subscribe` broadcasts to all 10 LiveViews; each arms its own 250 ms timer (`refresh.ex:64`) and, when it fires, runs its own ~9–10+ store calls. Upper bound ≈ **10 × (9–10 + O(threads)) ≈ ~100+ serialized in-memory `GenServer.call`s** within the window — all cheap, none touching Postgres. Serialized, not concurrent, but each is a map read; this is tolerable and already coalesced.
- **If 10 clients instead opened the `/threads/:id/stream` SSE** (not the dashboard): each poll pays R1's full-stream Postgres read, serialized through the one store → **this** is where 10 viewers on a busy run would actually hurt. That is the path worth hardening, not the LiveView.

---

## 4. Test plan — what must stay green

No code change is proposed by this assessment, so the gate is the existing suite plus the
tests that pin the properties this report relies on:

1. `test/foreman_server_web/workspace/refresh_test.exs` (or equivalent) — must assert that a `"WorkerStdout"`/`"WorkerStderr"` event does **not** arm the refresh timer and a non-Worker project event does. This is the single guard behind R3; if it does not exist, that is the first thing to add.
2. `ForemanServerWeb.ProjectWorkspaceLive` LiveView tests — refresh still renders after a coalesced burst.
3. Full suite: `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'` (unset `DATABASE_URL`/`EVENTSTORE_URL` first; the inherited langfuse Postgres on :55434 fails auth and the test config must fall back to :55432).

If any mitigation in §6 is implemented, add a `ProjectionStore` test asserting `run_events` no longer blocks concurrent reads (e.g. a long `run_events` call must not delay a concurrent `coordinator_state` call past a small bound).

---

## 5. Rollback

Not applicable — this is a read-only analysis; the only artifact is this report, deletable
with no runtime effect. For any mitigation later taken from §6: each is a localized change
to one function and reverts by `git revert` of that single commit; none alters an event
shape, projection schema, or public contract, so no data migration or replay is involved.

---

## 6. Mitigations (only if the real risks R1/R2 are acted on) — cheapest first

1. **Bound the `run_events` read.** Replace `read_stream_forward("run:#{run_id}", 0, 99_999_999)` (`projection_store.ex:1452`) with a paged/tailed read matching what `Transcript.page` actually consumes (it already pages its output at ≤1000). Removes the unbounded full-stream read from inside the GenServer. Smallest, highest-value fix.
2. **Move the DB read out of the GenServer.** `run_events` needs only `run_id`; `EventStore.read_stream_forward` can run in the *calling* process (it is a DB client call, not state access), so it stops blocking the store for all other callers. Low risk — the handler reads no `state`.
3. **Cache/debounce the SSE stream** (`thread_transcript_controller.ex:99`) so N clients on one run share one `Transcript.page` result per interval instead of each paying R1.
4. **Keep the Worker filter structural.** Leave `@ignored_prefixes ["Worker"]` (`refresh.ex:24`) and ensure the test in §4.1 exists, so R3 cannot regress silently.

For the dashboard path as it stands today, **no mitigation is warranted** — the costed
refresh is bounded, coalesced, in-memory, and Worker output already costs it nothing.

---

### Documentation gate

No externally visible identifier added, removed, or renamed (analysis only). `CLAUDE.md`,
`README.md`, `docs/user-guide.md`, `docs/cli-reference.md` need no edit. Report written to
the workflow-named artifact path only.
