

Phase 4 (`repo-rules-review`) done.

**Diff range:** `git diff main...HEAD` ($FOREMAN_BASE_BRANCH=main, merge-base `f0f3b083`, HEAD `8b84206d`) → 3 added files, no product code, no user-facing doc.

**Fixed (2, in place, uncommitted)** — this run's own artifacts lied:
- `PLAN.md:16,:103` — claimed qdt14 `295155d0` "no PR open" + only work "at risk of loss". False: PR #946 OPEN. Now names #946; operator action = none.
- `FIX_REPORT.md:10,12-14,18` — false "zero open PR / at risk of loss"; dangling commit `b7b7b974` (rev-parse → exit 128, in no ref); non-existent path `aggregates/settings.ex:31` → real `aggregates/project/settings.ex:47-51`; false "no escalation tools" (both work via codemode MCP).

**Declined (2):**
- `docs/user-guide.md` request (major): all 4 subjects absent here — server rejects `base_ref_policy` (`{:unknown_setting, :base_ref_policy}`), no `base_sha` on `RunBaseBranchRecorded`, no `branch.behind_origin`, no fetch-before-run. Each owned by open PR #943/#945/#946, none merged. Prose here = AGENTS.md §5.2 plausible-looking success + collision. user-guide byte-identical to base.
- `REVIEW_CODERABBIT_REPORT.md` = 2 bytes, no findings block → nothing carried forward; recorded, not fabricated.

**Verification:** 9 read-only checks (exit 0/1/128 as recorded in report). Repo doc-gate test `mix test test/foreman_server/observability/docs_test.exs` **did not execute** — Mix aborts `the dependency is not available, run "mix deps.get"` (Hex deps unfetched in this worktree) → exit 1, environment defect, reported as such. No formatter applies (markdown only).

**Artifact:** `docs/reports/foreman-beads:foreman:foreman-okend/REVIEW_REPORT.md` — 5 sections, findings block (4 entries: 2 open, 2 declined), risk LOW. Marker/JSON/fence/order validator: 44 checks PASS.

Notifications sent: Foreman inbox + task comment (both OK), kata comment on `fy7m` (closed issue).

Caveats: advisor review skipped — `ask_advisor` fails (Anthropic oauth `invalid_grant`, refresh expired; operator must re-auth). Three subjects' prose still lives only on unmerged PRs #943/#945/#946. Operator should run `mix deps.get` then re-run the doc-gate test.