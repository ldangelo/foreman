# Handoff — Improve task capabilities in the cockpit

Status: Implemented in `clients/cockpit/` · Date: 2026-07-10 · Owner: Leo D'Angelo
Audience: local coding agent (Go / Bubble Tea)
Related: `docs/design/cockpit-ui-spec.md`, `clients/cockpit/`


Implementation note (2026-07-11): the shipped UX intentionally uses rich two-line
task/run rows and an in-pane `textinput`/`textarea` create form instead of the
earlier one-line/no-id row and nvim-JSON-first create sketch. Task detail is
scrollable through the shared `Viewer`; `clients/cockpit/README.md` and
`docs/design/cockpit-ui-spec.md` are authoritative for operator behavior.
## 1. Implemented scope

The shipped cockpit closes the three task-capability goals:

1. **Full task detail view.** Selecting a READY task renders non-empty task
   fields in the shared `Viewer`: id, title, type, priority, status, project,
   dependencies, workflow, and description.
2. **Wider, richer task/run list.** Task rows remain identifiable in the list:
   the first line shows id/type/priority metadata, the second line shows the
   title, and global scope adds project metadata. Run rows are enriched from the
   task map with task type, priority, title, phase/status, and last signal.
3. **Task creation from the list.** `n` opens the in-pane
   `textinput`/`textarea` create form; `N` opens one-line quick-add. Both post
   `task.create` and refresh the list after success.

This supersedes the earlier sketch that moved task ids out of rows and used
nvim JSON as the primary create flow.

## 2. Client and component shape

- `Task` in `client.go` maps the live projection fields needed by detail and
  list rows, including `task_type`/`type`, `description`, `depends_on`,
  `dependencies`, `project_id`, and workflow.
- `CreateTask(task Task) error` is part of the `Client` interface.
  `httpClient` posts `task.create`; `mockClient` appends an in-memory READY task
  so `COCKPIT_BACKEND=mock` demonstrates the flow.
- `TaskList` remains the left-pane component for section tabs, filtering,
  current/global project scope, selection identity, keep-visible behavior, and
  mouse row hit-testing.
- `task_form.go` owns the full create form and quick-add state as a sibling to
  the list, not as ad-hoc state inside the renderer.

## 3. Keymap

| Key | Context | Action |
|-----|---------|--------|
| `n` | task list focused | full new-task form (`ctrl+s` → `task.create`) |
| `N` | task list focused | inline quick-add title (`enter` → `task.create`) |

Existing task keys remain: `y` copy id, `a` approve, `e` edit, `enter` focuses
the selected details, and `o` opens rows that have external targets.

## 4. Verification completed

- Payload tests cover task create/update command fields, including duplicated
  `type`/`task_type`, priority defaults, project scoping, and empty-title
  cancellation.
- Render tests cover rich task rows, detail fields, truncation/narrow layout, and
  mock create round-tripping into the READY list.
- Focused and full cockpit verification has passed with `go test ./...`,
  `go generate ./...`, `go vet ./...`, build, and mock dump smoke.

## 5. Closed non-goals

- No new backend endpoint was added; the shipped flow uses the existing Elixir
  command bus route `task.create`.
- No regression to run rows or RUNNING/RECENT grouping; the list uses viewport
  row identity and row-height-aware hit-testing.
