

**Repo-rules review — done.** Bead `beads:foreman:foreman-p0b23`, run `run-1d5bb343dcae0b4d55f102b84a26ad14`, base `main` (merge-base `f0f3b083`, HEAD `f2ee5845`, 20 files/+1288).

**Rules applied:** root `AGENTS.md` §5.2/§5.3/§5.7 + doc gate + surgical-changes.

**Fixed 4:**
1. `docs/user-guide.md:757` — prose claimed artifact "under the last heading" + extra headings "share the last block"; code (`PrBody.contents_under/2`) maps **positionally**. Rewrote prose to match code + `pr_body_test.exs`.
2. `docs/user-guide.md:736` — blank line split `pr_body_headings` row out of settings table (headerless 1-row table). Removed.
3. §5.7 violation — settings→PR-context mapping written 3× (`pr_create.ex:216`, `repo_pr_context.ex`, `run_executor.ex`). Now one module `ForemanServer.Workflow.PrBodyContext` (`put_headings/2`, `put_project_headings/2`); 3 private copies deleted. Settings **source** unchanged (run_exec = latched `state.project_settings`; command doors = live projection).
4. `repo_pr_context.ex:89` — comment glued to previous function's comment. Gone with #3.

**Declined 2:** run_executor latched-vs-live settings source (latching deliberate); phase PR keeps own body (out of scope, already documented).

**New:** `lib/foreman_server/workflow/pr_body_context.ex` + `test/.../pr_body_context_test.exs` (6 tests).

**Verify:** compile `--warnings-as-errors` 0 · targeted suite **99 passed** 0 · `mix format --check-formatted` 0 · `git diff --check` 0 · report JSON blocks parse, markers outside fences.

**Pre-existing hang (not mine):** `auto_pr_test.exs` exit 124 — 56 tests/stall L#1281 with fixes vs 53/L#1221 at plain HEAD (stash A/B), 0 failures both. `auto_pr.ex` untouched.

**Artifact:** `docs/reports/foreman-beads:foreman:foreman-p0b23/REVIEW_REPORT.md` (findings + MEDIUM risk blocks). Fixes left **uncommitted** for Foreman. Kata `kap9` closed with test evidence.

**Unavailable:** `ask_advisor` (Anthropic oauth `invalid_grant`), `foreman_inbox_send`/`foreman_task_add_comment` (not on PATH) → no progress note sent.