# Multi-repo live end-to-end run (E12-S12), 2026-10-21

Evidence for flipping the run-start gate (`config :foreman_server, :multi_repo, runs`) to open.
Harness: `scripts/e2e/multi_repo.sh` (POSIX sh, assets in `scripts/e2e/multi_repo/`).

## What ran

| | |
|---|---|
| Real | git; a Foreman server booted from `MIX_ENV=dev` on a private port with its own Postgres database (`foreman_e12_live`, dropped at the end); the Go CLI (`foreman run get/approve-merge/merge/retry-pr/submit`, `project repo add`); the **real agent: `pi` 1.3.0 with `minimax/MiniMax-M2.7-highspeed`** (a private pi agent dir holding only the operator's `auth.json`/`models.json`, so no user extensions or MCP servers load) |
| Stubbed | GitHub only: a recording fake `gh` (`scripts/e2e/multi_repo/fake-gh`) implements what Foreman calls (`pr create/view/edit/merge`, `api graphql`), and every remote is a local bare repository. `pr merge` flips the fake PR to MERGED; it does not touch the bare origin's `main` |
| Gate | opened for the live node by a runtime override in `boot.exs` (`Application.put_env`), then closed/reopened at runtime by the `gate` stage. The committed default was `false` while this ran; it was flipped afterwards in the same story |
| Stages | `gate green gates failure legacy` plus the closing `strays` check |
| Result | **110 assertions passed, 0 failed, exit 0, 127 s** (final run; the two earlier runs are described under "Defects") |

Scenario of the `green` stage: ONE `task.create` with `repo_ids: ["b"]` over project primary `a` (repository id `main`)
and attached repository `b`; the workflow (`cleanup: on_success`, one phase, `commit: true`) tells the agent to create
`VERSION` containing `1.4.2` in every repository listed in the `{{repositories}}` assign.

What the assertions establish (all against the live run):

* **Worktrees**: two projections, `wt-<run>` (no `repo_id`) at `<run>/workspace` and `wt-<run>-b` (`repo_id: b`) at
  `<run>/repos/b`; both registered in their own repository while the run was live; reclaimed by `cleanup: on_success`.
* **Sibling-path edit**: `VERSION` is committed in **b** as well as in a. The agent's own pi session file shows the tool
  call (`printf ... > <primary>/VERSION && printf ... > <run>/repos/b/VERSION`): pi has no `add_dirs`, so it used the
  absolute path from the prompt's `{{repositories}}` JSON. Foreman committed both worktrees at phase end
  (`Foreman run <run> phase 1` in each repository).
* **Branches/PRs**: the same branch name pushed to both bare origins; two `gh pr create` calls, each from its own
  repository's checkout; `pr_associations_for_run` = 2; `run.pr_url` stays the primary's, `run.pr_urls.b` is b's;
  sibling cross-links in both PR bodies; `GET /api/runs/:id/prs` lists both.
* **Events**: `repo_id` appears on exactly six events (`WorktreeCreated`, `WorktreeCleaned`, `RunBaseBranchRecorded`,
  `PrAssociated`, `PrReady`, `PrUpdated`), once each, all b's; no event of the primary and no event of the legacy run
  carries `repo_id`/`repo_ids`, not even as `nil`.
* **Archive**: `diff.patch` (a), `diffs/b.patch`, `diffs/b.files.txt`, and `manifest.repositories[]` = `main`, `b` with
  their PR URLs; repo b has nothing written outside its run worktree.
* **Per-repo merge gate** (`gates` stage): both gates `pending`; `merge_approve` for a only makes a `approved` and leaves b
  `pending`; `run merge --repo-id b` is **refused** (`HTTP 422 :pr_not_acceptable`) and no `gh pr merge` happens; a merges
  pinned to its own head; after approving b it merges pinned to b's head.
* **Failure injection** (`failure` stage): `chmod -R a-w` on b's bare origin. The run still **completes**; a has its PR;
  b is `create_failed` (`{:git_push_failed, 1, "error: remote unpack failed: unable to create temporary object
  directory ..."}`), `completed_with_errors` is true, b's branch is not on its origin, **b's worktree is kept while a's is
  reclaimed**. After `chmod -R u+rwx`, `foreman run retry-pr --id <run> --repo-id b` pushes b, opens b's PR, leaves a's PR
  and branch untouched, clears `completed_with_errors` and reclaims b's worktree.
* **Legacy** (`legacy` stage): a single-repository project that never saw `repo add`, same server, `foreman run submit`
  without repo flags: one worktree (`wt-<run>`), one PR, one association, no `repos/` anything, no `diffs/` directory and no
  `repositories` key in its archive manifest, no `repo_id`/`repo_ids` in any event or in the run projection.
* **Gate refusal** (`gate` stage): with the gate closed on the live node a task with `repo_ids` is accepted at creation but
  the run fails at start with `multi_repo_runs_disabled` and provisions no worktree.
* **Strays**: afterwards each repository has only its main checkout registered as a worktree, no run worktree directory is
  left under `~/.foreman/worktrees/<project>`, and the fake gh saw no unsupported invocation.

## Defects found by running it for real (and fixed)

1. **`GET /api/runs/:id` and `GET /api/runs` answered 500 for every run that recorded usage.** `RunController.stringify_keys/1`
   enumerated the run's `%ForemanServer.Usage{}` (`Protocol.UndefinedError: Enumerable not implemented for
   ForemanServer.Usage`). On `origin/main` since the usage projection (E0), hidden because the existing tests seed runs
   without usage. First live run: the agent finished, both PRs were opened, but `foreman run get` could not read the run, so
   the harness timed out after 604 s. Fix: structs are passed through to Jason. Regression test
   `test/foreman_server_web/controllers/run_controller_test.exs` (2 tests; removing the fix fails both). The sibling
   controllers carry the same private helper and were left untouched.
2. Harness bug (second live run: 108 passed, 1 failed): counted two lines per registered worktree in `git worktree list
   --porcelain`. Fixed in the harness.
3. Stale test: `RepoIdReplayTest` used `RunRepoPrFailed` as its "unknown event" although the Run aggregate has folded it since
   E12-S6; it now uses a genuinely unknown type.

## Not covered / unverified

* `E2E_GITHUB=1` (two real private GitHub repositories) is **not implemented**: the harness refuses it. Real `gh`/GitHub
  behaviour (PR creation, mergeability, branch protection) is exactly what the fake replaces.
* Only `pi` + MiniMax was run. `E2E_PROVIDER` is passed straight to the workflow manifest; other providers were not tried.
* The env contract (`FOREMAN_REPOS`, `FOREMAN_REPO_<ID>_WORKTREE`) is covered by unit tests; this run proves only that the
  agent can reach b through the path in its prompt, not what its environment contained.
* Jobsite multi-repo, per-phase repository selection and thread-requested attachment (`run.repo.request`) are not part of
  this run.

## How to run it

```
devbox run -- sh scripts/e2e/multi_repo.sh                       # all stages, cleans up after itself
E2E_STAGES="green gates" E2E_TRANSCRIPT=/path/t.txt devbox run -- sh scripts/e2e/multi_repo.sh
E2E_KEEP=1 ...                                                    # keep server, database and work dir
```

Needs Elixir/OTP, `jq`, `git`, `go`, `psql` and the dev Postgres (`localhost:55432`, `postgres`/`postgres`), a working `pi`
login for the MiniMax model, and a free port from 4800. The work dir defaults to `<repo>/tmp/e2e-multi-repo` (it must sit
under the VFS allowlist root, so not `/tmp`). After `E2E_KEEP=1`: kill the node (`pkill -f 'e2emr[0-9]*@127.0.0.1'`),
`chmod -R u+rwx` and remove the work dir, `DROP DATABASE <E2E_DB_NAME> WITH (FORCE)`, and remove
`~/.foreman/worktrees/e2e-mr-*` and `~/.foreman/worktrees/e2e-legacy-*`. The script exits 0 when every assertion passed,
1 on an environment problem, 2 when setup failed and 3 with the failing assertions named.

## Timings of this run

```
   server ready after 23s: E2E-SERVER-READY port=4800 node=e2emr39454@127.0.0.1 multi_repo=[runs: true]
   stage gate took 1s
   terminal status 'completed' after 11s
   stage green took 11s
   stage gates took 1s
   terminal status 'completed' after 7s
   stage failure took 7s
   terminal status 'completed' after 7s
   stage legacy took 9s
```

## Transcript (as printed by the harness)

```

== foreman multi-repo live e2e: provider=pi model=minimax/MiniMax-M2.7-highspeed stages=[gate green gates failure legacy] ==

== setup: scratch repositories, fake gh, database, server ==
   repos: <repo>/tmp/e2e-multi-repo/repos/repo-a  <repo>/tmp/e2e-multi-repo/repos/repo-b  <repo>/tmp/e2e-multi-repo/repos/repo-c (each with a local bare origin under <repo>/tmp/e2e-multi-repo/origins)
   workflow: <repo>/tmp/e2e-multi-repo/workflows/multi-repo-edit.yaml (provider=pi model=minimax/MiniMax-M2.7-highspeed cleanup=on_success)
   pi runs with a private agent dir (<repo>/tmp/e2e-multi-repo/pi-agent: the operator's auth.json/models.json only)
   CLI built: <repo>/tmp/e2e-multi-repo/bin/foreman
   database foreman_e12_live ready
   server pid 83759, node e2emr39454@127.0.0.1, http://127.0.0.1:4800 (log: <repo>/tmp/e2e-multi-repo/server.log)
   server ready after 23s: E2E-SERVER-READY port=4800 node=e2emr39454@127.0.0.1 multi_repo=[runs: true]
   project e2e-mr-39454 registered over <repo>/tmp/e2e-multi-repo/repos/repo-a (its primary repository has the id 'main')
  PASS  project repositories (primary first, then b) (= [{"id":"main","primary":true},{"id":"b","primary":false}])

== gate: a multi-repo run is refused while the run-start gate is closed ==
   gate closed on the live node: {"multi_repo":[["runs",false]]}
  PASS  task.create with repo_ids is accepted at the boundary (the gate is a run-start gate) (= 201)
   run run-4f9ed0db72bf332bc25edcf34af254ce: failed (+0s)
  PASS  gate closed: run status (= failed)
  PASS  gate closed: the failure reason names the gate
  PASS  gate closed: no worktree was provisioned in a (= 0)
   gate reopened on the live node: {"multi_repo":[["runs",true]]}
   stage gate took 1s

== green: ONE task over repositories a (primary) and b (repo_ids: [b]) ==
  PASS  task.create repo_ids [b] accepted (= 201)
   run id: run-bf6db40e20fd52f2c4deef3200671c81
   run run-bf6db40e20fd52f2c4deef3200671c81: awaiting_worker (+0s)
   run run-bf6db40e20fd52f2c4deef3200671c81: in_progress (+3s)
   run run-bf6db40e20fd52f2c4deef3200671c81: completed (+10s)
   terminal status 'completed' after 11s
  PASS  green: run completed
   foreman run get: {"run_id":"run-bf6db40e20fd52f2c4deef3200671c81","status":"completed","task_id":"green-task-39454","pr_url":"https://github.com/e2e-owner/repo-a/pull/1","pr_urls":{"b":"https://github.com/e2e-owner/repo-b/pull/1","main":"https://github.com/e2e-owner/repo-a/pull/1"},"usage":{"cache_read_tokens":5033,"cache_write_tokens":0,"cost_usd":0.0038353799999999998,"input_tokens":4873,"output_tokens":254,"total_tokens":10160}}
   probe: {"status":"completed","completed_with_errors":false,"worktrees":[{"operation_id":"wt-run-bf6db40e20fd52f2c4deef3200671c81","repo_id":null,"status":"cleaned"},{"operation_id":"wt-run-bf6db40e20fd52f2c4deef3200671c81-b","repo_id":"b","status":"cleaned"}],"pr_associations":[{"repo_id":"main","pr_url":"https://github.com/e2e-owner/repo-a/pull/1"},{"repo_id":"b","pr_url":"https://github.com/e2e-owner/repo-b/pull/1"}]}
  PASS  worktree projections for the run (= 2)
  PASS  primary worktree operation id is the legacy wt-<run> (= wt-run-bf6db40e20fd52f2c4deef3200671c81)
  PASS  secondary worktree operation id is wt-<run>-b (= wt-run-bf6db40e20fd52f2c4deef3200671c81-b)
  PASS  primary worktree path ends in <run>/workspace
  PASS  secondary worktree path ends in <run>/repos/b
  PASS  the worktree of a was registered in repo a while the run was live (= 1)
  PASS  the worktree of b was registered in repo b while the run was live (= 1)
  PASS  cleanup: on_success reclaimed both worktrees (projection status) (= cleaned)
  PASS  cleanup: primary worktree directory is gone
  PASS  cleanup: secondary worktree directory is gone
  PASS  cleanup: repo a keeps no registered run worktree (= 0)
  PASS  cleanup: repo b keeps no registered run worktree (= 0)
  PASS  branch foreman/green-task-39454/run-bf6db40e20fd52f2c4deef3200671c81 pushed to the origin of repo a (009fe5269e9b895242212cd3f54495bd7bfe5e94)
  PASS  repo a: pushed branch carries commits ahead of main (= yes)
  PASS  repo a: VERSION committed on the run branch (= 1.4.2)
   repo a head commit: 009fe52 Foreman run run-bf6db40e20fd52f2c4deef3200671c81 phase 1
  PASS  branch foreman/green-task-39454/run-bf6db40e20fd52f2c4deef3200671c81 pushed to the origin of repo b (f020bb812a91f4fcc0820bca3fa60077bbf65e54)
  PASS  repo b: pushed branch carries commits ahead of main (= yes)
  PASS  repo b: VERSION committed on the run branch (= 1.4.2)
   repo b head commit: f020bb8 Foreman run run-bf6db40e20fd52f2c4deef3200671c81 phase 1
  PASS  the agent wrote b's VERSION through the sibling path (run-bf6db40e20fd52f2c4deef3200671c81/repos/b/) (= yes)
   agent tool call touching b: printf '1.4.2\n' > "/Users/ldangelo/.foreman/worktrees/e2e-mr-39454/green-task-39454/run-bf6db40e20fd52f2c4deef3200671c81/workspace/VERSION" && printf '1.4.2\n' > "/Users/ldangelo/.foreman/worktrees/e2e-mr-39454/green-task-39454/run-bf6db40e20fd52f2c4deef32006
  PASS  fake gh: 'pr create' calls for this branch (= 2)
  PASS  fake gh: the PR of a was created from repo a's checkout (= 1)
  PASS  fake gh: the PR of b was created from repo b's checkout (= 1)
  PASS  pr_associations_for_run (= 2)
  PASS  the PR of a points at repo-a
  PASS  the PR of b points at repo-b
  PASS  run.pr_url is the PRIMARY's PR (b never overwrites it) (= https://github.com/e2e-owner/repo-a/pull/1)
  PASS  run.pr_urls.b (= https://github.com/e2e-owner/repo-b/pull/1)
  PASS  GET /api/runs/:id/prs lists both PRs (= 2)
  PASS  cross-link: the body of PR a names the run
  PASS  cross-link: the body of PR a lists the sibling PR of b
  PASS  cross-link: the body of PR b lists the sibling PR of a
  PASS  merge gates after finalisation (a,b) (= pending,pending)
  PASS  event types that carry repo_id (the primary's events carry none) (= ["PrAssociated","PrReady","PrUpdated","RunBaseBranchRecorded","WorktreeCleaned","WorktreeCreated"])
  PASS  each of them carries repo_id exactly once (b's), never a's (= [1])
  PASS  WorktreeCreated events (one per repository) (= 2)
  PASS  no event stores a nil repo_id/repo_ids (absent really means absent) (= 0)
   archive: changed-files.txt diff.patch diffs manifest.json request.md  diffs/: b.files.txt b.patch 
  PASS  archive has diff.patch (repo a)
  PASS  archive has diffs/b.patch
  PASS  diffs/b.patch carries the VERSION change of b
  PASS  manifest.repositories[] ids (= ["main","b"])
  PASS  manifest.repositories[] carry their PR urls (= ["https://github.com/e2e-owner/repo-a/pull/1","https://github.com/e2e-owner/repo-b/pull/1"])
  PASS  git status of repo b is clean (nothing written outside the run worktree) (= )
  PASS  git status of repo a shows only the Foreman archive (= ?? .foreman/)
  PASS  fake gh: unsupported invocations so far (= 0)
   stage green took 11s

== gates: merge_approve for repo a alone must not allow merging repo b ==
  PASS  gate of a before any approval (= pending)
  PASS  gate of b before any approval (= pending)
  PASS  merge_approve (repo a): exit status (= 0)
  PASS  gate of a after approving a (= approved)
  PASS  gate of b after approving a only (= pending)
  PASS  run merge --repo-id b is REFUSED while only a is approved (exit 1): foreman: HTTP 422: {"error":":pr_not_acceptable"} 
  PASS  fake gh: no 'pr merge' reached any PR yet (= 0)
  PASS  run merge (repo a, approved): exit status (= 0)
  PASS  fake gh: a merged once, pinned to its approved head (= 1)
  PASS  fake gh: b not merged by a's merge (= 0)
  PASS  merge_approve (repo b): exit status (= 0)
  PASS  run merge --repo-id b (approved): exit status (= 0)
  PASS  fake gh: b merged once, pinned to ITS head (= 1)
   stage gates took 1s

== failure: repo b's origin is read-only when the run finalises ==
   chmod -R a-w <repo>/tmp/e2e-multi-repo/origins/repo-b.git (a push to it will fail)
  PASS  task.create repo_ids [b] accepted (= 201)
   run id: run-95a9e59566b6dbff68c54f1db9166b73
   run run-95a9e59566b6dbff68c54f1db9166b73: awaiting_worker (+0s)
   run run-95a9e59566b6dbff68c54f1db9166b73: in_progress (+4s)
   run run-95a9e59566b6dbff68c54f1db9166b73: completed (+7s)
   terminal status 'completed' after 7s
  PASS  failure: the run completed although b's PR could not be created
   foreman run get: {"run_id":"run-95a9e59566b6dbff68c54f1db9166b73","status":"completed","task_id":"failure-task-39454","pr_url":"https://github.com/e2e-owner/repo-a/pull/2","pr_urls":null,"usage":{"cache_read_tokens":5329,"cache_write_tokens":0,"cost_usd":0.0035435399999999995,"input_tokens":4541,"output_tokens":208,"total_tokens":10078}}
   probe: {"status":"completed","completed_with_errors":true,"repositories":[{"repo_id":"main","pr_state":"open","gate":"pending","pr_url":"https://github.com/e2e-owner/repo-a/pull/2","wt":"cleaned","failure":"null"},{"repo_id":"b","pr_state":"create_failed","gate":null,"pr_url":null,"wt":"created","failure":"{:git_push_failed, 1, \"error: remote unpack failed: unable to create temporary object directory\\nTo <repo>/tmp/e2e-m"}]}
  PASS  completed_with_errors (the derived dashboard flag) (= true)
  PASS  repo b reads as create_failed (= create_failed)
  PASS  repo a has its PR
  PASS  the branch of a is on its origin (= yes)
  PASS  the branch of b is NOT on its origin (= no)
  PASS  fake gh: a PR was created for a only (= 1)
  PASS  worktree of a reclaimed (cleanup: on_success) (= 0)
  PASS  worktree of b KEPT for the retry
  PASS  worktree of b still registered in repo b (= 1)

== failure: the operator restores the permissions and runs 'run retry-pr --repo-id b' ==
   retry-pr: exit 0: {   "result": {     "raw": "nil"   },   "status": "accepted" } 
  PASS  run retry-pr: exit status (= 0)
  PASS  the branch of b is now on its origin (= yes)
  PASS  VERSION of b on the pushed branch (= 1.4.3)
  PASS  fake gh: the retry created the PR of b (= 1)
  PASS  fake gh: the retry left a alone (still one PR for a) (= 1)
  PASS  the pushed branch of a is untouched by b's retry (= 02272d8783034544c91ea9d2945ccac3042bb920)
  PASS  pr_associations_for_run after the retry (= 2)
  PASS  completed_with_errors cleared by the retry (= false)
  PASS  the worktree of b is reclaimed by the successful retry (on_success)
  PASS  archive diffs/b.patch exists for the partially failed run too
   stage failure took 7s

== legacy: a single-repository project (never given a second repo) on the same server ==
  PASS  foreman run submit (no repo flags): exit status (= 0)
   run id: run-d2fefaebc360e3de88238ae7421f01b0
   run run-d2fefaebc360e3de88238ae7421f01b0: in_progress (+0s)
   run run-d2fefaebc360e3de88238ae7421f01b0: completed (+6s)
   terminal status 'completed' after 7s
  PASS  legacy: the run completed
   foreman run get: {"run_id":"run-d2fefaebc360e3de88238ae7421f01b0","status":"completed","task_id":"legacy-task-39454","pr_url":"https://github.com/e2e-owner/repo-c/pull/1","pr_urls":null,"usage":{"cache_read_tokens":4864,"cache_write_tokens":0,"cost_usd":0.00348084,"input_tokens":4751,"output_tokens":141,"total_tokens":9756}}
   probe: {"status":"completed","completed_with_errors":false,"worktrees":[{"operation_id":"wt-run-d2fefaebc360e3de88238ae7421f01b0","repo_id":null,"status":"cleaned"}],"repositories":[{"repo_id":"main","pr_state":"open"}],"pr_associations":[{"repo_id":"main","pr_url":"https://github.com/e2e-owner/repo-c/pull/1"}]}
  PASS  a single run worktree (= 1)
  PASS  its operation id is the legacy wt-<run> (= wt-run-d2fefaebc360e3de88238ae7421f01b0)
  PASS  run_repositories has the one primary entry (= 1)
  PASS  exactly one PR association (= 1)
  PASS  fake gh: one 'pr create' for the legacy branch (= 1)
  PASS  fake gh: it was opened from repo c (= 1)
  PASS  run.pr_url is set
  PASS  the run projection has no repo_ids / pr_urls / repo_id keys (= [false,false,false])
  PASS  the branch is on the origin of c (= yes)
  PASS  VERSION committed (= 1.4.4)
   events: PhaseCompleted,PhaseStarted,PrAssociated,PrReady,PrUpdated,ProjectRunReservationReleased,ProjectRunReserved,RunBaseBranchRecorded,RunCompleted,RunSlotAcquired,RunSlotReleased,RunStarted,TaskApproved,TaskCreated,TaskDispatched,TaskExecutionCompleted,UsageRecorded,VcsOperationCompleted,VcsOperationStarted,WorkerExited,WorkerSessionBound,WorkerStarted,WorkerStdout,WorktreeCleaned,WorktreeCreated
  PASS  events were read (run + task) (= yes)
  PASS  no event of the single-repo run carries repo_id / repo_ids (= [])
  PASS  no per-repo failure event (= 0)
  PASS  git status of repo c shows only the Foreman archive (= ?? .foreman/)
   archive: changed-files.txt diff.patch manifest.json request.md 
  PASS  the archive has diff.patch
  PASS  the archive has NO diffs/ directory
  PASS  the manifest has NO repositories[] key (= false)
   stage legacy took 9s

== strays: nothing left behind by the runs ==
  PASS  repo a: only its main checkout is a registered worktree (= 1)
  PASS  repo b: only its main checkout is a registered worktree (= 1)
  PASS  repo c: only its main checkout is a registered worktree (= 1)
  PASS  no run worktree directory left under ~/.foreman/worktrees/e2e-mr-39454 (= 0)
  PASS  no run worktree directory left under ~/.foreman/worktrees/e2e-legacy-39454 (= 0)
  PASS  fake gh: unsupported invocations over the whole run (= 0)

== evidence: fake gh calls ==
   gh@<repo>/tmp/e2e-multi-repo/repos/repo-a	pr create --base main --head foreman/green-task-39454/run-bf6db40e20fd52f2c4deef3200671c81 --title E2E: add VERSION 1.4.2 to ev
   gh@<repo>/packages/foreman_server	pr view https://github.com/e2e-owner/repo-a/pull/1 --json state,mergeable,headRefOid,headRefName,baseRefName,statusCheckRollup,reviewDe
   gh@<repo>/tmp/e2e-multi-repo/repos/repo-b	pr create --base main --head foreman/green-task-39454/run-bf6db40e20fd52f2c4deef3200671c81 --title E2E: add VERSION 1.4.2 to ev
   gh@<repo>/packages/foreman_server	pr view https://github.com/e2e-owner/repo-b/pull/1 --json state,mergeable,headRefOid,headRefName,baseRefName,statusCheckRollup,reviewDe
   gh@<repo>/tmp/e2e-multi-repo/repos/repo-a	pr view https://github.com/e2e-owner/repo-a/pull/1 --json body --jq .body 
   gh@<repo>/tmp/e2e-multi-repo/repos/repo-a	pr edit https://github.com/e2e-owner/repo-a/pull/1 --body Foreman run `run-bf6db40e20fd52f2c4deef3200671c81` complete.  Artifac
   gh@<repo>/tmp/e2e-multi-repo/repos/repo-b	pr view https://github.com/e2e-owner/repo-b/pull/1 --json body --jq .body 
   gh@<repo>/tmp/e2e-multi-repo/repos/repo-b	pr edit https://github.com/e2e-owner/repo-b/pull/1 --body Foreman run `run-bf6db40e20fd52f2c4deef3200671c81` complete.  Part of
   gh@<repo>/packages/foreman_server	pr view https://github.com/e2e-owner/repo-a/pull/1 --json state,mergeable,headRefOid,headRefName,baseRefName,statusCheckRollup,reviewDe
   gh@<repo>/packages/foreman_server	pr merge https://github.com/e2e-owner/repo-a/pull/1 --squash --match-head-commit 009fe5269e9b895242212cd3f54495bd7bfe5e94 
   gh@<repo>/packages/foreman_server	pr view https://github.com/e2e-owner/repo-b/pull/1 --json state,mergeable,headRefOid,headRefName,baseRefName,statusCheckRollup,reviewDe
   gh@<repo>/packages/foreman_server	pr merge https://github.com/e2e-owner/repo-b/pull/1 --squash --match-head-commit f020bb812a91f4fcc0820bca3fa60077bbf65e54 
   gh@<repo>/tmp/e2e-multi-repo/repos/repo-a	pr create --base main --head foreman/failure-task-39454/run-95a9e59566b6dbff68c54f1db9166b73 --title E2E: add VERSION 1.4.3 (b 
   gh@<repo>/packages/foreman_server	pr view https://github.com/e2e-owner/repo-a/pull/2 --json state,mergeable,headRefOid,headRefName,baseRefName,statusCheckRollup,reviewDe
   gh@<repo>/tmp/e2e-multi-repo/repos/repo-b	pr create --base main --head foreman/failure-task-39454/run-95a9e59566b6dbff68c54f1db9166b73 --title E2E: add VERSION 1.4.3 (b 
   gh@<repo>/packages/foreman_server	pr view https://github.com/e2e-owner/repo-b/pull/2 --json state,mergeable,headRefOid,headRefName,baseRefName,statusCheckRollup,reviewDe
   gh@<repo>/tmp/e2e-multi-repo/repos/repo-c	pr create --base main --head foreman/legacy-task-39454/run-d2fefaebc360e3de88238ae7421f01b0 --title Create a file named VERSION
   gh@<repo>/packages/foreman_server	pr view https://github.com/e2e-owner/repo-c/pull/1 --json state,mergeable,headRefOid,headRefName,baseRefName,statusCheckRollup,reviewDe

== evidence: scratch repositories ==
   repo-a local branches: foreman/failure-task-39454/run-95a9e59566b6dbff68c54f1db9166b73 foreman/green-task-39454/run-bf6db40e20fd52f2c4deef3200671c81 main 
   repo-a origin branches: foreman/failure-task-39454/run-95a9e59566b6dbff68c54f1db9166b73 foreman/green-task-39454/run-bf6db40e20fd52f2c4deef3200671c81 main 
   repo-b local branches: foreman/failure-task-39454/run-95a9e59566b6dbff68c54f1db9166b73 foreman/green-task-39454/run-bf6db40e20fd52f2c4deef3200671c81 main 
   repo-b origin branches: foreman/failure-task-39454/run-95a9e59566b6dbff68c54f1db9166b73 foreman/green-task-39454/run-bf6db40e20fd52f2c4deef3200671c81 main 
   repo-c local branches: foreman/legacy-task-39454/run-d2fefaebc360e3de88238ae7421f01b0 main 
   repo-c origin branches: foreman/legacy-task-39454/run-d2fefaebc360e3de88238ae7421f01b0 main 

== summary ==
   110 passed, 0 failed in 127s (provider=pi, model=minimax/MiniMax-M2.7-highspeed)
multi-repo e2e: PASSED
```
