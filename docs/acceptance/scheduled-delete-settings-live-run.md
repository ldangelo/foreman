# Scheduled-tab Delete confirm and Settings editors, real Chromium (foreman-l2ab7)

Date: 2026-10-30. Audit rows C9, C1. Harness: `devbox run -- bash scripts/e2e/scheduled_tab_flow.sh`
(throwaway server, private database/port, headless Chromium via `scripts/e2e/scheduled_tab_ui.mjs` and
`scripts/e2e/settings_page_ui.mjs`). Result of the full run (including the 2-slot ticker wait): **passed=87 failed=0 unverified=0, wall 631 s**.
Screenshots: `docs/acceptance/l2ab7-shots/`.

## Scheduled tab (acceptance 1)
- Four schedules (`interval-6h`, `yearly-cron`, `tick-5m`, `skipconfirm-probe`) plus a second project with `other-keep`.
- Delete on `interval-6h` shows only that row's `Confirm delete <name>` + `Cancel` (its Delete button gone, other rows keep Delete); API and
  `foreman project schedule list` still list everything; Cancel restores Delete (`scheduled-tab-delete-confirm.png`).
- Delete -> Confirm on an active schedule (`tick-5m`) and on a paused one (`yearly-cron`) removes the row; API and CLI report it deleted.
- Another project's schedules unchanged (snapshot compare); only `interval-6h` is left, active.
- Ticker: after 2 slots (5 min each) of the deleted `tick-5m`, zero threads started. Caveat: there is no positive control (no schedule is
  allowed to fire, since a firing starts a pi agent), so this proves absence of a fire, not a live ticker.
- **Negative control**: `--skip-confirm-probe` simulates a build that deletes on the first click (the delete is sent through the CLI right after
  the Delete click) and runs the same confirm-step check; the check fails (no Confirm button, schedule already gone) and the flow counts that as the pass.
  It is a simulation of a confirm-less build, not a patched server.

## Settings page (acceptance 2)
- Repo allowlist: `relative/dir` refused with the field error, nothing persisted; `/tmp/foreman-l2ab7-allowed` saves.
- Max repositories per run: 0 and 1001 each refused with the field error; 3 saves.
- Notification preference `every_turn` and the setup script save; reload shows all four persisted values; `foreman project settings` and
  `project setup-script show` agree.
- Proposal card: seeded without a model turn (`scripts/e2e/claude_projects/seed_proposal.exs`); Decline -> card shows `(closed)` with no buttons, task projection closed.
  The proposal is a seeded `propose_threads` action, not one produced by a live coordinator turn.

Not done: axe/keyboard check of the new Confirm/Cancel buttons (optional).
