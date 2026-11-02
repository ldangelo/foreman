---
document_id: PRD-2026-94f379ec
label: prd-agent-mcp-credential
version: 1.0.0
status: Draft
date: 2026-11-02
scale_depth: STANDARD
author: Claude Code (delegated author agent)
total_requirements: 17
readiness_score: 4.5
readiness_gate: PASS
---

# PRD: Scoped agent credential for the Foreman MCP boundary (project memory write)

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 15 |
| Should | 2 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 17/17 (100%) |
| Risk flags | 9 |
| Dependencies | 27 |
| Open ambiguity markers | 0 (6 judgement calls recorded, none blocking; J1 and J5 confirmed by the user on 2026-11-02; J2, J3, J4 and J6 ship on their recorded defaults pending review) |
| External dependencies | 3 (2 existing, 1 deferred and unbuilt) |

## Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Mint a per-run agent credential that is bound to its run and not interchangeable | Must | Medium | 3 |
| REQ-002 | Make the credential live exactly as long as its run | Must | Medium | 3 |
| REQ-003 | Authenticate every MCP entry point into one typed principal; keep the operator unchanged | Must | Medium | 3 |
| REQ-004 | Let an agent write and forget its own project's memory regardless of `allow_workflow_writes` | Must | Medium | 3 |
| REQ-005 | Confine the agent principal to one explicit allowlist defined once in `MCP.Policy` | Must | Medium | 3 |
| REQ-006 | Enforce project scope: an agent can only address its own project | Must | Medium | 3 |
| REQ-007 | Make `tools/list` and tool visibility principal-aware on both transports | Must | Medium | 3 |
| REQ-008 | Audit denied agent calls and keep the credential out of every log | Should | Low | 2 |
| REQ-009 | Hand Foreman-launched Claude workflow phases the scoped MCP server and its pre-approval | Must | High | 4 |
| REQ-010 | Hand jobsite launches no credential in this slice | Must | Low | 2 |
| REQ-011 | Degrade safely when the credential cannot be offered | Must | Medium | 2 |
| REQ-012 | Derive the standing memory guidance from what the launch actually received | Must | Medium | 3 |
| REQ-013 | Reconcile the remaining claims that agents write memory through MCP | Should | Low | 2 |
| REQ-014 | Do not regress the operator principal | Must | Medium | 2 |
| REQ-015 | Pass the documentation gate | Must | Low | 2 |
| REQ-016 | Prove the boundary end to end with a live smoke and mutation proofs | Must | Medium | 2 |
| REQ-017 | Keep the server's operator token and signing key out of every agent process environment | Must | Medium | 6 |

## Problem Statement

An agent running inside a Foreman project run cannot reach project memory write
under the shipped default or production configuration, yet the standing context
Foreman injects into agents describes project memory as something they use. The
write path is closed from three independent directions at once, and fixing any
one of them leaves the other two:

1. **The write gate is caller-blind and off by default.** The MCP boundary asks
   "may *anyone* call this tool?", never "who is calling?".
2. **No credential exists for an agent.** The only MCP credential is the single
   operator token.
3. **Workers are never handed an MCP server at all.** Even where a gate and a
   token would allow it, nothing tells the worker's CLI where `/mcp` is.

Who feels it: the solo operator, whose agents are told to curate durable project
knowledge but cannot, so the memory they read never improves unless the operator
writes it by hand with `foreman project memory write`.

### Verified code facts

Every row was read in this session. Rows marked [INFERENCE] state what the cited
code implies but no run proved.

| # | Fact | Evidence |
|---|---|---|
| F1 | `Dispatch.call/4` authenticates, then asks `Policy.authorized?/1`, then calls the tool. Nothing in that sequence knows the caller's kind. | `packages/foreman_server/lib/foreman_server/mcp/dispatch.ex:62-75` |
| F2 | `Policy.authorized?/1` reads only `:mcp, allow_workflow_writes`. The memory write and forget tools are on its write list. The shipped default is `false`; `dev.exs` sets `true`; `test.exs` sets `false`. | `mcp/policy.ex:4-32` (memory tools at `:20-21`), `:52-64`, `:75-77`; `config/config.exs:67-71`; `config/dev.exs:49-56`; `config/test.exs:133-137` |
| F3 | The write gate is enforced a second time inside most write tool bodies, also caller-blind. The two memory tools call it first. | `mcp/tools.ex:1939`, `:1969`, `:2894-2900`; also `:2017`, `:2159`, `:3160`, `:2658-2668`, `:3729`, `:3804`, `:3887`; `mcp/repo_tools.ex:125-135` |
| F4 | `McpAllowlist` is started and seeded ("advertised minus write tools") but `permit?/1` has no caller in `lib/`. The seeding is cosmetic. The gap is already on record. | `application.ex:181`, `:259`, `:625-642`; `agents/mcp_allowlist.ex:20`; `docs/TRD/completed/TRD-2026-4212be7e-jido-migration-VERIFIED.md:145` |
| F5 | `MCP.Auth.verify_token/1` accepts a missing token only under `allow_insecure_local`, and compares a string token to the single `:api_bearer_token`. There is no notion of caller kind. | `mcp/auth.ex:34-60` |
| F6 | Tools take `project_id` from caller arguments, so one credential reaches every project. The memory author reference comes from caller-supplied `run_id` or `session_id`. | `mcp/tools.ex:1933-1963`, `:2107-2108` |
| F7 | Anubis looks a tool up in `module.__components__(:tool) ++ Frame.get_tools(frame)` **before** `handle_tool_call/3` runs, and `__components__/1` receives no frame. A tool absent from Foreman's gate-filtered static list is "Tool not found" over the wire and never reaches `Dispatch`. | `packages/foreman_server/deps/anubis_mcp/lib/anubis/server/handlers.ex:51-53`, `.../handlers/tools.ex:31-43`; `mcp.ex:29`; `mcp/stdio.ex:30`; `mcp/dispatch.ex:40-53` (anubis_mcp 1.14.0 per `mix.lock`) |
| F8 | Claude workflow phases build `driver_opts` in one place. The only existing `mcp_config` is the in-flight approval hook, merged with `Keyword.merge`, which **replaces** any other `:mcp_config`. | `workflow/run_executor.ex:1528-1539`, `:1613-1623` (replace at `:1617`); `approvals/inflight.ex:88-109` |
| F9 | The jobsite launch paths set no `mcp_config`. | `jobsite/agent_runner.ex:166-214`; `jobsite/runners/overwatch.ex:259-291` |
| F10 | The Claude adapter maps a normalized `:mcp_config` map to `--mcp-config '{"mcpServers": <map>}'` and a string verbatim, accepts `:allowed_tools`, and never emits `--strict-mcp-config`. The server compiles the vendored harness. | `packages/jido_harness/lib/jido_harness/adapters/claude.ex:40-44`, `:113-116`, `:183-185`; `packages/foreman_server/mix.exs:96-99`; `packages/jido_harness/UPSTREAM_PIN.md` ("Build role") |
| F11 | Worker env carries `FOREMAN_RUN_ID`, `FOREMAN_WORKTREE_PATH` and friends, but no API URL, API token or project id. Operators cannot supply `FOREMAN_*` project env. Workers inherit the server's own OS environment in overlay mode. | `workflow/run_executor.ex:1506-1514`, `:4154-4248`; `project_setup.ex:46-69`; `project_environment.ex:119-122`; `packages/jido_harness/lib/jido_harness/run/request.ex:52`, `process/spec.ex:27` |
| F12 | The Go CLI can write memory, but the generated agent command set registers only list and read, and the list description says agents write through the MCP tool. The CLI needs a bearer token against a token-protected server. | `packages/foreman_cli/cmd/foreman/agent_commands.go:271-272`; `internal/client/client.go:33-47`; `foreman_server_web/plugs/bearer_auth.ex:37-54` |
| F13 | Memory **read** already reaches agents in every posture: the memory index is injected into the prompt, rebuilt per launch, but only when the index is non-empty. | `project_context/memory.ex:22-41` (empty index skipped at `:25`); `project_context.ex:42` |
| F14 | The standing guidance tells agents to call `foreman_project_memory_list` and `foreman_project_memory_forget`, and the same text is embedded in the tool descriptions. | `project_memory/guidance.ex:9-38`; `project_context/memory.ex:33-41` |
| F15 | A per-run credential precedent exists: a stateless HMAC-SHA256 of `"agent-permission:" <> run_id` keyed by `secret_key_base`, compared in constant time, bound to its run by URL path, never stored, never revoked. | `approvals/inflight.ex:68-80`, `:292-301`; `foreman_server_web/controllers/agent_permission_controller.ex:31-44`; `foreman_server_web/router.ex:42-45` |
| F16 | The pi adapter offers no MCP option: it has only free-form `extra_args` and rejects reserved flags, and the coordinator's isolation block passes `--no-mcp`. By inference phase pi workers load the host user's `~/.pi/agent/mcp.json`. [INFERENCE] A pi CLI **can** be given a per-run MCP server through a per-run agent directory: the e2e scripts run `pi mcp add foreman --url <url> --header "Authorization=Bearer <token>" --exposure direct` under `PI_CODING_AGENT_DIR=<per-run dir>`. Foreman has never used that for a production worker and its flag semantics are unverified there, so pi stays out of this slice (D2). | `packages/jido_harness/lib/jido_harness/adapters/pi.ex:62`, `:555-575`; `foreman_server/coordinator/agent/harness.ex:38-47`; `scripts/e2e/multi_repo_agent.sh:284-287`; `scripts/e2e/redaction_value_live.sh:220-223` |
| F17 | Legitimate operator-principal MCP clients exist and must keep working: the e2e scripts hand the operator bearer token to a real claude (a user-scope `foreman` MCP server in a private claude HOME) or a real pi (`pi mcp add` into a per-run `PI_CODING_AGENT_DIR`), or call `/mcp` with curl; any external MCP client holding the operator token does the same; and `mix foreman.mcp.stdio` passes the token in `init_meta`. The Go CLI is not one of them (F18). | `scripts/e2e/multi_repo_agent.sh:275-287`, `:296`; `scripts/e2e/redaction_value_live.sh:220-223`; `scripts/e2e/claude_projects/claude_home.sh:31-34`; `scripts/e2e/mcp_schedule_update.sh:75-98`; `scripts/e2e/coordinator_live_actions.sh:81-89`; `mcp/stdio.ex:52-58` |
| F18 | `foreman run submit` does **not** call `/mcp`: it posts `task.create` to `/api/commands`, and no Go file under `packages/foreman_cli` references `/mcp`. (The job brief listed it as an MCP caller; the code disagrees.) The Go CLI is an `/api` client. | `packages/foreman_cli/cmd/foreman/run.go:291-292` |
| F19 | Agent processes start in overlay mode: the child inherits the server's OS environment with Foreman's variables laid over it. An overlay entry whose value is `false` or `nil` is unset in the child (erlexec receives `{name, false}`); `:clear` is sent only in `:replace` mode; `""` would set an empty string instead. A harness test starts a real process with such entries and reads both as unset. | `packages/jido_harness/lib/jido_harness/run/request.ex:51-52`, `process/spec.ex:26-27`, `:118-119`, `:150`; `process/driver/erlexec.ex:52-61`; `packages/jido_harness/test/jido_harness/process_manager_test.exs:437-465`; `packages/jido_harness/deps/erlexec/src/exec.erl:144-149`, `:294-299` |
| F20 | `FOREMAN_API_TOKEN` is read from the server's environment at boot into `:api_bearer_token`; `MCP.Auth` and the `/api` bearer plug compare a presented token to it, and `Policy.authorized?/1` is caller-blind, so a worker that presents an inherited token is the unrestricted operator principal. `SECRET_KEY_BASE` is the key every agent credential and approval token is minted from; the server holds it in its OS environment only where the deployment supplies it there (the prod secret provider falls back to `System.get_env/1`). | `packages/foreman_server/config/runtime.exs:39-41`; `mcp/auth.ex:43-60`; `foreman_server_web/plugs/bearer_auth.ex:37-54`; `mcp/policy.ex:52-64`; `config/prod.exs:47-53`; `config_providers/secrets.ex:144-155`; `approvals/inflight.ex:292-301` |
| F21 | The server composes the environment of an agent process in four separate places: the supervised-worker hop (workflow phases of every kind, `command:` included, and the jobsite scripted launch), the jobsite direct runner, the coordinator turn and the review evaluator. Foreman's variables travel as `env_map` or `env`; the last two pass none. A task with no project has its `env_map` replaced by an empty map before the worker starts, and the jobsite direct runner stringifies every env value, so a `nil` would become `""`. | `overwatch/adapters/jido_harness_worker.ex:96-111`; `overwatch.ex:184`; `workflow/run_executor.ex:1506-1514`, `:1646-1659`; `jobsite/runners/overwatch.ex:259-291`; `jobsite/agent_runner.ex:143-151`, `:166-214`; `coordinator/agent/harness.ex:77-102`; `review/evaluator/agent.ex:215-235` |

## Design Principle

**One boundary, two principals.** The MCP boundary decides by *who is calling*,
in exactly one place. The operator keeps the ambient gate and stays
unrestricted. An agent is confined to a small explicit set of tools, on its own
project, for as long as its run lives.

**Guidance follows capability.** What an agent is told it can do is derived from
what that launch was actually given, never from what the system could do in the
best case. Where Foreman cannot hand a launch the write path, the text says so.

The two principles are the line between what this PRD changes and what it does
not: it adds a principal and makes the instructions honest. It does not widen the
operator's surface, relax `allow_workflow_writes` for anyone else, or promise a
sandbox (see Non-Goals).

## Decisions already made (recorded, not reopened)

| ID | Decision |
|---|---|
| D1 | Agent credentials MAY write and forget the memory of **their own** project even when `allow_workflow_writes` is false (the shipped default). The agent credential is evaluated first; for tools in the agent set it wins. `tools/list` is principal-aware for the same reason: an agent-scoped list unions the agent set so `foreman_project_memory_write` is advertised. Memory only; no other write tool is unlocked. |
| D2 | The first slice covers **Claude workers only**. Pi workers stay read-only via prompt injection until a later slice, and the guidance stays truthful for them. Pi's adapter MCP option is a deferred follow-up PRD. |
| D3 | The operator principal (operator bearer token, or no token under `allow_insecure_local`) stays unrestricted and unchanged. The agent allowlist applies to the agent principal **only**. It is an explicit list defined once in `MCP.Policy`, not "advertised minus write tools". `application.ex` seeding is removed or derived from it. The existing `McpAllowlist` tests are kept. |
| D4 | The agent principal is `{:agent, project_id, run_id}`. Project scope is enforced: a call addressed to another project is refused, and an absent `project_id` is `INVALID_PARAMS`. |
| D5 | Process: PRD, then TRD, then step beads (the step beads already exist: epic `foreman-5ifqm` with one chained, deferred step bead per TRD PR, `foreman-5ifqm.1` to `.5`; do not create a second set). |
| D6 | The server's `FOREMAN_API_TOKEN` and `SECRET_KEY_BASE` are scrubbed from agent environments **in this slice**, narrowly: those two names only, on every launch path the server composes (REQ-017). The broader policy on which other server-held secrets (LANGFUSE keys, GitHub tokens, ...) an agent may inherit is deferred to a named follow-up and recorded as a residual risk. This moves the scrub from Non-Goals into scope (user decision, 2026-11-02). |

### How the decisions are applied

Three decisions need an operational reading, recorded here so the choice is
visible and reversible. None of them changes a decision's intent.

- **J1 — "read tools" in D3.** The agent set is the read tools whose input
  **requires `project_id`** (15 of the 35 advertised read tools) plus the two
  memory write tools: 17 tools. D4's project scope can only be enforced on a tool
  that carries a `project_id`. The other 20 read tools are keyed by run, task or
  thread, or are global aggregates; handing them to an agent would let it read
  other projects' logs, transcripts and tasks, contradicting D4. They are withheld
  from the first slice and listed under Deferred in the TRD. Widening later is one
  list entry plus an owner-resolution rule.
- **J2 — "otherwise fall through to `Policy.authorized?/1`" in D1.** Read as
  "every non-agent principal keeps the ambient gate". An agent principal never
  falls through: a literal fall-through would hand an agent **every** tool whenever
  `allow_workflow_writes` is true (the dev posture), which D3's confinement and the
  acceptance case "`foreman_project_settings_update` is refused for an agent"
  contradict.
- **J3 — D4's `foreman_project_*` wording.** Generalised to "every agent-set tool
  declares `project_id`, and every call must carry the principal's". All 17 agent
  tools do, so the rule covers `foreman_project_*` and the project-addressed reads
  named differently (`foreman_thread_list`, `foreman_usage_get`, and others) that a
  name-based rule would miss.

## Goals

- A Foreman-launched Claude workflow agent can list, read, write and forget its
  own project's memory under the shipped default posture.
- No other capability is unlocked for any agent, and nothing changes for the
  operator.
- The credential dies with its run.
- No agent the server launches inherits the server's operator token or the key
  every agent credential is minted from (REQ-017).
- The memory guidance an agent receives is true for that launch, for Claude and
  for every provider and door that does not receive the credential.

## Non-Goals

- **Pi MCP injection.** Deferred (D2). Open questions are recorded in the TRD.
- **Per-worker stdio MCP.** `mix foreman.mcp.stdio` boots a whole second Foreman
  application and is unsuitable as a per-worker server.
- **Any other agent write tool.** Tasks, runs, schedules, settings, workflows,
  prompts, inbox, messages and PR tools stay operator-only.
- **CLI-based agent writes.** The CLI stays an operator surface.
- **A revocation list or stateful tokens.** Revocation is the run's lifecycle.
- **Surviving `secret_key_base` rotation.** Rotating it invalidates every agent
  and in-flight approval token; documented, not mitigated.
- **A sandbox.** The credential confines the MCP tool channel. It does not stop an
  agent with a shell from doing what its environment and the host allow: REQ-017
  removes two inherited secrets, not the agent's other access (see Threat Model in
  the TRD).
- **Broader worker-environment policy** (which other server secrets a worker may
  inherit: LANGFUSE keys, GitHub tokens, the webhook and notification secrets, ...)
  — follow-up. REQ-017 scrubs only `FOREMAN_API_TOKEN` and `SECRET_KEY_BASE` (D6).
- **Run-, task- and thread-keyed read tools for agents** (J1).
- **A credential for jobsite launches** (REQ-010 pins their absence).
- **Collapsing the remaining in-body write gates** (about 18 tools) into the
  dispatcher.
- **A `foreman doctor` row** for credential availability, and rate limiting.

## External Dependencies

| Dependency | Status | Effect on this PRD |
|---|---|---|
| Claude Code CLI: `--mcp-config` HTTP servers with headers, and MCP permission rules (`mcp__<server>__<tool>`; globs only after a literal `mcp__<server>__` prefix) | **Existing.** The approval hook already depends on `--mcp-config`. Rule syntax and name-collision precedence were read from `https://code.claude.com/docs/en/permissions` and `.../mcp` on 2026-11-02; no live run. | REQ-009 depends on it. A server key that cannot collide with the operator's own (`foreman`) avoids the documented highest-precedence-source rule. |
| Anubis MCP server library 1.14.0 | **Existing.** `handle_request/2` is a documented, overridable callback; `Frame.tools` is documented. `Anubis.Server.Handlers.handle/3` is an undocumented internal that the generated default also calls. | REQ-007 depends on both. The full-stack HTTP test pins the contract. |
| Pi CLI MCP injection | **Deferred, unbuilt.** The adapter exposes no MCP option. A per-run mechanism is known from the e2e scripts (`pi mcp add --url --header --exposure direct` into a per-run `PI_CODING_AGENT_DIR`), but its flag semantics are unverified for production use. | None. D2 excludes it; REQ-012 keeps pi's guidance truthful meanwhile. |

## Assumptions

Recorded rather than presented as decided:

- **A1** — The only user is the solo operator, and `/mcp` is reachable over
  loopback only.
- **A2** — `secret_key_base` is a binary of at least 32 bytes wherever the
  server runs. `Inflight` already raises otherwise (`approvals/inflight.ex:292-301`).
- **A3** — Run ids are not secret: `Identity.run_id/2` derives them
  deterministically from the task and approval ids (`identity.ex:15-30`), and they
  surface in listings and tool results. The credential therefore cannot be "the
  run id".
- **A4** — The run projection is applied by `CommandRouter` before it replies to
  the actor (`projection_store.ex:144-152`), so a run is visible to the
  authenticator before its first worker could present a credential. [INFERENCE:
  the relative order against worker spawn was not traced.]
- **A5** — Workflow-door claude processes are spawned by the harness on the host,
  so a loopback base URL is reachable from them. [INFERENCE: no sandbox provider
  sits in that path; not proven by a run.]
- **A6** — Jobsite launches may run the agent CLI inside a Docker sandbox through
  a shim, where loopback is not the host's. [INFERENCE from
  `jobsite/agent_runner.ex:186-189`.]
- **A7** — Headless Claude denies a tool call that would prompt and is not
  pre-approved, MCP tools included. Repo evidence for built-in tools:
  `workflow/run_executor.ex:1584-1589`, `jobsite/agent.ex:3-10`; Claude's
  documentation lists MCP tool prompts alongside the others.
- **A8** — The MCP endpoint must be enabled (`:mcp, enabled: true`) for any of
  this to apply. It is `false` in `config.exs` and `test.exs`, `true` in
  `dev.exs`, and `runtime.exs` has no switch for it.
- **A9** — Memory content lives on disk under the project's main checkout and is
  audited by `ProjectMemoryWritten` and `ProjectMemoryForgotten` events carrying
  `author_kind` and `author_ref` (`project_memory.ex:172-188`, `:208-219`).
- **A10** — `FOREMAN_API_TOKEN` and `SECRET_KEY_BASE` reach an agent only by
  inheritance: no `lib/` code hands either to a worker, and the worker env Foreman
  builds carries neither (`workflow/run_executor.ex:4154-4248`). `SECRET_KEY_BASE`
  is in the server's process environment only where the deployment supplies it
  there; the prod secret provider falls back to `System.get_env/1`
  (`config_providers/secrets.ex:144-155`), so an env-supplied deployment carries it
  and whether a given deployment does is not known to this PRD.

## Requirements

### Feature Area: Identity

#### REQ-001: Mint a per-run agent credential bound to its run and not interchangeable

**Priority:** Must · **Complexity:** Medium

A credential exists that identifies one run. It is minted from server-held key
material, is deterministic per run, and cannot be confused with any other
credential Foreman issues.

- AC-001-1: Given an active run R of project P, when a caller presents R's agent
  credential to `/mcp`, then the caller is authenticated as the agent principal
  of project P and run R, and not as the operator.
- AC-001-2: Given a credential altered in any part, a credential minted for a
  different run, or an in-flight approval token, when it is presented to `/mcp`,
  then it is refused; and given an agent credential presented to the approval
  endpoint `/agent-permission/:run_id`, then it is refused there too.
- AC-001-3: Given `allow_insecure_local: true` and no operator token configured,
  when a string shaped like an agent credential fails verification, then it is
  refused rather than accepted as the operator.

#### REQ-002: Make the credential live exactly as long as its run

**Priority:** Must · **Complexity:** Medium

[RISK: a credential that outlives its run is a standing write capability for a
project; a check that fails open when the run lookup is unavailable is the same
defect under load.]

- AC-002-1: Given a run that has reached a terminal state (completed, failed,
  cancelled, blocked, stuck or deleted) or never existed, when its credential is
  presented, then it is refused: HTTP 401 at the edge, `UNAUTHORIZED` on a tool
  call.
- AC-002-2: Given the run lookup itself fails, when a credential is presented,
  then the request is refused (fail closed) with an outcome distinct from
  "invalid", an error-level log line that names the run id and never the
  credential, and HTTP 503 at the edge.
- AC-002-3: Given a run that is paused or awaiting a worker (not terminal), when
  its credential is presented, then it is accepted, and a run resumed after a
  failure accepts the same credential again without re-minting.

#### REQ-003: Authenticate every MCP entry point into one typed principal; keep the operator unchanged

**Priority:** Must · **Complexity:** Medium

[RISK: the HTTP edge, tool dispatch and stdio initialisation each verified tokens
on their own. A fourth, differing copy, or a caller still reading the old return
shape, is a silent authentication bypass.]

- AC-003-1: Given an operator bearer token, or no token under
  `allow_insecure_local: true`, when it is presented on either transport, then the
  caller is the operator principal and every outcome is identical to before this
  change.
- AC-003-2: Given the codebase after the change, when searched, then the HTTP
  plug, tool-call dispatch and stdio initialisation all call one authentication
  function, and the former `verify_token/1` and `verify_request/3` no longer exist.
- AC-003-3: Given the principal type, then it is a struct with enforced keys and a
  `@type t`, with exactly two kinds, and every consumer handles both kinds with no
  catch-all clause.

### Feature Area: Policy and enforcement

#### REQ-004: Let an agent write and forget its own project's memory regardless of `allow_workflow_writes`

**Priority:** Must · **Complexity:** Medium

This is D1. It unlocks exactly two write tools, for the agent principal only.

- AC-004-1: Given `allow_workflow_writes: false` and the agent principal of
  project P, when it calls `foreman_project_memory_write` for P, then the topic is
  written and a `ProjectMemoryWritten` event records author kind `agent` and the
  principal's run as the author reference.
- AC-004-2: Given the same posture, when it calls `foreman_project_memory_forget`
  for P, then the topic is forgotten and audited the same way.
- AC-004-3: Given `allow_workflow_writes: false`, when the **operator** principal
  calls either tool, then it is refused exactly as before (D3).

#### REQ-005: Confine the agent principal to one explicit allowlist defined once in `MCP.Policy`

**Priority:** Must · **Complexity:** Medium

[RISK: an allowlist derived by subtraction ("advertised minus write tools")
silently grants every tool added later; a second copy of the list drifts. The
current seed is both.]

- AC-005-1: Given an agent principal, when it calls any tool outside
  `Policy.agent_tools/0` (for example `foreman_project_settings_update`), then it
  is refused, including when `allow_workflow_writes: true`.
- AC-005-2: Given `Policy.agent_tools/0`, then it is an explicit literal list of
  the 15 read tools that require `project_id`, plus `foreman_project_memory_write`
  and `foreman_project_memory_forget`, and no other write tool; each member exists
  in the advertised inventory and declares a required `project_id`.
- AC-005-3: Given `ForemanServer.Application`, then it no longer seeds
  `Agents.McpAllowlist`, no second list of agent tools exists outside `MCP.Policy`,
  and the existing `McpAllowlist` tests still pass unmodified.

#### REQ-006: Enforce project scope: an agent can only address its own project

**Priority:** Must · **Complexity:** Medium

[RISK: a scope check that lives in only some tools, or that normalises the
identifier differently from the tool that then uses it, is a confused-deputy hole
across projects.]

- AC-006-1: Given the agent principal of project P, when it calls an agent-set
  tool, including `foreman_project_memory_write` or `_forget`, with a `project_id`
  other than P, then the call is refused with `POLICY_REFUSED` before the tool
  runs, and nothing is read or written: no topic file changes and no memory event
  is recorded for the other project. The refusal does not consult any store, so it
  reveals nothing about whether the other project exists.
- AC-006-2: Given the agent principal, when `project_id` is absent, blank or not
  a string, then the call is refused with `INVALID_PARAMS`.
- AC-006-3: Given an agent's memory write or forget that supplies a `run_id`
  argument, when the audit event is recorded, then its author reference is the
  principal's run id, never the supplied value.

#### REQ-007: Make `tools/list` and tool visibility principal-aware on both transports

**Priority:** Must · **Complexity:** Medium

[RISK: Anubis resolves a tool by name before dispatch runs and takes no principal
for its static list, so a list or call that is not made principal-aware either
hides the memory tools from the agent that is allowed them or shows the operator
tools it cannot call.]

- AC-007-1: Given the agent principal, when it lists tools, then it receives
  exactly `Policy.agent_tools()`, under both values of `allow_workflow_writes`.
- AC-007-2: Given the operator principal, when it lists tools, then the result is
  identical to before this change under both values of `allow_workflow_writes`.
- AC-007-3: Given an agent that calls a tool outside its set, then over the wire
  the tool is "not found", and if the call reaches dispatch directly it is refused
  with `POLICY_REFUSED`.

#### REQ-008: Audit denied agent calls and keep the credential out of every log

**Priority:** Should · **Complexity:** Low

- AC-008-1: Given any call refused for an authenticated agent principal (outside
  the set, project mismatch, missing project), when it is refused, then an event on
  `[:foreman_server, :mcp, :policy, :refused]` records the tool, the reason, the
  principal kind, the run id and the project id.
- AC-008-2: Given any log line, telemetry event, `inspect/1` of a Foreman struct or
  worker output line, then the agent credential does not appear in clear.

### Feature Area: Injection

#### REQ-009: Hand Foreman-launched Claude workflow phases the scoped MCP server and its pre-approval

**Priority:** Must · **Complexity:** High

[RISK: the existing approval hook already owns the single `mcp_config` key, and its
merge replaces rather than combines; a naive second injection silently removes
one of the two, and an injection that lands before enforcement hands workers an
open endpoint under `allow_insecure_local`.]

- AC-009-1: Given a Claude workflow phase launch with agent credentials available,
  when its harness options are built, then `mcp_config` contains an HTTP server
  named `foreman_agent` at `<base>/mcp` carrying
  `Authorization: Bearer <the credential for this run>`.
- AC-009-2: Given a Claude phase whose approval mode `prompt` also adds the
  in-flight approval hook, when its harness options are built, then `mcp_config`
  contains both `foreman_permission` and `foreman_agent`, whichever is constructed
  first.
- AC-009-3: Given the same launch, then `allowed_tools` pre-approves exactly the
  four memory tools (`mcp__foreman_agent__foreman_project_memory_list`, `_read`,
  `_write`, `_forget`) and keeps any entries already present.
- AC-009-4: Given a phase whose provider is not Claude, then its launch carries no
  `mcp_config` from this feature.

#### REQ-010: Hand jobsite launches no credential in this slice

**Priority:** Must · **Complexity:** Low

Jobsite launches key on a jobsite id, not a run in the projection, may run the
agent inside a Docker sandbox where loopback is not the host, and receive their
standing context through the same producer. D4's principal is run-keyed, so
covering them needs a widening this slice does not make. The omission is pinned
rather than left implicit.

- AC-010-1: Given a jobsite iteration on either launch path with agent
  credentials available, when its run request is built, then it carries no
  `mcp_config` and no `allowed_tools` from this feature.
- AC-010-2: Given the standing context of a jobsite launch, then its memory
  guidance names no tool that launch cannot call (REQ-012).

#### REQ-011: Degrade safely when the credential cannot be offered

**Priority:** Must · **Complexity:** Medium

- AC-011-1: Given MCP disabled, the new `agent_credentials` switch off, no
  resolvable base URL or an invalid `secret_key_base`, when a Claude phase
  launches, then no credential is minted, the harness options are exactly what they
  were before this feature, the run proceeds, and one boot-time log line states
  the reason.
- AC-011-2: Given a run whose task has no project, then no credential is minted.

### Feature Area: Truthfulness

#### REQ-012: Derive the standing memory guidance from what the launch actually received

**Priority:** Must · **Complexity:** Medium

[RISK: guidance text that is chosen by provider name, not by the credential
decision, drifts the moment either changes; two decisions are two chances to
promise a path that is closed.]

- AC-012-1: Given a launch that received the agent credential, when the standing
  context is built, then the memory section instructs list, read, write and
  forget, names the project id, and is present even when the project has no
  memory yet.
- AC-012-2: Given a launch without the credential (pi, jobsite, coordinator, or
  the feature unavailable), when the standing context is built, then the memory
  text names no memory tool, states the notes are read-only for the session, and
  any truncation hint does not point at an unreachable tool.
- AC-012-3: Given the codebase after the change, then `ProjectContext.build/2`
  remains the only producer of standing context, both doors and the preview
  endpoint call it, and the access decision reaches it from one place per launch.

#### REQ-013: Reconcile the remaining claims that agents write memory through MCP

**Priority:** Should · **Complexity:** Low

- AC-013-1: Given `foreman commands inventory`, when the
  `foreman-project-memory-list` entry is read, then its description no longer
  promises the MCP write tool unconditionally.
- AC-013-2: Given `GET /api/projects/:id/context`, when it answers, then the
  response states which memory access variant it shows.

### Feature Area: Verification and documentation

#### REQ-014: Do not regress the operator principal

**Priority:** Must · **Complexity:** Medium

[RISK: the e2e scripts, the stdio task and the operator's own claude and pi
sessions call write tools with the operator token; any accidental restriction
breaks live harnesses that no unit test of the new code would notice.]

- AC-014-1: Given every advertised tool and both values of `allow_workflow_writes`,
  when decisions made through the new authorization are compared with the former
  caller-blind gate, then they are identical for the operator.
- AC-014-2: Given the operator bearer path, the stdio path and the insecure-local
  path, then the existing tests of those paths pass with their intent unchanged.

#### REQ-015: Pass the documentation gate

**Priority:** Must · **Complexity:** Low

- AC-015-1: Given the change set, when the documentation gate list in the TRD is
  walked, then every document is updated or recorded as intentionally unchanged
  with a reason.
- AC-015-2: Given `TRD-2026-4212be7e-jido-migration-VERIFIED.md`, when its recorded
  gap is read, then a forward-pointer note sits beside it and the original text is
  not rewritten.

#### REQ-016: Prove the boundary end to end with a live smoke and mutation proofs

**Priority:** Must · **Complexity:** Medium

- AC-016-1: Given a server started per `docs/dev-setup.md`, when `/mcp` is called
  with the operator token, an agent token, no token and a wrong token, then each
  answers as the TRD's smoke matrix specifies, and the agent token stops working
  when its run ends.
- AC-016-2: Given each mutation in the TRD's proof table applied locally, when the
  named tests run, then they fail, and they pass again once the mutation is
  reverted.

### Feature Area: Worker environment

#### REQ-017: Keep the server's operator token and signing key out of every agent process environment

**Priority:** Must · **Complexity:** Medium

[RISK: a scrub applied at one launch site leaves every other launch path
inheriting the token; a scrub that overrides an explicit entry breaks a project
that legitimately delivers its own `SECRET_KEY_BASE`; a scrub carried in the
caller's env map is silently dropped for a run with no project.]

This is D6. Agents start with the server's own OS environment under Foreman's
variables (`env_mode: :overlay`, F19), so an agent inherits whatever the server was
started with. Two inherited variables defeat this PRD's confinement:
`FOREMAN_API_TOKEN`, which `/mcp` accepts as the unrestricted operator principal,
and `SECRET_KEY_BASE`, the key every agent credential is minted from (F20). Both
are unset in every agent launch the server composes (F21), through one function.
Only these two names are in scope; every other inherited secret is the follow-up
(Non-Goals). The scrub is not behind the `agent_credentials` switch (REQ-011): it
applies whether or not a credential is offered.

- AC-017-1: Given a server whose environment exports `FOREMAN_API_TOKEN` and
  `SECRET_KEY_BASE`, when a workflow phase worker is launched, of any provider and
  any phase kind (`command:` included), for a task with or without a project, then
  the worker's process environment holds neither variable.
- AC-017-2: Given the same server, when a jobsite iteration is launched on either
  launch path (the direct runner and the supervised scripted launch), then the
  agent's process environment holds neither variable.
- AC-017-3: Given the same server, when the coordinator runs a turn or the review
  evaluator runs, then the agent process it starts holds neither variable.
- AC-017-4: Given any launch covered above, when its environment is built, then
  every other variable the launch carried before this change is present and
  unchanged (the server's `PATH` and `HOME`, the `FOREMAN_*` run variables, project
  variables and secrets, `FOREMAN_LIBRARY_PATH`), and a project that stores a
  secret named `SECRET_KEY_BASE` still receives its own value.
- AC-017-5: Given `allow_insecure_local: false` and an operator token configured,
  when a phase worker calls `/mcp` with the credential of its own `foreman_agent`
  server, then it is the agent principal of its run, and when it presents no token,
  then it is refused with HTTP 401; it is never the operator.
- AC-017-6: Given an operator client that presents the operator token (an e2e
  script, an external client or the stdio transport), when it calls `/mcp` or
  `/api`, then every outcome is identical to before this change.

Posture limit, not an AC: under `allow_insecure_local: true` an absent token is the
operator (D3, AC-003-1), so a worker that omits `Authorization` is the operator
whatever its environment holds. The scrub removes a secret; it does not close a
posture the operator opened.

## Constitution Gate

Source: `docs/standards/constitution.md` (canonical).

- **§1 Non-Negotiable Rule 4, event-sourced invariant: PASS.** No new event,
  command, aggregate or projection. The memory write still goes `ProjectMemory` →
  `CommandGateway.dispatch_system` → `project.memory.write`
  (`project_memory.ex:172-188`). The credential is stateless and persists nothing.
  Whether a credential is still live is read from the run projection. That read
  decides whether to accept one HTTP request, inside the request/response boundary,
  exactly as every MCP read tool reads the projection; it is not orchestration. It
  triggers nothing, and no scheduler, run loop or recovery path consumes it.
- **§1 Non-Negotiable Rules 5-8, naming: PASS (not triggered).** New modules
  (`MCP.Principal`, `MCP.AgentToken`, `MCP.AgentAccess`) are not events, commands,
  aggregates or projections. If an audit event proves necessary it ends in
  `Event`; the design needs none because the memory event already carries
  `author_kind` and `author_ref`.
- **§1 Non-Negotiable Rules 1-3, secrets, validation, tests: PASS.** The key is
  the endpoint `secret_key_base`; no secret enters code. The credential and every
  caller argument are validated at the one boundary. Every requirement has a test
  task.
- **§1 TDD and §3 Quality Gates: PASS.** The TRD pairs each implementation task
  with a `-TEST` task whose failing tests are written first within the same PR,
  and its closing task runs the full ExUnit and Go suites.
- **§4 Architecture Rules (Binding): PASS.** No `EventStore.append` call site is
  added or changed; reads stay on the projection store (queries read the read
  model, no write on the query path); the Go CLI change is a description string and
  adds no multi-step call.
- **§5 Approval Requirements: SATISFIED.** A new principal kind at the MCP boundary
  is an architecture change ("new patterns, or service boundaries"). D1-D5 record
  the user's approval of the direction; this PRD and the TRD are the review
  artefacts. No new dependency is added (`:crypto` and `Plug.Crypto` are already
  used by `Approvals.Inflight`). No endpoint, command or event is removed or
  changed incompatibly: the operator's `/mcp` contract is unchanged,
  `GET /api/projects/:id/context` gains an additive field, the CLI inventory
  description text changes, and the Elixir `Auth` function names change but are
  internal. Agent environments lose two inherited variables (REQ-017): a hardening
  of a trusted surface, not a change to an API contract, and approved as D6.
- **§8 Documentation Discipline: SATISFIED by REQ-015.**

**Constitution Gate: PASSED.**

## Ambiguity scan

Ambiguity scan complete: 0 items marked for clarification, none blocking.

Six judgement calls are recorded with their rationale and a default that ships
unless the user says otherwise. Status: **J1 confirmed** (2026-11-02: the 17-tool agent set, project-keyed reads plus memory write/forget) and **J5 confirmed** (2026-11-02: show the write guidance whenever the agent holds the scoped credential, including an empty index). J2, J3, J4 and J6 ship on their defaults pending review.

| ID | Call | Default taken |
|---|---|---|
| J1 | D3's "read tools" means the 15 read tools that require `project_id` | 17-tool agent set (see Decisions) |
| J2 | D1's fall-through does not apply to the agent principal | Agent confined to its set in every posture |
| J3 | D4's scope rule covers every agent-set tool, not only `foreman_project_*` names | Schema-driven, enforced in the dispatcher |
| J4 | The injected server is named `foreman_agent`, not `foreman` | Avoids Claude's name-collision precedence with the operator's own entry |
| J5 | When the credential is injected, the write instruction is delivered even for a project with an empty memory index | Otherwise an agent in a fresh project is never told it can write |
| J6 | The feature needs `:mcp, enabled: true`, and `runtime.exs` has no switch for it | No new env var; release operators set the key in config |

## Failure scenarios considered

- **Agent in project A writes to project B's memory** — covered by REQ-006; the
  refusal is by string equality and never touches a store.
- **Token replayed after its run ends** — covered by REQ-002.
- **Projection store down while an agent calls** — covered by AC-002-2; the
  authenticator fails closed and says so.
- **Approval token used as an MCP token, or the reverse** — covered by AC-001-2.
- **A malformed agent-shaped string becomes the operator under insecure-local** —
  covered by AC-001-3.
- **Agent calls `foreman_project_settings_update`, in default or dev posture** —
  covered by AC-005-1.
- **A caller-supplied `run_id` forges the audit author** — covered by AC-006-3.
- **Merging `mcp_config` drops the approval hook, or the new server** — covered by
  AC-009-2, with a mutation proof for each side.
- **Injection lands before enforcement** — covered by the Dependency Map and the
  TRD's PR ordering; under `allow_insecure_local` an un-enforced endpoint treats
  every caller as the operator.
- **Operator workflows regress** — covered by REQ-014.
- **Guidance promises a path the launch does not have** — covered by REQ-012 and
  REQ-013.
- **Agent holds an inherited operator token or `secret_key_base`** — covered by
  REQ-017: both are unset in every agent launch the server composes, so the scoped
  credential's memory-only guarantee holds against the agent's own environment.
- **Agent holds any OTHER inherited server secret** (LANGFUSE keys, GitHub tokens,
  the webhook and notification secrets) — not mitigated here. The broader
  worker-environment policy is the named follow-up (Non-Goals); a residual risk
  until it lands.
- **A worker omits the token under `allow_insecure_local: true`** — it is the
  operator by that posture's definition (D3, AC-003-1). The scrub removes a
  secret; it does not close a posture the operator opened. The confinement holds in
  token-enforcing deployments (`allow_insecure_local: false`, the shipped default).
- **The scrub lands at one launch site only, or rides in an env map that is
  dropped** — covered by REQ-017 and the TRD's launch-site architecture test: a
  task with no project has its env map replaced before the worker starts, so the
  scrub is applied at the last hop, not in the caller's map.
- **A project's own `SECRET_KEY_BASE` is unset by the scrub** — covered by
  AC-017-4: an explicit entry wins over the scrub.
- **Hostile agent persists a prompt injection in its own project's memory** — not
  eliminated: memory already renders inside a block labelled as agent-written
  notes, not instructions, with caps and redaction. Residual, own project only.

## Dependency Map

- REQ-002 depends on REQ-001.
- REQ-003 depends on REQ-001.
- REQ-004 depends on REQ-003, REQ-005.
- REQ-005 depends on REQ-003.
- REQ-006 depends on REQ-005.
- REQ-007 depends on REQ-005.
- REQ-008 depends on REQ-005, REQ-006.
- REQ-009 depends on REQ-001, REQ-002, REQ-004, REQ-006, REQ-007, REQ-017. This is
  the ordering constraint: injection must not land before enforcement, and must not
  land before the scrub.
- REQ-010 depends on REQ-009.
- REQ-011 depends on REQ-009.
- REQ-012 depends on REQ-009.
- REQ-013 depends on REQ-012.
- REQ-014 depends on REQ-003, REQ-005.
- REQ-015 depends on REQ-009, REQ-012, REQ-017.
- REQ-016 depends on REQ-009, REQ-012, REQ-017.
- REQ-017 depends on nothing: the scrub is independent of the principal, the policy
  and the credential.

Cluster to implement together: REQ-001, REQ-002, REQ-003 (identity). Then
REQ-004, REQ-005, REQ-006, REQ-007, REQ-008 (policy and enforcement). Then
REQ-017 (worker environment) with REQ-009, REQ-010, REQ-011 (injection), the scrub
first within the cluster. Then REQ-012, REQ-013, REQ-015 (truthfulness and
documentation). REQ-014 and REQ-016 close each cluster.

No circular dependencies. No requirement depends on the deferred pi work.

## Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Completeness | 5 | D1-D6 recorded, scope and non-scope explicit, every code claim cited with a file and line, and the three independent causes of the problem each have a requirement. |
| Testability | 5 | All 48 ACs are observable outcomes: a returned principal, a refusal code, an event field, a tool list, an option map, a text, a command output, a process environment. |
| Clarity | 4 | J1 and J5 confirmed by the user (2026-11-02); J2, J3, J4 and J6 ship on stated defaults pending review. |
| Feasibility | 4 | Two external behaviours (Claude's MCP permission and precedence rules, Anubis's `handle_request/2` hook) were verified by reading documentation and source, not by a live run. REQ-016 closes that. |
| **Overall** | **4.5** | **PASS (>= 4.0)** |

**What 4.5 does not claim.** It does not claim agents are sandboxed. With REQ-017
the two server secrets that would defeat the scoping, the operator token and the
key every credential is minted from, are not inherited, so the scoped credential's
memory-only guarantee holds against the agent's own environment. Two limits remain
and are recorded: any OTHER secret the server holds in its environment is still
inherited until the broader worker-environment policy lands, and under
`allow_insecure_local: true` an absent token is the operator by definition (D3),
which the scrub neither changes nor can change. It claims the MCP tool channel is
confined, bounded in time, attributable and reviewable under a token-enforcing
posture.

## Changelog

### v1.0.0 — 2026-11-02

Initial draft.

**Decisions recorded:** D1-D5, with the operational readings J1-J3.

**Corrections to the job brief found while verifying:** (a) `foreman run submit`
posts to `/api/commands`, not `/mcp` (F18); (b) the base-URL default is derived in
`approvals/config.ex:89-110`, not in `config.exs`; (c) the write gate also lives
inside the tool bodies (F3), which the brief did not list and which D1 cannot be
implemented without addressing; (d) Anubis resolves tools before dispatch (F7), so
principal-aware visibility is a requirement (REQ-007), not a cosmetic one.

### v1.0.0, revision 1 — 2026-11-02

Before review, on the user's decision (D6) and a re-read of the agent launch paths:
**REQ-017 added** (agent environments carry neither `FOREMAN_API_TOKEN` nor
`SECRET_KEY_BASE`; 6 ACs). The scrub moves from Non-Goals into scope and the
broader worker-environment policy becomes the named follow-up. The residual-risk
wording is corrected: the memory-only guarantee holds against the two scrubbed
secrets, not against other inherited secrets or the `allow_insecure_local` posture.

**Corrections:** F16 (a pi CLI can be given a per-run MCP server through a per-run
`PI_CODING_AGENT_DIR`; still out of this slice), F17 and F18 (the Go CLI is an
`/api` client; the operator-principal MCP clients are the e2e scripts, external
clients and the stdio task), AC-006-1 (names the foreign-project memory write).

## Next step

The paired design is `docs/TRD/TRD-2026-94f379ec-agent-scoped-mcp-credential.md`.
The step beads already exist: epic `foreman-5ifqm` and its five chained, deferred children
`foreman-5ifqm.1` to `.5` (one per TRD PR). Do not run
`/ensemble:implement-trd-beads` to create a second set.
