# Workspace PR action buttons: live LiveView evidence (foreman-i6kws)

Observed against a real `mix` dev server (branch `uigaps-pr`, private DB `uigaps_dev`, port 47937,
`FOREMAN_PR_MONITOR_ENABLED=false`), driven with headless Chromium through the `browser` helper
at `http://localhost:47937/dashboard/projects/demo`. Four completed runs were seeded through the real
command path (`run.pr.ready` / `run.pr.checks` / `run.pr.review`); no GitHub was contacted for
the seed (the `gh` calls the PrWatcher made after a click failed with "Could not resolve to a Repository" because
`acme/demo` does not exist, which is the expected result here).

| Thread | State seeded | Group observed | Buttons observed |
|---|---|---|---|
| Add /healthz route (CI red) | PR open, checks `failing`, changes requested | **Waiting on you** (`ci_failing`, red "CI failing" line) | Fix CI and Address comments enabled; Resolve conflicts and Create PR disabled with reasons |
| Docs touch-up (CI green) | PR open, checks `passing` | Ready for review | all four disabled, each with a visible reason |
| Rename config key | PR `conflicted` event only | Ready for review (the PrChecksChanged status does not move the PR projection to `conflicted`; a real `PrUpdated` does) | Resolve conflicts enabled |
| Refactor parser | completed, no PR | Idle | Create PR enabled; the three fix buttons disabled: "No pull request is being watched" |

Interactions observed:

- Click **Fix CI** on the failing thread: notice `Done: run.pr.fix_ci run-failing-ci.`; the server log shows the
  PrWatcher picked up the `PrFixRequested` and tried to read the PR (failed on the fake repo, as above).
- Click **Create PR** on the thread whose run has no pushed branch: the real `run.pr.create` path refused and
  the notice read `run.pr.create run-no-pr failed: :no_head_branch` (since reworded to a plain sentence, covered by a test).
- Accessibility tree of a card: `group "Pull request actions for <title>"` containing `button "Fix CI"`,
  `button "Address comments"`, `button "Resolve conflicts" [disabled]`, `button "Create PR" [disabled]`; each
  disabled button has `aria-describedby` pointing at the visible reason text. Disabled buttons leave the tab order,
  the reason stays readable text next to them.
- No merge or approve button exists anywhere in the page (only the existing hint text
  `operator: foreman run approve-merge/merge`).

Screenshots: `pr-actions-01-overview.png` (whole workspace), `pr-actions-02-fix-ci-clicked.png` (the CI-red card).
Not exercised: a real GitHub PR, the Address comments / Resolve conflicts clicks on the dev server (covered by the LiveView tests).
