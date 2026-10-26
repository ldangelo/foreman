# Live GitHub: workspace PR buttons, `pr_auto_fix`, a push after merge approval, and merge refusal (2026-10-23)

Evidence for the second half of `foreman-ksy0q` (the first half is `github-live-run.md`). Everything below was observed
against a **real private GitHub repository** and a real throwaway Foreman server, with real `pi` agents
(`minimax/MiniMax-M2.7-highspeed`) doing every run and fix thread. The only injected events are the ones a real project
meets from the outside: a failing commit pushed to the PR branch, a review posted with `gh api`, a conflicting commit on
`main`, an external commit status. Nothing is simulated.

## Result per item

| # | Item | Result | Evidence |
|---|---|---|---|
| 1 | Merge under GitHub **branch protection** (required check, required review, linear history) | **UNVERIFIED in this run; verified live on 2026-10-26** ([`live-github-branch-protection.md`](live-github-branch-protection.md)) | see "Item 1"; in this run protection and rulesets answered HTTP 403 on a private repo of this plan, and the pre-flip content scan for the approved temporary public window failed on the commit identities, so the repo was never made public. The scan now allows the account's own public profile identity and the stage was run |
| 1b | GitHub refuses the operator merge: text and state (repo forbids squash merges, works on a private repo) | **PASS** | 9j |
| 2a | UI **Fix CI** button on a real failing PR | **PASS** | 9c |
| 2b | UI **Address comments** button on a real unresolved review thread | **PASS** | 9d |
| 2c | UI **Resolve conflicts** button on a real merge conflict | **PASS** | 9e |
| 2d | UI **Create PR** button after the run's own PR creation failed | **PASS after fix** (defect found: the PR could not be merged) | 9g |
| 2e | No merge or approve control anywhere on the page | **PASS** | 9b, every button label on the page |
| 3a | `pr_auto_fix` disabled: a failing PR is observed and not fixed | **PASS** | 9c (150 s) and 9f (90 s) quiet windows |
| 3b | `pr_auto_fix` enabled: the failing PR is fixed automatically, once | **PASS** | 9f |
| 3c | `pr_auto_fix` bounded: an unfixable failure stops at `max_attempts` with `PrFixExhausted` | **PASS** | 9f |
| 4 | After `MergeGateApproved`, a push to the PR branch (observation only; the fix landed afterwards as #650, `foreman-ehxy6`) | **observed on the build before #650: PR stranded**. The post-#650 behaviour (approval voided, gate held again) is UNVERIFIED live | 9h |

## Environment

- Branch `feat/live-github-protection-ui-autofix` off `origin/main` `126ff019`; macOS arm64; devbox Elixir 1.20.4 / OTP 28; Playwright
  1.64.1 (headless Chromium) driving `/dashboard/projects/<id>`; `gh` token scopes `gist, read:org, repo, workflow`; `cloudflared` quick tunnel.
- Scratch repo `ldangelo/foreman-scratch-202610230729` (private, **never made public**, archived at the end). Seed:
  `scripts/e2e/claude_projects/github-fixture/` (app, unit tests, `ci.yml`) plus `approve.yml` (a manual workflow whose
  `github-actions[bot]` can approve a PR) and `.coderabbit.yaml`.
- Server: `MIX_ENV=dev`, private database, ephemeral port, redirected `HOME`; credentials only in the environment
  (`GH_TOKEN`, a `GIT_CONFIG_*` credential helper, `FOREMAN_GITHUB_WEBHOOK_SECRET=<random>`); `FOREMAN_PR_MONITOR_ENABLED=true`,
  `FOREMAN_PR_FIX_SANDBOX=host`; the review analysis is switched off (`E2E_REVIEW_ANALYSIS=0`) so no reviewer agent runs and no
  `foreman-exec` gap bead starts runs the stages do not expect.
- Driver: `scripts/e2e/github_live_extras.sh` (modes `all | serve | stage <name>... | stop`), stage library
  `scripts/e2e/claude_projects/github_extras.sh`, browser driver `scripts/e2e/ui-a11y/pr_actions_live.mjs`.

```bash
FOREMAN_E2E_GITHUB_REPO=ldangelo/foreman-scratch-<suffix> devbox run -- bash scripts/e2e/github_live_extras.sh all
# E2E_GH_ALLOW_PUBLIC=1 additionally allows the temporary public window of the protection stage
```

### Harness findings (1 may also be a product defect, filed as `foreman-v9y3x`)

1. **CodeRabbit is installed account-wide.** On the first probe PR it posted a 9.7 KB walkthrough comment and a `CodeRabbit`
   commit status that stayed `PENDING` for about 85 s. By code reading (`PrObservation.comment_ids`) the watcher counts every conversation
   comment and every status as part of the PR, so unsilenced it would make Address comments enabled on every PR and the check state
   pending: **[INFERENCE, not reproduced against an unsilenced PR; filed as `foreman-v9y3x`]**. The fixture now carries
   `.coderabbit.yaml` (`ignore_title_keywords: ["e2e-skip"]`, `review_status: false`) and every bead title starts with `e2e-skip`;
   verified: no comment, status `SUCCESS`.
2. The workspace's LiveView socket is refused from `http://127.0.0.1:<port>` (the page renders, the socket never mounts: `check_origin`
   accepts the configured host `localhost`). The browser driver uses `http://localhost:<port>`.
3. The nix `bash` that `devbox run` provides has no `compgen`; the driver lists variables with `set`.

## UI buttons on real PRs (Playwright, real browser, real GitHub)

PR #3 of the scratch repo, opened by a real run from bead `gh-vqb`. The card is `#thread-<thread id>`, the buttons are
`#pr-action-<thread id>-<kind>`; the driver reads every button and its visible reason, clicks one, reads the `#notice` status line,
and reports every button label on the page.

**9b, green PR (screenshot `live-github-ui-1-green-pr.png`).** All four buttons disabled with their visible reason:
`Fix CI` "CI is not failing.", `Address comments` "There are no unresolved review comments.", `Resolve conflicts` "The pull request has
no merge conflicts.", `Create PR` "A pull request already exists for this thread." Every button on the page: `Send | Fix CI | Address
comments | Resolve conflicts | Create PR | Library | Pull requests | Scheduled`: **no merge or approve control** (`merge_controls = []`).

**9c, Fix CI.** A failing unit test pushed to the PR branch (`e754deb5`), CI `FAILED`, card `waiting_on_you / ci_failing`
(`live-github-ui-2-fix-ci-enabled.png`: red "CI failing" line, Fix CI enabled). With the policy off nothing happened for 150 s (head still
`e754deb5`, `PrFixRequested` 0, `attempts.ci` 0, nothing in flight). Click **Fix CI**: notice `Done: run.pr.fix_ci run-be7ecd17...`;
the button immediately reads "A fix is already running for this pull request." (`live-github-ui-3-fix-ci-clicked.png`). Events:

```text
11 12:57:04 PrFixRequested head_sha=e754deb5 trigger=operator kind=ci attempt=1
12 12:57:07 PrFixStarted kind=ci attempt=1
13 12:58:24 PrUpdated head_sha=d2db2212
14 12:58:24 PrChecksChanged head_sha=d2db2212 checks_state=pending
15 12:58:27 PrFixFinished kind=ci attempt=1 outcome=pushed
16 12:58:38 PrChecksChanged head_sha=d2db2212 checks_state=passing
```
CI green on `d2db2212`, card back to Ready for review.

**9d, Address comments.** An inline review comment posted on `note_a.txt:1` (GitHub: 1 unresolved thread). Within seconds the button was enabled
(`live-github-ui-4-address-comments-enabled.png`); click: `Done: run.pr.address_comments ...`; the agent pushed `8d183573` (the file gained the
requested line), CI green. Events 17-23: `PrReviewChanged`, `PrFixRequested trigger=operator kind=comments attempt=1`, `PrFixStarted`,
`PrUpdated 8d183573`, `PrChecksChanged pending`, `PrFixFinished outcome=pushed`, `PrChecksChanged passing`.

**9e, Resolve conflicts.** A different `note_a.txt` committed to `main` (`git merge-tree` proved the conflict before pushing); GitHub
`CONFLICTING`; card `waiting_on_you / conflict`; button enabled (`live-github-ui-5-resolve-conflicts-enabled.png`); click:
`Done: run.pr.resolve_conflicts ...`; the agent pushed `dafd2650`, GitHub `MERGEABLE`, CI green. Events 24-30: `PrUpdated` (conflicted),
`PrFixRequested trigger=operator kind=conflicts`, `PrFixStarted`, `PrUpdated dafd2650`, `PrChecksChanged pending`, `PrFixFinished outcome=pushed`,
`PrChecksChanged passing`.

**9g, Create PR.** The project checkout's `origin` pointed at a nonexistent remote while the run finished, so the run's own AutoPR
failed: run `completed`, no PR, card `idle / no_pr`, Create PR enabled (`live-github-ui-6-create-pr-enabled.png`). `origin` restored,
click: `Done: run.pr.create ...`, and GitHub has the PR (#5 on the first server).

> **Defect, found live and fixed in this PR.** On the first server the PR the button opened was never put into the merge gate:
> `PrCreated` / `PrUpdated` / `PrChecksChanged` and **no `PrReady`**, card `idle / review_undetermined`, `merge_gate: none`, and
> `foreman run approve-merge` answered `HTTP 422: {"error":"{:merge_gate_not_found, :run}"}`. A PR opened from the Create PR button
> could never be merged through the operator path. `PrCreate.execute/1` now signals `run.pr.ready` exactly as `RunExecutor`/`RepoPr`
> do (deterministic command id, head commit resolved in the project checkout); a failed signal is a typed error
> (`{:pr_ready_signal_failed, reason}`), and the retry resumes the open PR. Tests (`pr_create_test.exs`, 3 new + 1 updated):
> `PrReady` names the PR/branch/head/base and the gate is `:pending`; approve + merge through the real gateway merges with
> `--match-head-commit <that head>`; a failed signal errors and the retry yields exactly one `PrReady`. **Mutation check:** with
> the signal removed 4 of the 16 tests fail (12/16 pass); restored, 16/16.
> Re-verified live on the fixed server (PR #6): `PrReady` at 13:21:38 then `PrCreated`; card `ready_for_review / pr_ready`, `merge_gate: pending`;
> `approve-merge` accepted, `merge` accepted, GitHub `MERGED`, thread `Resolved`.

## `pr_auto_fix` (9c off, 9f off -> on -> bounded), PR #4

Policy off (`.settings.pr_auto_fix` null): failing commit `1edf719b`, CI failed, card `ci_failing`; for 90 s the head stayed `1edf719b` and
`PrFixRequested` stayed 0. Then `foreman project update --pr-auto-fix '{"kinds":["ci"],"max_attempts":2,"cooldown_seconds":0}'`
(reads back normalised). The next observation requested the fix with **no operator command**:

```text
11 13:04:00 PrFixRequested head_sha=1edf719b trigger=auto kind=ci attempt=1
12 13:04:03 PrFixStarted kind=ci attempt=1
13 13:04:23 PrUpdated head_sha=e62459ca
14 13:04:23 PrChecksChanged head_sha=e62459ca checks_state=pending
15 13:04:23 PrFixFinished kind=ci attempt=1 outcome=pushed
16 13:04:33 PrChecksChanged head_sha=e62459ca checks_state=passing
```
Exactly one automatic attempt (`attempts.ci = 1`, zero `trigger=operator`). Bounded: an external commit status
`e2e/external-policy` = `failure` posted on the new head (no code change can clear it):

```text
17 13:05:03 PrChecksChanged head_sha=e62459ca checks_state=failing
18 13:05:03 PrFixRequested head_sha=e62459ca trigger=auto kind=ci attempt=2
19 13:05:04 PrFixStarted kind=ci attempt=2
20 13:05:40 PrFixFinished kind=ci attempt=2 outcome=no_change
21 13:05:40 PrFixExhausted head_sha=e62459ca kind=ci reason=max_attempts
```
`attempts.ci = 2 = max_attempts`, `exhausted.ci = e62459ca`; for the next 120 s no `PrFixRequested` and `attempts` did not grow. The policy was
cleared afterwards (`--clear pr_auto_fix`).

## A push after merge approval (9h), PR #3: observation on the build before #650 (`foreman-ehxy6`)

> **Superseded by #650 (`foreman-ehxy6`).** Everything in this section was observed on the build before #650 (`origin/main` `126ff019`).
> Since #650, `merge_approve` must name the head (`--head-sha`, read back from GitHub), a push after approval voids the approval and holds
> the gate again (`MergeGatePending`, `reason: head_moved_since_approval`), the old head is refused as a mismatch, and only a fresh approval
> naming the new head merges. `run_pr_merge_test.exs` covers that. The harness stage 9h is rewritten for it and has **not** been run live
> (the scratch repository is archived), so the new behaviour is UNVERIFIED against real GitHub.

```text
31 13:09:31 MergeGateApproved approver=e2e-operator                       # card: landing / merge_in_flight, merge_gate=approved
32 13:09:42 PrUpdated head_sha=5c96f66b                                   # operator push after approval
33 13:09:42 PrChecksChanged head_sha=5c96f66b checks_state=pending
34 13:09:56 PrChecksChanged head_sha=5c96f66b checks_state=passing
```
- **No `PrReady` and no `MergeGatePending`** after the push; the gate stays `approved`; the card still reads `landing / merge_in_flight`
  although nothing is merging and the head is no longer the approved one.
- `foreman run approve-merge` again: `HTTP 422: {"error":":merge_gate_already_approved"}`.
- `foreman run merge`: `HTTP 422: {"error":"{:head_moved_since_approval, \"dafd2650...\", \"5c96f66b...\"}"}`; the PR stays OPEN on GitHub.
- A failing push after approval moved the card to `waiting_on_you / ci_failing` (`merge_gate: approved`); operator `fix-ci` pushed `fcd49aef`
  (events 35-44: `PrFixRequested trigger=operator attempt=2` ... `PrFixFinished outcome=pushed`, `PrChecksChanged passing`): again no
  `PrReady`; `approve-merge` still `merge_gate_already_approved`, `merge` still `head_moved_since_approval` against the original pin `dafd2650`.
- `foreman run retry-pr` needs `--repo-id` (multi-repo runs only): not a recovery path for a single-repository run.
- **Net, on that build: the PR was stranded.** No operator verb re-opened the gate; the only exit was merging outside Foreman or opening a new PR.

## Operator merge when GitHub refuses it (9j, PR #10)

Branch protection is not available here (Item 1). A repository setting that private repos do have is the allowed merge methods;
Foreman only ever runs `gh pr merge --squash --match-head-commit <sha>`. With squash disabled:

```text
foreman: HTTP 422: {"error":"{:gh_merge_failed, 1, \"GraphQL: Squash merges are not allowed on this repository. (mergePullRequest)\"}"}
GitHub: state=OPEN mergeable=MERGEABLE mergeStateStatus=CLEAN
```
GitHub's own text reaches the operator verbatim (inside an inspected Elixir tuple, the convention of every operator command error); no
`PrMerged` was recorded, the gate stayed `approved`, and after squash was allowed again the same approval and head pin merged the PR (`PrMerged`).

## Item 1: merge under branch protection: UNVERIFIED in this run, and why

> **Superseded 2026-10-26 (`foreman-ksy0q` closed).** The identity allowlist of the scan was fixed (the authenticated account's own public profile identity, derived from `gh api user`,
> may appear in commit author and committer fields; everything else stays rejected, proved by `scripts/e2e/claude_projects/github_scan_proof.sh`) and `stage protection` was run in a
> temporary public window of a new scratch repository: refusal text verbatim under unmet rules, then the merge once every rule was met. See
> [`live-github-branch-protection.md`](live-github-branch-protection.md). What follows is the record of the 2026-10-23 run.

- On the private scratch repo both `PUT /branches/main/protection` and `POST /rulesets` answer **HTTP 403 "Upgrade to GitHub Pro or make this
  repository public"**.
- The operator approved a temporary public window for this one repo, conditional on a content scan of the whole repository. The scan
  (`gh_public_safety_check`, stage `safety`) reads **every branch and every `refs/pull/*` ref** (6 branches, 12 PR refs, 26 commits), every
  path ever committed, the whole `git log --all -p`, PR/review/comment text, check output and statuses, 43 Actions logs and the repository
  metadata, for tokens, `FOREMAN_*` dumps, transcripts, local paths, this run's exact secrets and the operator's real git identity. It proves each class
  can match a planted value before it reports clean. Result: no token, no `FOREMAN_*` dump, no transcript, no local path, all 15 paths ever
  committed are fixture/note files, **but the history contains a real identity**: the squash commit GitHub made when the operator merge
  of the Create PR verification PR (#6) landed is attributed to the merging account's real name and profile email, plus `Foreman <foreman@localhost>`
  from run commits. A squash merge always carries the merger's identity, so any merge in a public window would publish it and the PR
  keeps the merge sha. **The repository was therefore not flipped and stayed PRIVATE throughout** (`gh repo view --json visibility` -> `PRIVATE`
  at the end). The protection stage (`protection`, three PRs prepared while private) is implemented and guarded by `E2E_GH_ALLOW_PUBLIC=1` plus the same scan; it
  has not been run.
- To finish item 1 an operator must either accept that identity in a scratch repo, or use a repository on a plan that supports protection
  (a public repo whose first operator merge happens inside the window, or a Pro/Team private repo).

## Bead status

`foreman-ksy0q`: items 2 and 3 and the refusal path (1b) are verified live, and item 4 was observed live on the build before #650 (the fix is not re-run live); item 1 (merge under real branch protection) is not verified, so the bead stays open.

**Update 2026-10-26:** item 1 was verified live on a new scratch repository (`live-github-branch-protection.md`: refusals verbatim under a missing required review, an absent and a failing required status check and a forbidden squash, then the same approval and head pin merging once every rule was met; linear history held); the bead is closed.
