Phase 4 complete.

**Review scope**: `git diff main...HEAD` = `796c888c...705d2909`, 5 files / +336 (dispatcher guard +13, its test +113, 3 earlier-phase report files). Base branch was set, so no Blocked path.

**Findings — 4 total, 1 fixed, 3 declined**

Fixed:
- **F1 `CLAUDE.md` §18 (minor)** — the diff changed run-slot promotion semantics (a promoted run is skipped and its slot handed back when the task is `closed`/`failed`/`blocked`) with nothing in the repo documenting it. `README.md`, `docs/user-guide.md`, `docs/cli-reference.md` need no edit — they carry zero run-slot-promotion coverage (the 2 README "promot" hits are the unrelated BeadsDbLease path). Added one bullet to §18 after line 1020; no other line touched.

Declined:
- **F2 `dispatcher.ex:1438`** — `@non_startable_task_statuses` duplicates the vocabulary `aggregates/task.ex:46 @valid_statuses` owns. No repo rule designates a canonical list (three parallel copies already exist) and the aggregate's list is a private attribute; exposing it adds API this diff doesn't need.
- **F3 `dispatcher_slot_promoted_test.exs:190`** — raw `:meck.new` instead of `TestSupport.MeckScope`. No rule mandates it (26 files vs 30 raw) and the same file already raw-mocks at `:43`/`:44`, so it matches the local pattern.
- **F4 `dispatcher.ex:1725`** — the BeadsDbLease path `re_dispatch_promoted/3` still starts runs for non-startable tasks. Different promotion path, outside this run's scope, tracked in `beads:foreman:foreman-tepov`.

Also noted, not touched (pre-existing, rule 4): the `acknowledged_run_id` clause in `start_promoted_run/2` is unreachable (`tasks_by_run_id/1` excludes those tasks), and the `[]` branch releases neither slot nor waiter.

**Verification** (all exit 0, re-run after the fix): `dispatcher_slot_promoted_test.exs` → 10 passed; `task_test.exs` + `run_slots_test.exs` + `run_slots_promote_test.exs` + `run_slots_release_test.exs` → 108 passed; `mix format --check-formatted` clean; `mix credo --min-priority higher` on both changed files → "found no issues". The re-read of the diff after the fix confirmed the only new hunk is the doc bullet.

**Report**: `docs/reports/foreman-beads:foreman:foreman-pjugt/REVIEW_REPORT.md` with both marker blocks validated through the real parsers — `ReviewFindings.read/1` → 4 findings, `PrRisk.parse_judgement/1` → `MEDIUM`. Note: a findings document must carry all `@required_keys` (`review_findings.ex:78`) — I wrote `findings_block_sha256`/`document_sha256` placeholders, which the server recomputes in `prepare/1`; omitting them yields `{:malformed, :missing_required_keys}`, i.e. hidden, which is worse than an unresolved finding.

**State**: nothing committed — `M CLAUDE.md` + the untracked report. `foreman_inbox_send` delivered (confirmed by reading it back via `foreman_inbox_get`, `msg_ANDX0i1xpzEp1z4f573kFQ`); `foreman_task_add_comment` remains unavailable to this phase, and `ask_advisor` still fails on the expired Anthropic credential.