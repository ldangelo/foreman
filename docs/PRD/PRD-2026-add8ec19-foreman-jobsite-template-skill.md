---
document_id: PRD-2026-add8ec19
label: prd-jobsite-template-skill
version: 1.0.0
status: Draft
date: 2026-10-14
scale_depth: STANDARD
author: Lead Agent
total_requirements: 18
readiness_score: 4.25
readiness_gate: PASS
---

# PRD: `foreman-jobsite-template` — author Jobsite specs from a prompt

## PRD Health Summary

- **Depth:** STANDARD (auto-selected: the authoring session was non-interactive, so interview questions were resolved by stated assumptions or marked `[NEEDS CLARIFICATION]`).
- **Risk flags:** REQ-001, REQ-006, REQ-011, REQ-013, REQ-015
- **Dependencies:** 21 cross-requirement dependencies (see Dependency Map)
- **Constitution compliance:** passed
- **Open ambiguity markers:** 6

## Product Summary

### Problem statement

Foreman's Remote Jobsite API lets a client script start an agent on a running
server by POSTing a JSON spec. Writing that spec by hand is error-prone: the
server validates it against a strict whitelist and rejects, with a specific
error code, any unknown key, any forbidden key (`on_event`, `reply_to`,
`prompt_file`, `repo_path`, `path`, `base`, `resume`, `logging`), any host-side
hook, any `agent.env` key the operator has not allowlisted, a `push` without a
named-branch strategy, or a branch name outside the accepted pattern. Today an
author learns these rules by reading `AGENTS.md`, the `Jobsite.Spec` module, and
the bundled `basic`/`iterate`/`parallel` templates, then iterating against 4xx
responses. The cost is felt by every operator who wants a jobsite shaped
differently from the three bundled templates.

### Solution overview

A skill named `foreman-jobsite-template` that takes a natural-language
description of what a jobsite should do ("loop until tests pass, push the
branch, run `mix deps.get` in the sandbox first") and produces a ready-to-run
client jobsite template — a script plus its prompt file, in the same shape as
the bundled `basic` and `iterate` templates — whose spec the server accepts
unmodified.

### Value proposition

- An operator goes from intent to a runnable, server-accepted jobsite without
  learning the spec whitelist.
- Contract violations are caught when the template is generated, not as a 4xx
  after a round-trip.
- Requests the remote API deliberately cannot honor (host hooks, client paths,
  callbacks) are refused with an explanation instead of silently dropped.

### Target users

- **Foreman operator** — runs a `foreman_server`, registers projects, wants
  custom agent runs beyond the bundled templates.
- **Coding agent acting for the operator** — invokes the skill inside a
  session to scaffold a jobsite for a task.

## User Analysis

| Role | Pain today | Success looks like |
|---|---|---|
| Operator | Hand-writing specs; discovering whitelist rules via rejected requests | Describes the run in prose, gets a template that runs first time |
| Coding agent | No authoritative, machine-followable description of the spec contract | Skill instructions encode the contract; output passes validation |

**Success metrics** (assumed; no operator-supplied targets):

- 100% of templates generated from the acceptance prompt set are accepted by
  `POST /api/jobsites` (HTTP 202/accepted, no `spec_*` error) on a server
  configured as documented in the template header.
- 0 generated templates contain a forbidden key, a `hooks.host` entry, or an
  inline secret value.
- The smoke template completes end-to-end (jobsite reaches a completed terminal
  state) on the first run.

## Goals and Non-Goals

### Goals

- Produce a server-accepted Jobsite spec, embedded in a runnable client
  template, from a natural-language prompt.
- Encode the Remote Jobsite API contract so the skill cannot emit a spec the
  whitelist would reject for structural reasons.
- Explain, rather than drop, any requested capability the remote API forbids.

### Non-Goals

- Changing the Remote Jobsite API, its whitelist, or its server configuration
  defaults. The skill conforms to the contract; it does not widen it.
- Generating Foreman-checkout scripts (`review`/`triage` style) that call
  `ForemanServer.Jobsite` directly. Only client scripts driven over HTTP are in
  scope.
- Changing server-side operator settings (`allow_remote_start`,
  `allow_host_sandbox`, `agent_env_allowlist`). The skill documents what the
  operator must enable; it never enables it.
- Adding a new bundled `foreman init --template` entry. [NEEDS CLARIFICATION:
  Should generated templates also be registerable as a named `foreman init
  --template` option, or remain one-off files in the operator's `.foreman/`?]

## Assumptions (resolved without interview)

- A1: "Skills surface" means the place agent skills are discovered by name in a
  coding-agent session for this repo. [NEEDS CLARIFICATION: Should the skill
  ship in this repository (repo-local, available when working in Foreman), in
  the ensemble plugin (available everywhere ensemble is installed, including the
  jobsite Docker image), or both?]
- A2: Output is written into the target project's `.foreman/` directory using
  the same layout as `foreman init --template` (`<name>.exs`,
  `prompts/<name>.md`), so the existing `shared/README.md` guidance applies.
- A3: The generated script uses the `foreman_client` package the same way the
  bundled client templates do; it introduces no new dependency.
- A4: The project id, API URL, and token are supplied at run time from the
  environment (`FOREMAN_PROJECT_ID`, `FOREMAN_API_URL`, `FOREMAN_API_TOKEN`),
  exactly as in `basic`/`iterate`; they are never written into the template.

## Requirements by Feature Area

### Feature area: Skill discovery and invocation

### REQ-001: Skill is discoverable under the name `foreman-jobsite-template`
**Priority:** Must  [RISK: discovery location is unresolved — see A1]

The skill appears by that exact name in the skills list of a session where it is
installed, with a one-line description stating that it authors Jobsite specs
from a prompt.

- AC-001-1: Given a session where the skill is installed, when the user lists
  available skills, then `foreman-jobsite-template` appears with a description
  mentioning Jobsite spec authoring.
- AC-001-2: Given a session where the skill is installed, when the user invokes
  it by name with a prompt, then the skill's instructions load and it begins
  generation without the user restating the prompt.

### REQ-002: Skill accepts a natural-language prompt as its input
**Priority:** Must

- AC-002-1: Given an invocation with a non-empty prompt, when the skill runs,
  then it treats the prompt as the description of the jobsite's behavior and
  of the agent's task.
- AC-002-2: Given an invocation with no prompt or a blank prompt, when the skill
  runs, then it stops and asks for (or, non-interactively, reports the absence
  of) a description, and writes no files.

### REQ-003: Skill resolves missing essentials before generating
**Priority:** Should

When the prompt does not determine a required choice (template name, one-shot
vs. looping, sandbox kind), the skill asks one question at a time in an
interactive session, or applies the documented default and records it in the
template header in a non-interactive one.

- AC-003-1: Given a prompt that does not say whether the agent should loop, when
  the skill runs non-interactively, then the template is single-iteration and
  its header states that this default was applied.
- AC-003-2: Given an interactive session and a prompt that omits the template
  name, when the skill runs, then it asks for a name (offering a derived
  suggestion) before writing files.

### Feature area: Prompt-to-spec mapping

### REQ-004: Map described behaviors onto supported spec fields
**Priority:** Must

Each behavior the prompt describes is expressed with the spec field the server
documents for it, and only with whitelisted top-level keys (`project_id`,
`prompt`, `agent`, `strategy`, `sandbox`, `name`, `max_iterations`,
`completion_signal`, `idle_timeout_seconds`, `completion_timeout_seconds`,
`hooks`, `exclude_paths`, `copy_to_worktree`, `resume_session`, `push`).
Required keys `project_id`, `prompt`, and `agent` are always present.

- AC-004-1: Given a prompt asking the agent to "keep going until done, at most 15
  turns", when the template is generated, then the spec sets `max_iterations`
  to 15 and a `completion_signal`, and the prompt file instructs the agent to
  emit that signal when finished.
- AC-004-2: Given a prompt asking for "a single pass", when the template is
  generated, then the spec sets neither `max_iterations` nor
  `completion_signal`.
- AC-004-3: Given any generated template, when its spec's top-level keys are
  compared with the whitelist, then every key is in the whitelist and
  `project_id`, `prompt`, and `agent` are present.

### REQ-005: The agent's task text is sent inline, never as a file reference
**Priority:** Must

The task portion of the prompt is written to the template's prompt file and the
script reads that file client-side and sends its text as `prompt`. The spec
never carries `prompt_file` or a path.

- AC-005-1: Given a generated template, when its spec is built, then `prompt` is
  a non-empty string and no key named `prompt_file`, `repo_path`, `path`, or
  `base` is present.
- AC-005-2: Given a prompt file containing `{{PLACEHOLDER}}` tokens, when the
  script runs, then the script fills them before sending, and a token with no
  value stops the script with an error before any request is made.

### REQ-006: Branch and push behavior follow the strategy rules
**Priority:** Must  [RISK: a valid-looking branch name the server pattern rejects fails only at POST time]

- AC-006-1: Given a prompt asking to "push the branch when done", when the
  template is generated, then the spec sets `push: true` and a
  `{"branch": <name>}` strategy.
- AC-006-2: Given a prompt requesting push together with "commit onto HEAD" or a
  merge-to-head strategy, when the skill runs, then it refuses the combination,
  explains that only a named branch can be published, and offers the branch
  form instead.
- AC-006-3: Given any generated branch name, when checked against the server's
  branch pattern (starts with an alphanumeric; then only letters, digits, `.`,
  `_`, `/`, `-`), then it matches.

### REQ-007: Agent configuration uses only accepted fields and values
**Priority:** Must

`agent` contains only `provider`, `model`, `effort`, `approval_mode`, and
`env`. `provider` is one the server supports (currently `pi`, `claude`,
`litellm`); `effort`, when present, is one of `minimal`, `low`, `medium`,
`high`, `xhigh`. The provider is chosen explicitly, never inferred from the model
name.

- AC-007-1: Given a prompt that names a model but no provider, when the skill
  runs, then it asks for (or defaults and records) the provider rather than
  deriving it from the model string.
- AC-007-2: Given a prompt asking for "maximum effort", when the template is
  generated, then `agent.effort` is `xhigh`.
- AC-007-3: Given a prompt naming an unsupported provider, when the skill runs,
  then it refuses with the list of supported providers.

### REQ-008: Agent environment passes names, never values
**Priority:** Must

When the prompt needs environment variables in the agent (e.g. an API base URL
or key), the template forwards them by **name** from the operator's shell at run
time, exactly as `iterate` does with `FOREMAN_AGENT_ENV`, and its header states
that the server must allowlist each name.

- AC-008-1: Given a prompt saying "the agent needs ANTHROPIC_API_KEY", when the
  template is generated, then the file contains the variable name but no value,
  and the header names `FOREMAN_JOBSITES_AGENT_ENV_ALLOWLIST` as the server
  setting that must include it.
- AC-008-2: Given the user pastes a literal secret value into the prompt, when
  the skill runs, then the value does not appear in any generated file and the
  skill tells the user it was replaced by an environment-variable reference.
- AC-008-3: Given a template whose listed env variable is unset in the shell,
  when the script runs, then it stops with an error naming the variable before
  any request is made.

### REQ-009: Setup steps run as sandbox hooks only
**Priority:** Must

Setup actions ("install deps before the agent starts") become `hooks.sandbox`
entries under `on_worktree_ready` or `on_sandbox_ready`.

- AC-009-1: Given a prompt asking to run `mix deps.get` before the agent starts,
  when the template is generated, then the spec carries it under
  `hooks.sandbox` at a supported phase and contains no `hooks.host` key.
- AC-009-2: Given a prompt asking to run a command "on the server" or "on the
  host", when the skill runs, then it refuses the host hook, explains that the
  remote API forbids it, and offers the sandbox hook equivalent.

### REQ-010: Sandbox choice defaults to Docker
**Priority:** Must

- AC-010-1: Given a prompt that does not mention a sandbox, when the template is
  generated, then the spec uses the default (`docker`, explicit or omitted) and
  the header carries the image-build instructions from the bundled templates.
- AC-010-2: Given a prompt that asks for the `host` sandbox, when the template is
  generated, then the spec sets `sandbox: "host"` and the header states that the
  server refuses it unless the operator enabled `allow_host_sandbox`.

### REQ-011: Requests the remote API cannot honor are refused with an alternative
**Priority:** Must  [RISK: the refusal list must stay in sync with the server whitelist]

Event callbacks (`on_event`/`reply_to`), client file paths, resume-by-flag,
logging configuration, host hooks, and caller-chosen push remotes are not
expressible remotely.

- AC-011-1: Given a prompt asking to "call my webhook on every event", when the
  skill runs, then it explains that event callbacks are not part of the remote
  spec and suggests polling the jobsite status from the script instead.
- AC-011-2: Given a prompt asking to push to a remote other than `origin`, when
  the skill runs, then it explains the remote is fixed to `origin` and does not
  emit a remote field.

### REQ-012: Optional scope controls map when requested
**Priority:** Could

`name`, `idle_timeout_seconds`, `completion_timeout_seconds`, `exclude_paths`,
`copy_to_worktree`, and `resume_session` are set only when the prompt asks for
the matching behavior.

- AC-012-1: Given a prompt asking that the agent "never touch vendor/", when the
  template is generated, then `exclude_paths` includes `vendor/`.
- AC-012-2: Given a prompt that mentions none of these behaviors, when the
  template is generated, then none of these keys is present.

### Feature area: Template output

### REQ-013: Output is a runnable client template in the bundled layout
**Priority:** Must  [RISK: depends on A2/A3]

The skill writes `<name>.exs` and `prompts/<name>.md` under the target
project's `.foreman/`, structured like the bundled `basic`/`iterate` templates:
a header explaining how to run it and which server settings it needs; loading
of the client package; reading of `FOREMAN_PROJECT_ID`; spec construction; a
run-and-wait call; a one-line success summary; a non-zero exit on failure.

- AC-013-1: Given a generated template, when run with `elixir .foreman/<name>.exs`
  and the documented environment, then it submits the spec and waits for a
  terminal state without further edits.
- AC-013-2: Given `.foreman/<name>.exs` already exists, when the skill would
  write it, then it does not overwrite silently: it asks (interactive) or
  stops and reports the conflict (non-interactive).
- AC-013-3: Given a jobsite that ends in a failure state, when the script
  finishes, then it prints the reason to stderr and exits non-zero.

### REQ-014: The skill validates the spec against the contract before writing
**Priority:** Must

Before writing files, the skill checks the spec it built against the contract
rules in REQ-004 to REQ-011 and does not write a template that fails any of
them.

- AC-014-1: Given an internally built spec containing a non-whitelisted key,
  when the pre-write check runs, then generation stops and reports the key.
- AC-014-2: Given a spec that passes the check, when the skill finishes, then it
  prints the files written and the exact command to run the template.

### REQ-015: The skill's contract knowledge cannot silently drift from the server
**Priority:** Should  [RISK: the server whitelist can change without the skill changing]

- AC-015-1: Given the server's accepted key list, forbidden key list, agent key
  list, hook targets/phases, and effort values, when the repository's test
  suite runs, then a test fails if any of them differs from what the skill
  documents.
- AC-015-2: Given a change that adds a key to the server whitelist, when the
  test suite runs without a matching skill update, then the failure names the
  added key.

### Feature area: Verification

### REQ-016: A generated template smoke-runs end to end
**Priority:** Must

- AC-016-1: Given a running server with remote start enabled, a registered
  project, and a valid token, when a template generated from the smoke prompt
  is run, then `POST /api/jobsites` accepts the spec and the jobsite reaches a
  completed terminal state with its branch reported.
- AC-016-2: Given the same server with remote start disabled, when the template
  is run, then the script exits non-zero and prints the server's refusal
  instead of hanging. [NEEDS CLARIFICATION: Which server — local dev
  (`devbox run up`) or a shared instance — is the reference environment for the
  acceptance smoke run, and which provider/model should it use?]

## Non-Functional Requirements

### REQ-017: No secrets in generated artifacts
**Priority:** Must

- AC-017-1: Given any generated template, when scanned, then it contains no
  token, API key, or password value — only environment-variable names.
- AC-017-2: Given the server token, when the template runs, then it is read
  from `FOREMAN_API_TOKEN` at run time and never printed.

### REQ-018: Documentation reflects the new skill
**Priority:** Must

- AC-018-1: Given the skill ships, when an operator reads the Jobsite section of
  the user-facing docs and the templates README, then they find what the skill
  does, how to invoke it, and the server settings generated templates may
  require.
- AC-018-2: Given the skill's refusal list, when compared with the Remote
  Jobsite API section of `AGENTS.md`, then they describe the same forbidden
  capabilities. [NEEDS CLARIFICATION: Which docs are canonical for skills —
  `docs/user-guide.md`, `AGENTS.md`, or a skill-local README?]

## Approvals and Decision Ownership

- **Approver:** the Foreman maintainer/operator (product owner role).
- **Criteria:** the skill is discoverable by name; a prompt yields a template
  whose spec `POST /api/jobsites` accepts; the smoke template completes end to
  end; no forbidden capability can be emitted; documentation updated.
- Any change that would require widening the server whitelist is out of scope
  and needs a separate decision (constitution §5, breaking API changes).

## Entry and Exit Criteria

**Entry**
- The Remote Jobsite API and `foreman_client` are merged and usable (true as of
  2026-10).
- The discovery location for the skill (A1) is decided.
- A reference server for the smoke run is available (REQ-016 clarification).

**Exit**
- All Must requirements' ACs pass.
- The contract-drift test (REQ-015) is in the suite and green.
- The smoke run (REQ-016) has been executed and its result recorded.
- Documentation updated (REQ-018).

## Dependency Map

- REQ-002 depends on REQ-001
- REQ-003 depends on REQ-002
- REQ-004 depends on REQ-002
- REQ-005 depends on REQ-004
- REQ-006 depends on REQ-004
- REQ-007 depends on REQ-004
- REQ-008 depends on REQ-007
- REQ-009 depends on REQ-004
- REQ-010 depends on REQ-004
- REQ-011 depends on REQ-004
- REQ-012 depends on REQ-004
- REQ-013 depends on REQ-004, REQ-005
- REQ-014 depends on REQ-005, REQ-006, REQ-007, REQ-008, REQ-009, REQ-011
- REQ-015 depends on REQ-014
- REQ-016 depends on REQ-013, REQ-014
- REQ-017 depends on REQ-008, REQ-013
- REQ-018 depends on REQ-011

**Clusters:** {REQ-001..003} invocation; {REQ-004..012, REQ-014} mapping and
validation (implement together — the validator is the mapping's contract);
{REQ-013, REQ-016, REQ-017} output and smoke; {REQ-015, REQ-018} drift and docs.
No circular dependencies.

## Self-Critique (auto-applied; non-interactive session)

1. **Gap — no server dry-run.** The server has no validate-only endpoint, so
   acceptance is only provable by starting a jobsite. Resolution: REQ-014
   validates offline; REQ-016 proves acceptance live.
   [NEEDS CLARIFICATION: Is a validate-only server route desired as a follow-up?]
2. **Ambiguity — "skills surface".** Resolution: recorded as A1 with a
   clarification marker; REQ-001 flagged as a risk.
3. **Contradiction risk — host sandbox.** Emitting `sandbox: "host"` is valid
   but refused by default servers. Resolution: REQ-010 AC-010-2 requires the
   header to state the operator prerequisite.
4. **Missing edge case — secrets in prompts.** Resolution: AC-008-2.
5. **Missing edge case — overwrite.** Resolution: AC-013-2.
6. **Testability — "end to end".** Resolution: AC-016-1 defines end as a
   completed terminal state with a reported branch.

## Readiness Scorecard

| Dimension | Score |
|---|---:|
| Completeness | 4 |
| Testability | 5 |
| Clarity | 4 |
| Feasibility | 4 |
| **Overall** | **4.25 — PASS** |

Constitution compliance: passed (Article 1 TDD/tests: REQ-015, REQ-016;
Non-Negotiable 1 no secrets: REQ-008, REQ-017; Non-Negotiable 2 input
validation: REQ-002, REQ-014; Article 5 no new dependencies: A3; Article 8
documentation: REQ-018).
