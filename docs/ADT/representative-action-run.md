# Representative Action E2E Run (ADT-T002)

TRD: TRD-2026-4212be7e / ADT-T002 / TRD-084
Bead: foreman-0jg9
Run date: 2026-08-19
Based on: docs/ADT/representative-action.md (ADT-T001)

## Representative action
`ForemanServer.Actions.GitStatusAction` (per ADT-T001)

## E2E plan
1. Provision a tmp git repo (`git init`, configure user, add a tracked
   file, commit it).
2. Start the action in test mode by calling
   `ForemanServer.Actions.GitStatusAction.run(%{path: <tmp>}, %{})`.
3. Assert clean state — `%{porcelain: [], exit_code: 0}`.
4. Touch a new file in the tmp repo, call the action again.
5. Assert dirty state — `porcelain` includes the new untracked path.
6. Reset the tmp repo to a clean state.
7. Time the full sequence and record against the NFR-01 ≤4h budget.

## E2E test scaffold
File: `packages/foreman_server/test/foreman_server/actions/git_status_action_e2e_test.exs`
covers the clean → dirty → reset sequence described above. The scaffold
exercises `GitStatusAction.run/2` against a real (per-test, tmp) git
working tree so the Jido.Action contract is validated against actual
`git` output rather than mocks.
## Time logged
Not run in this session (sandbox lacks erlexec). Expected to pass based on code
review — `GitStatusActionE2ETest` exercises `run/2` against a real tmp git repo
and the action's `git status --porcelain` logic is straightforward. Full development
time not measured; see timing doc for rough retrospective estimate.

## Result
Not yet run this session (sandbox constraint). Expected: PASS — the test exercises
`GitStatusAction.run/2` against a real tmp git working tree (clean→dirty→reset)
and the action logic is read-only git porcelain. A CI/normal-environment run is
needed to confirm the timing measurement.
