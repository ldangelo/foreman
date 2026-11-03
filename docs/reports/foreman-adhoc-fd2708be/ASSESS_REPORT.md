# ASSESS: Workspace.Refresh — what it arms and ignores

Read-only. `ForemanServerWeb.Workspace.Refresh` = coalesced, subscription-driven refresh for workspace LiveViews. Subscribes once (live events, no replay); first dirty event arms one timer, later events in-window only set the flag (N events → 1 refresh). No periodic timer.

- **Arms:** `Process.send_after(self(), :workspace_refresh, coalesce_ms())` (default 250ms, `config :foreman_server, :workspace, coalesce_ms:`). Emits `[:foreman_server, :workspace, :refresh]` telemetry on each refresh.
- **Ignores:** events whose `event_type` starts with `"Worker"` (`@ignored_prefixes`, worker output carries no shown state); and events for a different project (`:project_id` mismatch). Events with no `project_id` (e.g. run events) refresh every workspace. Any other event shape raises — not ignored, not guessed.
