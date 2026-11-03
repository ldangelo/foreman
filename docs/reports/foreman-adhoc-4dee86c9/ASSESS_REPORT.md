Assess complete. Report at `docs/reports/foreman-adhoc-4dee86c9/ASSESS_REPORT.md`.

**Headline: the task premise is stale — the feared hot path does not exist.**

- `load_log/1`, `note_output/3`, `Threads.Transcript.full/2`: none exist; `git log -S` shows they were **never** in the repo.
- `Workspace.Refresh` filters every `"Worker"`-prefixed event — `@ignored_prefixes ["Worker"]` (`refresh.ex:24`), checked in `relevant?/2` (`refresh.ex:88`). `WorkerStdout`/`WorkerStderr` (`projection_store.ex:3094,3098`) therefore arm **no** refresh. Module doc says so verbatim (`refresh.ex:12`).

**Answers to the four questions (all counts exact-from-code; latencies estimated, nothing benchmarked):**

1. **Per refresh:** coordinator page ≤200 msgs + `Overview.build` over ≤500 threads + 2 disk reads (memory/library). All bounded, in-memory; no per-stdout-line work. Does not scale with the 10k-line/5-MiB log bound b/c logs aren't read here.
2. **Store calls:** ~9–10 fixed `ProjectionStore` `GenServer.call`s + O(threads)+O(proposals), all serialized through the one `ProjectionStore` GenServer (`projection_store.ex:28`) but all cheap map reads — none touch Postgres. The blocking read (`run_events` = `read_stream_forward(0, 99_999_999)` inside `handle_call`, `projection_store.ex:1452`) is **not** on the LiveView path; it lives on the MCP/HTTP transcript path (`tools.ex:1732`, `thread_transcript_controller.ex:99`).
3. **10 dashboards on a stdout-busy run ≈ 0 cost** — worker output wakes none of them. A non-Worker event burst costs ~10×(9–10) serialized cheap calls, coalesced to 1/250 ms each.
4. **Mitigations** target the real risk (R1/R2, the SSE transcript stream + unbounded `run_events`), not the dashboard: bound/page `run_events`, move its DB read out of the GenServer, debounce the SSE stream, keep the Worker filter + a test. For the dashboard as-is, none warranted.

Sections 1–5 (Scope/Impact/Risks/Test plan/Rollback) + ranked risks R1–R5 in the report. Doc gate: analysis-only, no identifiers changed.

Status-update note: inbox progress + completion sent OK; the task Work Log comment was refused (`Task external_id is malformed`) because this adhoc task is not provider-tracked — expected, not a blocker.