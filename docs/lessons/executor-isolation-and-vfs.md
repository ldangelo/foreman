# Executor isolation, the VFS registry, and what each backend really enforces

> Written for Phase 0 durable execution (TRD-2026-a804d1c7, PR 9 / TRD-024) from PRs 7 and 8 and the source on `main` at that time. Every `file:line` below is under `packages/foreman_server/lib/foreman_server/` and was read, not grepped; lines drift, so re-read before relying on one.
> Rule of thumb: **a name that says "isolation" is not an enforcement point until you can name the caller that acts on its answer.**

## 1. The `VfsIsolation` registry enforces nothing

- `Agents.VfsIsolation` is a per-run registry: `bind/2` records canonical worktree roots for an `agent_id` (the run id), `lookup/1` reads them back, `unbind/1` drops them (`agents/vfs_isolation.ex:30-50`).
- `allowed?/2` answers "is this path under a bound root" (`agents/vfs_isolation.ex:60-63`). **It has no caller in `lib/`.** The only callers are tests (`test/foreman_server/agents/jido_shell_integration_test.exs:254-267`). Nothing asks it before a read, write or command, so its answer gates nothing.
- A refused bind is **fail-open**. `RunExecutor.bind_vfs/2` calls `VfsIsolation.bind_with_check/2`; on `{:error, :worktree_not_in_allowed_list}` it logs a warning and returns `:ok`, and when the GenServer is not running it logs at debug and returns `:ok` (`workflow/run_executor.ex:5204-5222`). The run proceeds either way.
- `JidoShellRunner.execute/3` runs host commands with `System.cmd/3` against the real `cwd`, outside any VFS (`agents/jido_shell_runner.ex:98-101`, `system_cmd/3` at `:169`). Its own doc says why: `Jido.Shell.Agent` mounts an in-memory VFS rooted at `/`, not the host directory, and only understands jido_shell's builtin command DSL (`agents/jido_shell_runner.ex:86-97`). Genuine VFS-sandboxed execution exists only for `start_session/2` + `run_command/3`, and the workflow engine does not use them to run agents.
- The other host-side callers shell out too (`actions/git_status_action.ex:61`, `actions/diff_read_action.ex:60` use `System.cmd("git", ...)`).

**The only enforced filesystem boundary is the docker jobsite's bind mount**: `Jobsite.Sandboxes.Docker` starts the container with `-v <worktree>:<sandbox_path>` plus any declared mounts (`jobsite/sandboxes/docker.ex:44-48`, `mount_args/1` at `:225`). The agent inside sees only what is mounted.

Rules:

- Do not describe the host workflow (what `RunExecutor` launches) as sandboxed, and do not add a doc sentence, status field or error message that implies the VFS registry protects the filesystem.
- Wiring `allowed?/2` into a real path is a design change (every host command and file read would need to route through it, and a refused bind would have to fail closed). Until then, treat the registry as bookkeeping.
- To re-verify: `grep -rn "allowed?(" packages/foreman_server/lib` and confirm no caller outside `vfs_isolation.ex`; read `bind_vfs/2` for the `:ok` on refusal.

## 2. The execution profile: what is recorded as enforced, and why

`Jobsite.ExecutionProfile` (`jobsite/execution_profile.ex`) is the recorded statement of what a backend enforces for one launch. An unenforced property is a recorded fact with a reason, never a silent default; nothing in a launch may claim a guarantee its backend does not give. The backend value is defined once there (`host_backend/0`, `docker_backend/0`); callers name no backend of their own. The recorded form is `to_map/1` (plain maps and strings so it survives JSON storage); it lands in each phase's `execution_profile` status field via `RunExecutor` (`workflow/run_executor.ex:1801-1805`).

| Property | `:host_workflow` (RunExecutor's door) | `:docker_jobsite` |
| --- | --- | --- |
| filesystem | always `unenforced` (the registry is not an enforcement point, section 1) | `enforced`, unless a mount is the host root (`/`), then `unenforced` (`execution_profile.ex:156-162`) |
| network | always `unenforced` | `enforced` where `NetworkPolicy.network_enforced_on/0` lists the backend |
| credentials | `unenforced` on both (run-scoped credentials belong to PRD-2026-aba4b79c) | same |
| cleanup | **never `enforced`** | follows the worktree spec: `:always` enforced; `:on_success`, `:never`, none per the spec |
| skill | `available` or `unverifiable` when a phase names a skill (section 5); absent otherwise | not computed |

Traps:

- **Host cleanup is never enforced, even for `cleanup: :always`.** The executor removes the worktree only on its own finish paths; a server crash skips them, and boot reconciliation reclaims a worktree only for a terminal run with a clean checkout (a dirty one is preserved). `host_cleanup/1` records `:always` as unenforced with that reason (`execution_profile.ex:166-177`). The TRD's first text said `:always` would be enforced; that was wrong for the host door.
- `ExecutionProfile.resolve(:docker_jobsite, ...)` has **no production caller**: the docker jobsite emits no phase events, so the docker row exists for the network policy and for tests. Do not cite a docker profile as something an operator can read from a run.
- Docker `cleanup: :always` recorded as enforced was NOT verified against the jobsite executor's `cleanup/3` and the boot orphan sweep (section 4); because the profile has no production caller, that mapping is unproven.

## 3. The host door fails closed on network policy

`NetworkPolicy.check_backend/2` (`jobsite/network_policy.ex:94-101`) returns `:ok` for the default (or absent) policy on any backend and for any policy on a backend in `network_enforced_on/0` (docker only). Anything else is refused as `{:error, {:isolation_unsupported, :network, backend}}`: a policy that silently does nothing is worse than an error, and a policy mode the module does not know is non-default, so it is refused rather than waved through.

`RunExecutor` runs it from `preflight_network_isolation/1` (`workflow/run_executor.ex:452`, `:478-488`) at kickoff, for fresh **and resumed** runs. Operator-visible consequences:

- A project that already had a `none`/`allowlist` `environment.network` policy, previously ignored on the host door, now has its runs refused at kickoff.
- A refused run is the first step of `kickoff_preflight`, before the provider/model check, the skill check and any claim.
- A resumed run that had already claimed a provider issue leaves that issue `in_progress` (only the execution-fail path releases it); boot reopens it at the next scan and the run's worktree is retained.

## 4. Docker cleanup routes and the orphan sweep

A policy-created network, proxy sidecar (`foreman-egress-proxy:1`) and sandbox container are all labelled `foreman.owner=<owner/0>` and `foreman.jobsite=<id>` (`jobsite/network_policy.ex:36`, `:49`). `owner/0` is a digest of the server's event-store host, port and database, so two servers on one docker host (or a test DB beside a live server) do not sweep each other. Cleanup and the sweep find objects by label and by nothing else; a name look-alike is never touched.

Who removes what, per way a jobsite ends:

| Ending | Route |
| --- | --- |
| completion, fresh run | the engine's `:release` step closes the sandbox (`jobsite/engine.ex:403-424`) |
| completion, resumed run | `release_all/3` (`jobsite/executor.ex:804-817`, called at `:1044`) closes the sandbox and the worktree; this is the **resume path only** |
| cancel or failure | `cleanup/3` (`jobsite/executor.ex:820-`, called from `fail/4` at `:553` and `handle_interrupt/6` at `:592`) closes the sandbox and discards the worktree |
| any ending of a run that reached `build_spec` | the policy network and sidecar are removed in `run/2`'s `after` (`jobsite/executor.ex:166-170`), whichever route above ran |
| server crash | `BootRecovery` calls `NetworkPolicy.sweep_orphans/0` at boot (`jobsite/boot_recovery.ex:84-88`, disabled by `:network_policy, sweep_on_boot: false`); at boot no jobsite of this owner is live, so every labelled container (sidecars and sandboxes) then network is an orphan |

Traps:

- A network cannot be removed while a container is attached, so containers go first. A missing `docker` binary makes the sweep a quiet no-op and never raises on boot.
- A completion/cancel test that only checks "the network is gone" cannot tell the routes apart (the `after` hook removes the network anyway). A test for a cleanup route must assert the **sandbox container** is gone and must be red when that route is removed; name both the engine release step and `release_all/3`.
- Mounting the host `/` on Docker Desktop for macOS shows the Linux VM's root, not the Mac's, so a "does the sandbox see the host" probe needs a parent-of-worktree mount and a marker file beside the worktree.

### Docker evidence run recorded for the PRD

Wed Nov 11 14:46:58 CST 2026, on a host with docker: `~/.omp/phase0-beads/mix.sh test --warnings-as-errors --include docker test/foreman_server/jobsite/network_policy_docker_test.exs test/foreman_server/jobsite/boot_recovery_test.exs` exited 0, 18 passed (log `~/.omp/phase0-beads/trd020-final.log`; the baseline before the TRD-020 changes at 14:20 CST was 11 passed). The `:docker` tag is excluded by default, so an ordinary suite run does not repeat this; rerun it with `--include docker` after touching the sandbox, the network policy or boot recovery. The crash test uses the default owner digest of the test event store, so do not run it against a test DB that a live docker jobsite shares.

## 5. The pi skill preflight mirrors pi's loader, and is fail-safe

`kickoff_preflight` order is network check, provider/model check, skill check, then the claim. The skill check resolves a phase's `command:` skill with `AgentRuntime.JidoHarness.SkillResolver.resolve/4` (`agent_runtime/jido_harness/skill_resolver.ex`), verified against pi 1.5.0's bundled loader (`chunk-44DLKSKE.js`, `chunk-36QC74V4.js`), **not** against Foreman's own CLI recommendation. The first TRD text was wrong because it copied that recommendation. Facts that bit:

- The project skill dir is `<cwd>/.pi/skills`, not `.pi/agent/skills`. The user dir is `<agent_dir>/skills` where `agent_dir` is `PI_CODING_AGENT_DIR` (tilde-expanded) else `~/.pi/agent`. pi also loads `~/.agents/skills` and every ancestor `.agents/skills` up to the git root, settings `skills` arrays, and each declared package's `pi.skills` (npm under `<agent_dir>/npm/node_modules`, git under `<agent_dir>/git/<host>/<path>`, local paths). Extensions can add skill paths at run time (`resources_discover`).
- A skill's identity is its frontmatter `name` (else directory name), and a file with no non-empty `description` is not loaded at all. The directory name is not the identity.
- `~/.foreman/skills` (the `Skills.Installer` target) is **not searched**: pi does not read it.
- Verdicts: `:available` only for a positive find in an unfiltered user-scoped source; `:missing` only when absence is proven everywhere and no extension could contribute paths; anything unresolvable (unknown package form, unreadable settings, project trust, filtering patterns, ignore files, a non-pi provider, a non-host backend) is `:unverifiable`. Only `:missing` refuses the run.
- The preflight uses the launch's own environment: Foreman launches pi with an overlay of the project's environment record, so `PI_CODING_AGENT_DIR` and `HOME` come from the project, not the server user.

What it does not do: on a typical dev host (pi with extensions or packages) a nonexistent skill resolves `:unverifiable`, so the refusal fires only on a clean pi setup; absence is proven against the registered checkout, not the worktree (which does not exist at admission); and `:missing` is not asserted against other pi versions. A refused run's terminal reason is a struct tuple, with readable text only in the log (`PreflightFailure.summarize/1`). Test fixtures seed a private skill home through the `:skill_home` config key and `test/test_helper.exs`.

When pi changes, re-derive the rules from its loader source and update the resolver's moduledoc; never from the CLI's `agent_commands.go` recommendation.

## 6. Local test runs must be CI-equivalent

The development host has `pi` on `PATH` and a real `~/.pi` with extensions, so tests that depend on the host's pi pass locally and fail on CI (PR 8's first CI run failed on about 27 `RunExecutor` tests while the local suite was green). Before opening a PR, run the full suite the way CI sees the machine:

```
CI_LIKE=1 ~/.omp/phase0-beads/mix.sh test --warnings-as-errors
```

`CI_LIKE=1` strips pi, omp and claude from `PATH` and sets an empty `HOME` (the runner script is the session's own tool, not part of the repo; any equivalent works: no agent CLI on `PATH`, empty `HOME`, `MIX_HOME`/`HEX_HOME` pinned). `test/test_helper.exs` stubs the `:jido_harness` provider-config pi `cli_path` hermetically so a test never reaches the real binary. A test that passes only with the host's pi installed is a defect in the test.
