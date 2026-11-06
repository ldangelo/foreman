Phase complete. Report-only run, per operator instruction.

**Artifact:** `docs/reports/foreman-adhoc-4f35b3c7/REVIEW_REPORT.md` (only file changed; `git status` shows just that `M`).

**Diff reviewed:** `git diff main...HEAD` (base = `main`, merge-base `4ee1b417` → `b6d70d41`) — 6 files, +565/−83: `operator_run_dashboard_live.ex`, `workspace/layouts.ex`, new `operator_run_dashboard_ui_test.exs`, plus the three report docs.

**Previous-phase carry-forward:** `REVIEW_CODERABBIT_REPORT.md` is 57 bytes with no `FOREMAN_REVIEW_FINDINGS_*` block → nothing to carry.

**Findings (all verified against HEAD; none fixed, per instruction):**
- Major — committed `FIX_REPORT.md`/older `REVIEW_REPORT.md` describe files never touched by this branch (`operator_dashboard.ex`, `components.ex`, `nav_runs.ex`, `change_evidence.ex`, `router.ex`, 2 test files) and claim "49 tests, 0 failures".
- Major — `operator_run_dashboard_live.ex:658-659` `Map.get(@chip_kinds, status, "muted")` silently degrades unmapped statuses (`needs_recovery`, `unresponsive` are live elsewhere); same catch-all at `:488-492`, `:555-560`.
- Major — `:555-560`/`:621-633` re-implement `ChangeEvidence` status vocabulary inside the LiveView (§5.7 boundary duplication).
- Minor — untyped `meta` map (`:530`, `:584`); `describe(@error)` struct leak (`:155`); unsound `styled_classes/0`/`emitted_classes/0` guard (`ui_test.exs:148-160`); pre-existing dead `ws-nav-*` classes (`components.ex`); `live_dashboard.ex:62` still unstyled; copy at `:147`.

**Not run here:** compile, tests, formatter — nothing was changed to verify; earlier green-test claims are explicitly not endorsed.

Scratch diff files deleted from the worktree and from the run directory.

---

**Resolved in follow-up commit (2026-11-06).** The review above covers an earlier head (`b6d70d41`); against the PR 836 follow-up these findings were addressed and no longer hold:
- Major, silent `"muted"` default in `chip_kind/1` (`operator_run_dashboard_live.ex`): `needs_recovery` (red), `retrying` (info) and `skipped` (muted) are now mapped, and an unmapped status renders in the visible `warn` colour. The `entry_kind/1` catch-all is unchanged except that `stdout` now maps to the agent style instead of falling through to system.
- The run row once more shows the task label, the shared stylesheet's generic button rule no longer overrides the run rows' selected marker, and the dashboard's events (tabs, refresh, filter, select-run, run action) are now driven by tests through the rendered DOM.
- `docs/user-guide.md` describes the final run list.

Not addressed and still open: the `ChangeEvidence` vocabulary duplication, the untyped `meta` map, and the `styled_classes/0` guard's looseness. The statement that earlier green-test claims are not endorsed is left as written.
