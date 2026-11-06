Phase 1 complete. Report: `docs/reports/foreman-adhoc-4f35b3c7/FIX_REPORT.md`.

**Recovered first, as instructed.** `git checkout HEAD -- packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex` restored the 525-line module; the restyle was then redone as small edits with `MIX_ENV=test mix compile --warnings-as-errors` after every batch. Every `def`/`defp`, `mount`, `handle_params`, `handle_event` (filters, tab, select-run, file preview, stop/resume/reset/abandon + `intent-key`) and the `?run_id=R[&tab=T&file=F]` deep link are untouched — diff is 223+/85− across the template, plus 9 lines in `layouts.ex`.

**Root cause:** the run dashboard invented its own CSS names (`operator-run-dashboard`, `dashboard-layout`, `focus-marker`, …) that the single stylesheet (`workspace/layouts.ex`) never defined, and leaked `inspect/1` terms (`:absent`, `[:status]`) into the page.

**Validation**
- `compile --warnings-as-errors`: clean. `mix format --check-formatted`: clean.
- New `operator_run_dashboard_ui_test.exs` (7 parity tests) + existing `operator_run_dashboard_live_test.exs` + `operator_dashboard_test.exs`: **49 passed**.
- Full suite: **6905/6907 passed, 10 excluded (529.7s)**. The 2 red are `config_test.exs:73/:87`, which assert `DATABASE_URL =~ "localhost"` against the `:dev` config — red only because the suite must run against `127.0.0.1:55432/foreman_test` here; identical before and after my diff, unrelated to `foreman_server_web`.
- Doc gate: no routes/tools/env/config/CLI identifiers touched; all four doc files grepped clean → no edits needed. PRD/TRD for the run dashboard name the removed classes and were left as written (point-in-time specs).

**Two things to flag**
1. Latent bug found while recovering: `@tabs` inside `~H` is *not* a module attribute (HEEx compiles it to `assigns.name`) — that is what made the page 500. The tablist is now four explicit static tab buttons; do not "simplify" it back to a comprehension.
2. `.ws-layout--runs` (2-column override) is an app-shell change that may conflict with concurrent run `run-df42b06452304231a63e9218316cd259`.

Not done (in `Follow-ups`): `/dashboard` root and `/admin` still use the old invented classes; out of this brief. No commit, branch, push or PR — tree left staged-free for Foreman to commit. `foreman_inbox_send`/`foreman_task_add_comment` were unavailable and `ask_advisor` fails in this worktree (`Advisor model not found: openai-codex/gpt-5.5`), so progress updates and the advisor gate could not be run.

---

**Follow-up note (2026-11-06).** The doc-gate line above ("no edits needed") no longer holds: the PR 836 follow-up edited `docs/user-guide.md` (run list wording). The tablist is still four static buttons, now sharing one always-present `#dash-panel` tabpanel, and the new dashboard event tests supersede the "7 parity tests" count.
