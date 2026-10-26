# Live GitHub: operator merge under real branch protection (2026-10-26)

Evidence for the last open item of `foreman-ksy0q` (the other items are in `github-live-run.md` and
`live-github-protection-ui-autofix.md`, where this one was UNVERIFIED). Everything below was observed against a **real GitHub
repository** with a real throwaway Foreman server and real `pi` agents (`minimax/MiniMax-M2.7-highspeed`) doing every run; the only
injected events are the ones a real project meets from the outside (a commit status from an external check, a review from a second
identity). Nothing is simulated.

Branch protection answers HTTP 403 on a private repository of a free plan, so the scratch repository was **public for two short
windows** (the first aborted by a harness defect, below), after a whole-history content scan that passed on the real repository.

## Result

| # | Item | Result |
|---|---|---|
| 1 | Operator merge **refused** while the required review is missing (`enforce_admins` false, then true): text reaches the operator verbatim, PR stays OPEN, no `PrMerged`, gate stays approved | **PASS** (M1, M2) |
| 2 | The same approval and head pin **merges** once the required review exists (a `github-actions[bot]` approval counts) | **PASS** (M2, PR #2) |
| 3 | Refused while the required status check `e2e/external-policy` is **absent**, and while it is **failing**; merged once it is green | **PASS** (M3, PR #4) |
| 4 | Refused while the repository forbids the only method Foreman uses (squash), under protection; merged once allowed again | **PASS** (M3) |
| 5 | **Linear history**: the commit each protected merge landed on `main` has exactly one parent, and `main` has no merge commit | **PASS** |
| 6 | The pre-flip content scan passes on the real repository with the account's own public profile identity allowed in commit identity fields, and still fails on everything else (mutation proof, 50 expectations) | **PASS** |
| 7 | The repository is PRIVATE again (and archived), protection removed, no webhook, no leftover process, port, database or directory | **PASS** |

`stage protection`: passed=28 failed=0 unverified=0 (119 s). `stage merge_refusal`: 9 PASS, `stage prot_prepare`: 12 PASS, `stage safety`: 8 PASS.

## Environment

- Branch `foreman/ksy0q-protection-live` off `main` `a934a19a`; the first protection run used commit `1dffdaff`, the successful one `4e809816`
  (harness changes only: `scripts/e2e/claude_projects/github_extras.sh`, `scripts/e2e/github_live_extras.sh`, new
  `scripts/e2e/claude_projects/github_scan_proof.sh`). macOS arm64; devbox Elixir 1.20.4 / OTP 28; `gh` 2.103.2, token scopes
  `delete_repo, gist, read:org, repo, workflow` (no `user` scope, so `gh api user` reads only the public profile); `cloudflared` quick tunnel.
- Scratch repository `ldangelo/foreman-scratch-202610261153`, created PRIVATE at 2026-10-26T16:53:45Z by `gh repo create --private` (no README, license
  or `.gitignore` template: those would be GitHub-authored commits), then seeded with one commit by `seed <seed@example.com>` holding
  `scripts/e2e/claude_projects/github-fixture/` (app, unit tests, `ci.yml`, `approve.yml`, `.coderabbit.yaml`). One repository setting was changed so that
  `approve.yml` can give a second identity's review: `PUT /actions/permissions/workflow` with `can_approve_pull_request_reviews=true`.
- Server: `MIX_ENV=dev`, private database `foreman_e2e_claude_projects_gx`, ports 4810/4910, redirected `HOME`; credentials only in the environment;
  `FOREMAN_PR_MONITOR_ENABLED=true`; a real webhook through a `cloudflared` tunnel (registered on the repository, bad signature 401, valid ping 202).
- Every PR was opened by a real Foreman run (AutoPR) from a bead; the operator verbs are the real CLI: `foreman run approve-merge --id ... --head-sha <head read back
  from GitHub>` and `foreman run merge --id ...`. Foreman's merge is `gh pr merge <pr> --squash --match-head-commit <approved head>`
  (`packages/foreman_server/lib/foreman_server/github/pr_merge.ex:40`): never `--admin`, never `--auto`.

```bash
# scratch repo (the harness never creates one): private, seeded with a synthetic identity
gh repo create ldangelo/foreman-scratch-202610261153 --private --description "Foreman live-acceptance scratch repository (synthetic fixture, safe to delete)"
#   git init; cp -R scripts/e2e/claude_projects/github-fixture/. .; commit as seed <seed@example.com>; push main (credential helper: gh)
gh api -X PUT repos/ldangelo/foreman-scratch-202610261153/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true

FOREMAN_E2E_GITHUB_REPO=ldangelo/foreman-scratch-202610261153 devbox run -- bash scripts/e2e/github_live_extras.sh serve      # the stack, kept up
FOREMAN_E2E_GITHUB_REPO=... devbox run -- bash scripts/e2e/github_live_extras.sh stage merge_refusal     # PR #1: a merged PR for the scan to see
E2E_GH_ALLOW_PUBLIC=1 FOREMAN_E2E_GITHUB_REPO=... devbox run -- bash scripts/e2e/github_live_extras.sh stage prot_prepare   # PRs #2 #3 #4, green, Ready for review
FOREMAN_E2E_GITHUB_REPO=... devbox run -- bash scripts/e2e/github_live_extras.sh stage safety            # the scan alone (read-only)
E2E_GH_ALLOW_PUBLIC=1 FOREMAN_E2E_GITHUB_REPO=... devbox run -- bash scripts/e2e/github_live_extras.sh stage protection     # the public window
FOREMAN_E2E_GITHUB_REPO=... devbox run -- bash scripts/e2e/github_live_extras.sh stop                     # tear everything down
gh repo archive ldangelo/foreman-scratch-202610261153 --yes
```

## Timeline (UTC)

| Time | Event |
|---|---|
| 16:53:45 | scratch repository created, PRIVATE; seeded 16:54 |
| 16:57:08-16:57:45 | `merge_refusal`: PR #1 opened by a run, `approve-merge`, squash disabled -> refusal, squash allowed -> merged (a real GitHub squash commit in `main`) |
| 16:58:45-16:59:56 | `prot_prepare`: PRs #2, #3, #4 opened by runs, CI green, Ready for review, gate pending |
| ~17:00 | `safety`: the scan on the real repository passes (below) |
| **17:02:13** | **window 1 starts** (`stage protection`: scan passed again, repository made PUBLIC) |
| 17:02:17 | protection PUT refused (`Repository has been locked.`), unflip refused (`A previous visibility change is still in progress`): stage fails |
| **17:02:51** | **window 1 ends**: set PRIVATE by hand on the first try (38 s public; no protection had been applied and nothing merged in it) |
| 17:04:32-17:04:43 | `approve.yml` dispatched on PR #4 while PRIVATE, to check the second identity works before the next window: `github-actions[bot]` APPROVED |
| 17:07:54 | harness fixed and committed (`4e809816`): lock-aware retries, exit trap |
| **17:08:24** | **window 2 starts** (scan passed again, PUBLIC) |
| 17:08:27 | protection accepted (the repository was still locked for 3 s) |
| 17:08:33-17:08:59 | M1, M2: refusals, bot approval, PR #2 merged (17:08:59) |
| 17:09:12-17:09:53 | M3: bot approval, refusals, PR #4 merged (17:09:53) |
| 17:09:57 | protection deleted, merge methods restored, unflip asked; **17:09:58 window 2 ends** (PRIVATE; 94 s public) |
| 17:11-17:12 | `stop`: webhook deleted, tunnel, server, database, work directory removed; at 17:12:02 `main` was restored to the seed commit and the run branches deleted (PR #3, prepared and never used, closed by that) |
| 17:12:49 | repository archived (`gh repo view --json archivedAt`), PRIVATE |

Total time public: 132 s (38 s + 94 s).

## What was set

Classic branch protection on `main` (applied in window 2, deleted before the repository went private again):

```json
{"required_status_checks":{"strict":false,"contexts":["test","e2e/external-policy"]},
 "enforce_admins":false,
 "required_pull_request_reviews":{"required_approving_review_count":1},
 "restrictions":null,
 "required_linear_history":true}
```

read back as `{"contexts":["test","e2e/external-policy"],"strict":false,"reviews":1,"linear_history":true,"enforce_admins":false}`, and with
`POST .../protection/enforce_admins` as `"enforce_admins":true` for M2 and M3. `test` is the CI check of the fixture; `e2e/external-policy` is a commit
status posted with `gh api -X POST repos/<repo>/statuses/<sha>` (state `success`, `failure`; absent = never posted). The token is the repository owner, so it is an admin.

## The refusals, verbatim (what `foreman run merge` printed to the operator)

Each one: HTTP 422 from the Foreman API, rc 1, the PR still `OPEN`. The first four are `gh pr merge`'s own wording (both sentences are strings in the `gh` 2.103.2 binary)
for GitHub's `mergeStateStatus: BLOCKED` (the base branch policy); the last is GitHub's own GraphQL error. Foreman passes either through unchanged, inside the inspected
`{:gh_merge_failed, status, text}` tuple every operator command error uses.

**M1, no review, admins not enforced** (PR #2; GitHub: `mergeable=MERGEABLE mergeStateStatus=BLOCKED reviewDecision=REVIEW_REQUIRED`):

```text
foreman: HTTP 422: {"error":"{:gh_merge_failed, 1, \"X Pull request ldangelo/foreman-scratch-202610261153#2 is not mergeable: the base branch policy prohibits the merge.\\nTo have the pull request merged after all the requirements have been met, add the `--auto` flag.\\nTo use administrator privileges to immediately merge the pull request, add the `--admin` flag.\"}"}
```

**M2, no review, admins enforced** (same PR, same text; `enforce_admins` true, `reviewDecision=REVIEW_REQUIRED`): identical output to M1.

**M3, required status `e2e/external-policy` absent** (PR #4, approved by the bot, `reviewDecision=APPROVED mergeStateStatus=BLOCKED`) and **failing** (same state):

```text
foreman: HTTP 422: {"error":"{:gh_merge_failed, 1, \"X Pull request ldangelo/foreman-scratch-202610261153#4 is not mergeable: the base branch policy prohibits the merge.\\nTo have the pull request merged after all the requirements have been met, add the `--auto` flag.\\nTo use administrator privileges to immediately merge the pull request, add the `--admin` flag.\"}"}
```

**M3, status green, review in place, the repository forbids squash merges** (`mergeStateStatus=CLEAN`, protection still on):

```text
foreman: HTTP 422: {"error":"{:gh_merge_failed, 1, \"GraphQL: Squash merges are not allowed on this repository. (mergePullRequest)\"}"}
```

Note M1: with `enforce_admins` false an admin can override the policy with `gh pr merge --admin` (not exercised). Foreman never passes `--admin`, so the owner's token is
refused exactly like anyone else.

## The merges once every rule was met

- **M2, PR #2**: after the refusals, `foreman run approve-merge` was **not** repeated. `github-actions[bot]` approved (workflow dispatch of `approve.yml`, run 40365855379,
  success; the fixture has this workflow because GitHub does not let an author approve their own PR): GitHub `reviewDecision` went `REVIEW_REQUIRED` -> `APPROVED` (the bot's
  review counts toward the one required review). The same `foreman run merge --id run-8f66...` then answered `{"result": {...}, "status": "accepted"}` and GitHub reported
  `state=MERGED` (merged 17:08:59). The commit on `main`: **1 parent**; author the account's public profile identity, committer `GitHub <noreply@github.com>`, message ending
  `Co-authored-by: Foreman <foreman@localhost>`.
- **M3, PR #4**: status posted `success`, squash allowed again, the same approval merged it (`state=MERGED`, 17:09:53), again one parent and the same author, committer and trailer.

`main` after the stage (`gh api repos/.../commits?sha=main`, read before teardown): four commits, each with 1 parent except the seed (0): the seed commit, PR #1 (merged before protection) and PRs #2 and #4; the stage also asserted
`git rev-list --merges origin/main` = 0.

## The gate stayed approved (event store, read before teardown)

`MergeGateApproved` is recorded once per run and nothing re-holds it between the refusals and the merge, so the same approval and head pin did the merge:

```text
run-8f66... (PR #2)  7 17:08:33 MergeGateApproved head_sha=49804e0c approver=e2e-operator       <- M1 approve; M1 and M2 refusals record no event
                     8 17:08:53 PrReviewChanged head_sha=49804e0c review_decision=approved      <- the bot's review observed
                     9 17:09:01 PrMerged head_sha=49804e0c
run-3f5d... (PR #4)  8 17:09:23 MergeGateApproved head_sha=d9f1c92b approver=e2e-operator       <- M3 approve; three refusals record no event
                     9 17:09:54 PrMerged head_sha=d9f1c92b
```

## The content scan before the flip (`gh_public_safety_check`)

It reads every branch and every `refs/pull/*` ref of the repository, every path ever committed, file contents at every commit, the whole patch history, commit identities,
PR/review/comment text, check output and statuses, every Actions log and the repository metadata, for tokens, `FOREMAN_*` dumps, transcripts, local paths and this run's exact
secrets. The first protection attempt of 2026-10-23 stopped here because GitHub attributes the squash commit and the `refs/pull/*/merge` commit to the PR author and the
phase commits carry `Foreman <foreman@localhost>`. What changed (harness only, `github_extras.sh`): a commit author or committer may be, as a whole line,

- synthetic (`<local>@example.com`), `GitHub <noreply@github.com>`, `Foreman <foreman@localhost>` (`Jobsite.Git.commit_all`'s default), or
- the authenticated account's own **public profile identity**, derived at run time from `gh api user` (name and email, only when the profile publishes an email; with no
  public email the account identity is rejected too). It is already on the profile, so naming it in a commit exposes nothing new.

Everything else stays rejected, and the profile email stays an exact secret everywhere except the identity fields of commits: the patch history is scanned without author/committer
lines, and the identity lines are scanned as free text after taking out that one allowed line.

Result on the real repository: `stage safety` (read-only, before any window: 10 Actions logs, 147677 bytes, PR text 1102 bytes, every other line identical) and the scan inside `stage protection`
immediately before window 2, which is shown (one more Actions log after the `approve.yml` dry run):

```text
refs scanned: 6 branch(es), 7 pull request ref(s): origin/HEAD origin/foreman/gh-5iv/... origin/foreman/gh-dht/... origin/foreman/gh-rne/... origin/foreman/gh-ymo/... origin/main pull/1/head pull/2/head pull/2/merge pull/3/head pull/3/merge pull/4/head pull/4/merge
paths ever committed on any ref: .coderabbit.yaml .github/workflows/approve.yml .github/workflows/ci.yml .gitignore README.md app.py note_p1.txt note_p2.txt note_p3.txt note_p4.txt test_app.py
PASS  every path ever committed (11 distinct) is part of the synthetic fixture
PASS  no token, FOREMAN_* dump, transcript or local path in the contents of any file at any of 9 commit(s) on any ref
PASS  the whole patch history (6356 bytes) is clean
commit identities: Foreman <foreman@localhost>;GitHub <noreply@github.com>;<account profile identity>;seed <seed@example.com>;
PASS  every commit author and committer is synthetic (@example.com), GitHub's own, Foreman's phase-commit default or the account's own public profile identity
PASS  no token, local path, FOREMAN_* dump, transcript line or exact secret in any commit author or committer
PASS  PR titles, bodies, comments, reviews, check output, statuses and repository metadata are clean (1163 bytes)
PASS  11 Actions run log(s) are clean (150892 bytes; the GitHub runner's own /home/runner paths excluded)
PASS  the scan patterns detect a planted token, local path, FOREMAN_* dump, transcript line and foreign commit identity (the scan can fail)
```

Objects created inside a window (the squash commits, the bot's review text, the statuses, the CI logs of the merges) were not scanned beforehand; they carry the same fixed content:
the account's profile identity as author, GitHub as committer, `Foreman <foreman@localhost>` as co-author, the bot review body `approved by the e2e harness (github-actions[bot])`,
`e2e external check: <state>` statuses.

### Mutation proof (`scripts/e2e/claude_projects/github_scan_proof.sh`, local only)

It builds a local bare origin shaped like the scratch repository (seed commit, a Foreman run commit, a squash commit and a `refs/pull/1/merge` commit attributed to the account and
committed by GitHub, `refs/pull/1/head`), runs the real `gh_public_scan_history` on it, plants one violation at a time into a fresh copy, and runs the clean history again. Nothing is
pushed to GitHub; the only network call is the scan's own read-only `gh api user`. The account's real name and email are masked in the output (`<account identity>`).
`bash scripts/e2e/claude_projects/github_scan_proof.sh` ends `expectations held: 50, broken: 0`:

```text
A0  clean history (the account identity as author of the squash and the merge commit)   scan PASSED
A1  (i) token-shaped string in a file            FAIL  the TOKEN class matches file contents in the history (rev:path): <sha>:app.py
A2  (i) token-shaped string in a commit message  FAIL  git log --all -p: the TOKEN class matches (lines: 2 of history-all.patch)
A3  (i) token-shaped string as an author name    FAIL  commit identities: the TOKEN class matches (lines: 2 of identities-scan.txt)
A4  (i) this run's webhook secret in a file      FAIL  an exact secret or identity of this run appears in file contents (rev:path): <sha>:note_p9.txt
A5  (ii) commit by Someone Else <someone@corp.test>                FAIL  commit identity outside the allowlist in the history: Someone Else <someone@corp.test>
A6  (ii) the same identity, reachable only from refs/pull/9/head   FAIL  commit identity outside the allowlist in the history: Someone Else <someone@corp.test>
A7  (iii) /Users/jdoe/... in a file             FAIL  the PATH class matches file contents in the history (rev:path): <sha>:note_p9.txt
A8  FOREMAN_API_TOKEN=... in a file              FAIL  the ENV class matches file contents in the history (rev:path): <sha>:note_p9.txt
A9  {"role": "assistant", ...} in a file         FAIL  the TRANSCRIPT class matches file contents in the history (rev:path): <sha>:note_p9.txt
A10 a path outside the fixture (secrets.env)     FAIL  paths outside the synthetic fixture in the history: secrets.env
A11 the account's email in a file                FAIL  an exact secret or identity of this run appears in file contents (rev:path): <sha>:note_p9.txt
A12 the account identity in a commit message     FAIL  git log --all -p: an exact secret or identity of this run appears in history-all.patch
A13 the operator's local git name + profile email as author   FAIL  commit identity outside the allowlist in the history: <operator git name> <<account email>>
A-hidden the clean history, profile with no public email      FAIL  commit identity outside the allowlist in the history: <account identity>
A-clean-again the clean history once more                     scan PASSED
```

Also in the script: B, 23 identity lines one by one (6 accepted: the synthetic forms, `GitHub`, `Foreman`, the account identity; 17 rejected: `foreman <foreman@localhost>`,
`Foreman <foreman@localhost.corp.test>`, `github <noreply@github.com>`, `x <x@notexample.com>`, `x <x@evil.example.com>`, `x <a@b@example.com>`, `Evil <e@corp.test> <a@example.com>`,
the account identity with a prefix or a suffix, the operator's local git name with the profile email, and the account identity when the profile publishes no email, among
others); C, `gh_account_identity` against a faked `gh api user` (name and email -> identity; email null, name null, empty strings, an error object, `gh` failing -> nothing); D,
`gh_retry_locked` (below).

**The proof itself can fail.** Seven sabotaged copies of `github_extras.sh` (a throwaway harness, not committed; run on the 45-expectation version of the proof, before section D existed)
each make the proof exit 3 on the expectations that guard that line:

| Sabotage | Proof expectations that broke |
|---|---|
| the identity allowlist accepts everything | A5, A6, A13, A-hidden and 17 allowlist rows (21 broken) |
| `refs/pull/*` no longer fetched | A6 |
| identity fields no longer scanned as free text | A3 |
| the patch history (messages) no longer scanned | A2, A12 |
| the profile email no longer an exact secret | A11, A12 |
| the `example.com` rule loosened to an unanchored local part | the `a@b@example.com` and `Evil <e@corp.test> <a@example.com>` rows |
| the TOKEN class dropped | A1, A2, A3 |

## Defect found live and fixed: GitHub locks the repository while a visibility change is processed

The first run of `stage protection` (window 1) failed right after the flip:

```text
flip at 2026-10-26T17:02:13Z: gh repo view --json visibility -> PUBLIC
FAIL  applying protection failed: {"message":"Repository has been locked.","documentation_url":"https://docs.github.com/rest/branches/branch-protection#update-branch-protection","status":"403"}gh: Repository has been locked. (HTTP 403)
unflip at 2026-10-26T17:02:17Z: gh repo view --json visibility -> PUBLIC
WARNING     ldangelo/foreman-scratch-202610261153 is still PUBLIC: set it private by hand NOW
visibility-private.out: HTTP 422: Failed to update visibility. A previous visibility change is still in progress. (https://api.github.com/repos/ldangelo/foreman-scratch-202610261153)
```

`gh repo edit --visibility` answers at once and `gh repo view` shows the new value, but the repository is locked for a few seconds: writes answer HTTP 403 `Repository has been
locked.` and another visibility change HTTP 422. The unflip, attempted once 4 s later, left the repository PUBLIC until it was set private by hand (38 s public; no protection
applied, nothing merged in it). Fix (`4e809816`, harness only): `gh_retry_locked` retries exactly those two refusals (never another error) for up to `E2E_GH_LOCK_SECS` (default
240 s) around the visibility change and the protection PUT, the unflip waits for the read-back, and a `stage` process now has an exit trap (INT, TERM and HUP included) that runs
the same unwind as the serve process when the repository is left flipped or protected. In window 2 the protection PUT was accepted after 3 s (`(the repository was still locked by
the visibility change: the protection was accepted after 3s)`) and the unflip was accepted within a second. GraphQL `Repository.isLocked` exists and read `false` outside the lock.
`github_scan_proof.sh` section D proves the retry is limited to the two refusals (two 403s then accepted; one 422 then accepted; `HTTP 404` not retried; a lock longer than the cap
gives up and the caller warns).

## Teardown (verified after `stop`, before archiving)

`gh repo view --json visibility` PRIVATE; `gh api repos/.../hooks` empty (the webhook was deleted); merge methods `squash, merge, rebase` all allowed again; branch protection deleted
inside window 2 (`branch protection removed from main`; it cannot be read back on a private repository of this plan); `main` restored to the seed commit and the run branches deleted
(PR #3, prepared and never used, was closed by that); no `cloudflared`, nothing listening on 4810/4910, no `foreman_e2e*` database, `tmp/e2e-claude-projects-gx` removed. The
evidence directory (it holds this run's secrets list) was removed after this write-up, and the repository was then **archived** (PRIVATE, archived at 2026-10-26T17:12:49Z).

## Limitations

- Classic branch protection only. Repository rulesets, merge queues, CODEOWNERS, "dismiss stale reviews" and "require conversation resolution" were not exercised.
- The second approving identity is `github-actions[bot]` (workflow dispatch of `approve.yml`, needs the repository setting "Allow GitHub Actions to create and approve pull requests"),
  not a human collaborator. GitHub counted it toward the single required review.
- The required status that was refused was the external commit status `e2e/external-policy` (absent, failing). The CI check `test` was required and green throughout; a failing `test`
  under protection was not run here (a failing check is the PR watcher's `ci_failing` / Fix CI path, `live-github-protection-ui-autofix.md`). `strict` ("up to date before merging") was off.
- Linear history held (one-parent commits, no merge commit) because Foreman only squashes; no merge-commit merge was attempted, so a refusal caused by `required_linear_history` itself was
  not observed. Refusing a squash because the repository forbids squash merges was (M3).
- The refusal text for a BLOCKED PR is the `gh` CLI's, not a GitHub API message; another `gh` version may word it differently. Foreman passes it through inside the
  inspected `{:gh_merge_failed, status, text}` tuple like every operator command error.
- A single repository on a free personal plan. Per GitHub's own 403 ("Upgrade to GitHub Pro or make this repository public") a paid private repository would not have needed a public window.
- Foreman needed no change: the refusals are passed through and the gate holds. Every defect met was in the harness (the identity allowlist; the visibility lock, found live;
  and, found by reading the code while fixing that, a `stage` process killed inside the window did not unwind it); nothing here was run by CI.

## Bead status

`foreman-ksy0q`: item 1 (merge under real branch protection: required status check, required review, linear history) is verified live above, with the refusal text verbatim and the
same approval and head pin merging once every rule was met. Items 1b, 2, 3 and 4 were already recorded (`live-github-protection-ui-autofix.md`). The bead is closed.
