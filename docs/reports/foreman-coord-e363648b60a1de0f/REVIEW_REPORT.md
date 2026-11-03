# Repository-rules review

## Review engine

Reviewer: repository-rules review phase agent, against this repo's own
`AGENTS.md` conventions (Working Rules, §5 Typed Boundaries, Documentation
Gate, UI invariants).

Diff range reviewed: `git diff main...HEAD` (`$FOREMAN_BASE_BRANCH=main`,
confirmed set). Reviewed source files:
- `packages/foreman_server/lib/foreman_server_web/project_workspace_live.ex`
- `packages/foreman_server/lib/foreman_server_web/workspace/components.ex`
- `packages/foreman_server/lib/foreman_server_web/workspace/project_view.ex`
- `packages/foreman_server/lib/foreman_server_web/workspace/layouts.ex`
- two test files (`project_view_test.exs`, `project_workspace_live_test.exs`)

Carry-forward: the previous phase's `REVIEW_CODERABBIT_REPORT.md` contains **no**
`FOREMAN_REVIEW_FINDINGS_START/END` marker block (its two findings were both
resolved in that phase; its unresolved block was empty). Nothing to carry
forward.

## Findings

No new findings. One pass over the diff produced no rule violation; a second
re-read of `main...HEAD` confirmed nothing introduced one. Points verified:

- **Error handling reports, not hides (§5.2/§5.3).** `memory_topics/1` and
  `library_entries/1` map `{:error, _}` → `:error` (distinct unavailable state),
  not `[]`; `info_panels` renders that distinctly via `is_list/1` guards.
  Missing on-disk dirs already yield `{:ok, []}`, so empty ≠ failed.
- **Typed boundary (§5.1).** `ProjectView.t()` extended with the
  `instructions: String.t() | nil` field; `build/1` normalises both atom- and
  string-keyed config once; `blank_to_nil/1` matches `is_binary` and `nil` only
  (a non-string present value raises — Absent ≠ malformed, §5.3).
- **No dead config/enum.** Every added field is read: `instructions` by the
  Instructions panel, `memory_topics`/`library_entries` by their panels,
  `overview.groups` flattened by `flatten_threads/1` for the Threads panel.
- **Data contracts confirmed against source:** `ProjectMemory.list/1` →
  `{:ok, [Topic.t()]}` with `.name`/`.description`; `Library.list/1` →
  `{:ok, [Entry.t()]}` with `.name`/`.file_count`; `Overview.groups` is
  `%{Group.group() => [ThreadCard.t()]}` with `.title`/`.status`. CSS classes
  used (`ws-panel`, `ws-panel-list`, `ws-muted`, `ws-error`, `ws-msg`) all exist
  in `layouts.ex`.
- **UI invariants.** Read-only panels only; no new command or event introduced;
  CSS lives in the root layout `layouts.ex` (no asset pipeline); components in
  `workspace/`.
- **Documentation gate.** No externally visible identifier added/removed/renamed
  (no routes, config keys, env vars, CLI verbs, or MCP tools) — only private
  functions, an internal component attr, CSS, and tests. No doc reconciliation
  required.

## Fixed

None. The diff already complied with the repository's rules.

## Declined

None.

## Verification

Ran with `DATABASE_URL`/`EVENTSTORE_URL` unset (inherited values point at the
wrong Postgres; see project memory).

| Command | Exit |
| --- | --- |
| `mix test --warnings-as-errors test/foreman_server_web/workspace/project_view_test.exs test/foreman_server_web/live/project_workspace_live_test.exs` | 0 — **54 passed** |
| `mix format --check-formatted` (4 edited `.ex` + 2 `.exs`) | 0 |
| `git status --short` (after review) | clean (no stray files) |

<!-- FOREMAN_REVIEW_FINDINGS_START -->
<!-- FOREMAN_REVIEW_FINDINGS_END -->
