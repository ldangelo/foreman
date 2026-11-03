Done. Summary:

**Task**: Filled empty `section.ws-panels` shell w/ 4 read-only panels, server data only, no new commands/events.

**Changes** (all in `packages/foreman_server/`):
- `workspace/project_view.ex` — added `instructions` field to `ProjectView.t`/`build/2` (read from config like `goal`).
- `project_workspace_live.ex` — alias `Library`/`ProjectMemory`; `load_state/1` loads `memory_topics` + `library_entries` (a missing dir is already `[]`; a genuine read failure returns `:error`, rendered as an "unavailable" state, not an empty collection); render `Components.info_panels` in shell.
- `workspace/components.ex` — new read-only `info_panels/1`: Instructions text, memory name/desc, library name + file count, thread titles/status flattened from `overview.groups`. No `phx-click`, no mutation.
- `workspace/layouts.ex` — inline `.ws-panel`/`.ws-panel-list` CSS (no asset pipeline).

**Preserved**: chat send, overview, questions, Library/PR/Scheduled tabs, library upload, PR buttons — all untouched.

**Tests**: added ProjectView instructions test + LiveView `read-only side panels` describe (headings, instructions text, empty states, thread title). 
- `mix test --warnings-as-errors` on both files → **54 passed**, exit 0 (DATABASE_URL/EVENTSTORE_URL unset).
- `mix format --check-formatted` → exit 0.

**Doc gate**: no externally visible identifiers (private component, internal field, 2 CSS classes). Grep of CLAUDE.md/README.md/docs/user-guide.md/docs/cli-reference.md → no hits. No doc edits needed.

**Git**: only the 6 intended files modified; no `.beads/`, no stray `docs/reports/` beyond FIX_REPORT. Changes left uncommitted for Foreman to commit + open the PR (merge gate operator-only).

Report: `docs/reports/foreman-coord-e363648b60a1de0f/FIX_REPORT.md`.