Plan written. No code changed.

**Artifact:** `docs/reports/foreman-beads:foreman:foreman-p0b23/PLAN.md` (251 lines, untracked; only file touched — `git status` shows nothing else).

**Verdict: real bug (missing feature).** `pr_body_template`/`pr_body_headings` appear nowhere in `*.ex|*.go|*.md`; `Aggregates.Project.Settings.@keys` (settings.ex:47-51) lacks the key → `{:unknown_setting, ...}`. Fallback body is hardcoded in `auto_pr.ex:715-722`.

**Plan shape:**
- Setting named `pr_body_headings` (list, mirrors `repo_allowlist` precedent) — bead text permits "headings-list".
- New pure `ForemanServer.Workflow.PrBody` + `PrBody.Sources` struct renders headings → content from task title/description, run commits (`git log --format=%H%x09%s base..head`), artifact + ReviewFindings section/unresolved counts. Unknown heading → explicit `_Not recorded by Foreman._`, never empty.
- `pr_content/1` → `pr_content/3`; headings arm only when key present, so existing stubbed runners/tests unaffected.
- All 3 context producers plumbed (`run_executor.ex:3121`, `repo_pr_context.ex:40`, `pr_create.ex:185`) — missing one makes the setting silently inert on that path.
- Mirror list enumerated: `project_updated.ex` type+defstruct, `project_settings.ex` type, MCP `@settings_update_keys`+schema, Go flag/payload/`projectSettingNames`/usage const, LiveView `@list_fields`+field+`error_field/1`.
- Phase-PR builder (`phase_pr.ex:344`) explicitly out of scope; `PrBody` written to be reusable there later (§5.7).

**Doc gate (this diff):** one new report artifact, zero externally visible identifiers added/removed/renamed → no edits needed to CLAUDE.md/README.md/docs/user-guide.md/docs/cli-reference.md. The plan itself assigns the gate work for the implementer: user-guide settings row, cli-reference flag line + table row, CLAUDE.md:1240 whitelist; README.md justified as no-edit (names no individual settings key).

**Tests:** not run — plan-only phase, zero code changed.

**Progress tools:** `foreman_inbox_send`/`foreman_task_add_comment` not exposed in this phase; no status updates sent.