# Handoff — Improve task capabilities in the cockpit

Status: Implemented in `clients/cockpit/` · Date: 2026-07-10 · Owner: Leo D'Angelo
Audience: local coding agent (Go / Bubble Tea)
Related: `docs/design/cockpit-ui-spec.md`, `clients/cockpit/`


Implementation note (2026-07-11): the shipped UX intentionally uses rich two-line
task/run rows and an in-pane `textinput`/`textarea` create form instead of the
earlier one-line/no-id row and nvim-JSON-first create sketch below. Task detail
is scrollable through the shared `Viewer` and the current documentation in
`clients/cockpit/README.md` and `docs/design/cockpit-ui-spec.md` is authoritative
for operator behavior.
## 1. Objective

Three improvements to how the cockpit handles tasks:

1. **Full task detail view** — when a task is selected, the detail pane shows all
   task fields, not just the title.
2. **Wider, richer task list** — widen the left list and show task **title,
   priority, and type** per row (id moves to the detail view).
3. **Create tasks from the list** — add a "new task" action to the task list.

Yes — the task list **is a component**: `TaskList` in `clients/cockpit/task_list.go`
(state) rendered by `renderLeft`/`renderRow` in `view.go`. Any new create-form
state should be a sibling component (see Workstream 3), keeping the pattern.

## 2. Current state (build on this)

- `Task` (in `client.go`) already has every field we need — no new fetch
  required for detail:
  `TaskID, Title, Description, TaskType, Priority, Status, Depends, Workflow, Summary, ProjectID`.
  `httpClient` already maps `task_type`/`type`, `description`, `depends_on`,
  `project_id`, etc.
- `Client` interface already has `UpdateTask(task Task) error`, implemented via
  `httpClient.postCommand("task.update", payload)` and a no-op on `mockClient`.
  `task_edit.go` (`editTaskInNvim`) is the working "edit JSON in nvim → post a
  command → refresh" flow. **Mirror it for create.**
- `TaskList` exposes `Items()`, `SelectedIndex()`, `SelectedItem()`, `Move`,
  `Counts`, `keepSelectedVisible`, search/scope/collapse. `model.selectedTask()`
  returns the selected READY task.
- The list width is a fixed `leftW` (28, or 22 when total < 92) in `view.go`;
  `renderRow` currently renders `glyph + id + right(priority|phase|status)`.
- Task detail today: `renderBody`/viewer for a non-run selection shows only
  `Summary` + a few fields.

## 3. Workstream 1 — Full task detail view

Intent: selecting a task shows all its fields in the right pane.

- In the task (non-run) branch of the detail/viewer render (`view.go`), render a
  labeled field block. Suggested order and formatting:
  - `id` (dim), `title` (primary, wrapped), `type` (tag), `priority` (colored
    badge: P0=danger, P1=warning, P2+=faint), `status` (colored by state),
    `project`, `depends`, `workflow`, then `description` (wrapped; render as
    markdown via the existing Glamour renderer if non-empty, like reports).
  - Reuse the existing `kv(label, value)` helper and `wrap()`; keep empty fields
    out (don't print blank rows) or show `—`.
- Keep it inside the `Viewer` line model so scrolling works for long
  descriptions; make each field a keyed viewer line.
- Acceptance: selecting any task shows id, title, type, priority, status,
  project, depends, workflow, and description (markdown-rendered) — every
  non-empty field is visible and scrolls; runs are unaffected.

## 4. Workstream 2 — Wider list; show title, priority, type

Intent: rows are legible task rows, not opaque ids.

- Widen the list. Replace the fixed `leftW` with a responsive width: default ~40,
  `min 32`, and cap so the right pane keeps `>= 44` columns
  (`leftW = clamp(desired, 32, total-45)`), reducing gracefully on small
  terminals. Keep it in one place so both `renderLeft` and the layout math agree.
- Implemented row shape for **task (READY)** rows:
  `‹id› ‹type› ‹priority›` metadata on the first line and the task title on the
  second line, with project metadata added when global scope is active. This
  supersedes the earlier sketch that moved the task id out of the row.
- Implemented row shape for **run (RUNNING/RECENT)** rows: task id, type,
  priority, phase/status, title, and summary/last signal when available. Runs are
  enriched from the task map in `httpClient`; missing titles fall back to ids.
- The list now uses two-line viewport rows, so keep-visible and mouse hit-testing
  count rendered row height rather than assuming one terminal row per item.
- Acceptance: task rows show id/type/priority/title plus available project
  metadata; run rows show title plus phase/status; the list is visibly wider;
  long titles truncate with `…`; narrow terminals still render without wrapping.

## 5. Workstream 3 — Create a task from the list

Intent: press a key in the task list to add a new task.

- Client: add `CreateTask(task Task) error` to the `Client` interface.
  - `httpClient`: implemented via `postCommand("task.create", payload)`, payload
    mirroring `UpdateTask` (title, description, `type`+`task_type`, normalized
    priority, `project_id`, status=`open`/`backlog`). The Elixir command bus
    route is `task.create` (`packages/foreman_server/lib/foreman_server/command_router.ex`
    and `aggregate_router.ex`).
  - `mockClient`: `CreateTask` appends to an in-memory slice so `COCKPIT_BACKEND=mock`
    shows the new row after refresh.
- Interaction: bind `n` (new) to an in-pane `textinput` / `textarea` form
  component. Draft defaults:

  ```json
  { "title": "", "task_type": "task", "priority": "P2", "description": "" }
  ```

  On `ctrl+s`, parse and call `CreateTask`; on empty title, cancel with a notice.
  Emit `taskActionDoneMsg{action:"created"}` and trigger `loadData` to refresh.
- Inline quick-add is implemented: `N` opens a one-line prompt for just the title
  (type/priority default), submitting on `enter`. The full `n` form and quick-add
  both live in `task_form.go`, post `task.create`, and refresh after the command
  succeeds.
- New tasks are created in the current project scope
  (`COCKPIT_PROJECT_ID`/`FOREMAN_PROJECT_ID` if set) so they appear in the list.
- Acceptance: `n` from the list opens the full create form, `N` opens quick-add,
  and on save a new task is created (live via `task.create`, or in-memory in
  mock) and appears in READY after refresh; empty/invalid input cancels cleanly
  with a notice.

## 6. Keymap additions (update spec + README)

| Key | Context | Action |
|-----|---------|--------|
| `n` | task list focused | full new-task form (`ctrl+s` → `task.create`) |
| `N` | task list focused | inline quick-add title (`enter` → `task.create`) |

Leave existing task keys as-is: `y` copy id, `a` approve, `e` edit, `enter`/`o`.

## 7. Testing (TDD, table-driven)

- `CreateTask` payload builder is a pure function returning the command payload;
  assert fields (including `type`+`task_type` duplication and project scoping) in
  table-driven tests, plus the empty-title cancel path.
- New-task template parse: table tests for valid JSON, missing title, extra
  fields, malformed JSON.
- `renderRow` for tasks: assert the rendered row contains priority badge, title
  (truncated), and type within `leftW`, and that width math keeps rightW ≥ min.
- Detail render: assert all non-empty task fields appear; empty fields omitted.
- `mockClient.CreateTask` round-trips into `Dispatchable()`.
- `go build ./... && go test ./...` clean; `go vet` clean.

## 8. Docs to update (documentation gate)

- `clients/cockpit/README.md` — new `n` key, wider list description, "task rows
  show title/priority/type", detail shows all fields.
- `docs/design/cockpit-ui-spec.md` — left-column row spec (title/priority/type),
  task detail field list, and the `n`/`N` keymap rows.

## 9. Non-goals & risks

- No new backend endpoints; if `task.create` isn't exposed on the command bus,
  stop and flag rather than adding Elixir endpoints here.
- Don't regress run rows or the RUNNING/RECENT grouping; widening must not break
  the viewport/keep-visible logic.
- Priority values may arrive as `P0`/`0`/`2` etc. — normalize in one helper used
  by both the badge and the create payload.

## 10. Suggested sequencing

1. WS1 (full detail view) — pure render, no new client method; fastest.
2. WS2 (widen + richer rows) — layout + `Run.Title`/`Run.TaskType` enrichment.
3. WS3 (`CreateTask` + `n` template flow + `N` quick-add).
4. Docs sweep.
