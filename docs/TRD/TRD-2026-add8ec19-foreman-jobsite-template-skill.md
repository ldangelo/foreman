---
document_id: TRD-2026-add8ec19
label: trd-jobsite-template-skill
prd: docs/PRD/PRD-2026-add8ec19-foreman-jobsite-template-skill.md
prd_document_id: PRD-2026-add8ec19
version: 1.0.0
status: Draft
date: 2026-10-14
kind: trd
design_readiness_score: 4.25
design_readiness_gate: PASS
constitution_compliance: passed
---

# TRD: `foreman-jobsite-template` skill

## Summary

Ship a repo-local agent skill that turns a natural-language prompt into a
runnable client Jobsite template (`.foreman/<name>.exs` + `prompts/<name>.md`)
whose spec `POST /api/jobsites` accepts. The skill's knowledge of the Remote
Jobsite API contract lives in a machine-readable contract file that a server
test pins to `ForemanServer.Jobsite.Spec`, and every generated template can
print its spec offline (dry run) so it is checked before it is ever sent.

Brownfield. No new dependencies (constitution §5). No change to the Remote
Jobsite API's accepted shape, auth, or operator gates.

## PRD Validation

- PRD readiness 4.25 (PASS). Structure complete; REQ-001..018 sequential.
- BDD coverage note: several PRD functional requirements carry 2 ACs, not 3.
  Test tasks below add a third (error/negative) scenario derived from the
  requirement text where the PRD has only two; these are marked "(derived)".
- Open PRD clarifications carried forward and resolved by default here (see
  Decisions D1–D4); each is revisitable in `/ensemble:refine-trd`.

## Decisions on PRD Open Questions

- **D1 — skill location (PRD A1).** Ship at
  `.claude/skills/foreman-jobsite-template/` in this repo (repo-local discovery
  in Claude Code sessions opened on Foreman). `.claude/` is not gitignored.
  Packaging into the ensemble plugin (so the jobsite Docker image has it) is a
  follow-up, not this slice. [NEEDS CLARIFICATION: confirm repo-local is
  sufficient for acceptance.]
- **D2 — named `foreman init --template` registration.** Out of scope; the
  generated template is a one-off file in the operator's `.foreman/`.
- **D3 — server validate-only route.** Out of scope (would widen the API,
  constitution §5). Offline validation (TRD-003) plus the live 202 test
  (TRD-006-TEST) cover acceptance.
- **D4 — smoke reference environment.** Local dev server (`devbox run up`,
  `mix phx.server`) with `FOREMAN_JOBSITES_ALLOW_REMOTE_START=true`, `host`
  sandbox enabled, `claude` provider. [NEEDS CLARIFICATION: confirm provider and
  model for the recorded smoke run.]
- **Provider list source.** PRD REQ-007 lists `pi`/`claude`/`litellm` from
  CLAUDE.md §5.1, but `JidoHarness.providers/0` currently returns
  `[:pi, :claude]`. The contract takes providers from code, and the drift test
  pins it there. CLAUDE.md §5.1's `litellm` mention is a pre-existing doc
  discrepancy to flag in TRD-008, not to fix by widening the list.

## Architecture Decision

### Option A — Prose-only skill

`SKILL.md` restates the whitelist in prose; the agent writes the script by hand.
- Pros: one file, fastest.
- Cons: nothing checks the output before POST; prose drifts silently from
  `Spec` (fails REQ-014, REQ-015).

### Option B — Server-side generation/validation endpoint

Add `POST /api/jobsites/validate` (and perhaps a generator route); the skill
calls it.
- Pros: authoritative validation by the real `Spec.from_json/2`.
- Cons: widens the public API (constitution §5 approval), needs a live server
  and token just to author a file, adds an auth/audit surface.

### Option C — Skill + contract file + offline checker + dry-run template (chosen)

- `SKILL.md` drives the conversation and mapping.
- `contract.json` is the single machine-readable copy of the whitelist, pinned
  to `Spec` by an ExUnit drift test.
- `check_spec.exs` validates a spec against `contract.json` with plain Elixir
  (OTP 27+ `:json`), no server and no network.
- Every generated script supports `FOREMAN_JOBSITE_DRY_RUN=1`: it builds the
  spec, prints it as JSON (env values replaced by references), and exits before
  loading `foreman_client`.
- Pros: catches violations at generation time; drift fails CI; no API change; no
  new dependency; reuses the `basic`/`iterate` shape.
- Cons: the offline checker cannot see server-only state (project registration,
  operator flags); those are covered by the template header and the live test.

Option C is the best fit for the existing codebase: it matches how the bundled
client templates already work and keeps `Spec.from_json/2` the only authority
the server applies.

## System Architecture

### Components

| Component | Path | Responsibility |
|---|---|---|
| Skill instructions | `.claude/skills/foreman-jobsite-template/SKILL.md` | Frontmatter `name`/`description`; workflow: read prompt → resolve essentials → map → refuse unsupported → render → dry-run + check → write → report |
| Contract | `.claude/skills/foreman-jobsite-template/contract.json` | `allowed_keys`, `required_keys`, `forbidden_keys`, `agent_keys`, `providers`, `approval_modes`, `efforts`, `hook_targets`, `hook_phases`, `branch_pattern`, `default_sandbox`, `push_remote`, plus a `refusals` catalogue (capability → reason → alternative) |
| Script skeleton | `.claude/skills/foreman-jobsite-template/reference/template.exs` | Canonical client script with placeholders the skill fills; dry-run mode; env-by-name; `{{PLACEHOLDER}}` fill; non-zero exit on failure |
| Offline checker | `.claude/skills/foreman-jobsite-template/scripts/check_spec.exs` | `elixir check_spec.exs < spec.json` → exit 0 / exit 1 with one line per violation (rule id + key) |
| Examples | `.claude/skills/foreman-jobsite-template/examples/<name>/` | Templates generated from the golden prompt set (one-shot, iterate+push, sandbox hook, env passthrough, smoke) |
| Server contract accessor | `ForemanServer.Jobsite.Spec.contract/0` | Public read of the existing module attributes; no behavior change |
| Drift test | `packages/foreman_server/test/foreman_server/jobsite/spec_contract_drift_test.exs` | Compares `contract.json` with `Spec.contract/0`, `Agent.approval_mode_names/0`, `JidoHarness.providers/0` |
| Acceptance test | `packages/foreman_server/test/foreman_server_web/controllers/jobsite_template_skill_test.exs` | Runs each example in dry-run, checks it, POSTs it to `/api/jobsites` in the controller-test harness, expects 202 |

### Data flow

```
prompt ──▶ SKILL.md workflow ──▶ fills reference/template.exs + prompts/<name>.md
                                    │
                    FOREMAN_JOBSITE_DRY_RUN=1 elixir <name>.exs
                                    │ spec JSON (env values → "${NAME}")
                                    ▼
                          scripts/check_spec.exs ◀── contract.json ◀── drift test ── Spec.contract/0
                                    │ ok
                                    ▼
                    write .foreman/<name>.exs, prompts/<name>.md; print run command
                                    │ (operator, later)
                    elixir .foreman/<name>.exs ──▶ foreman_client ──▶ POST /api/jobsites
```

### Interfaces

- **Dry-run contract.** `FOREMAN_JOBSITE_DRY_RUN=1`: stdout is exactly one JSON
  object (the spec), exit 0; no network, no `Mix.install`. `project_id` is read
  from `FOREMAN_PROJECT_ID` or, in dry run only, defaults to
  `"dry-run-project"`. `agent.env` values print as `"${NAME}"`. Any error
  (missing env var listed in `FOREMAN_AGENT_ENV`, unfilled placeholder) prints
  to stderr and exits 1.
- **Checker contract.** Input: spec JSON on stdin (or path arg). Output: exit 0
  and nothing on stdout when valid; exit 1 and lines
  `VIOLATION <rule> <detail>` otherwise. Rules: `unknown_key`, `forbidden_key`,
  `missing_required`, `prompt_not_string`, `agent_unknown_key`,
  `provider_unsupported`, `effort_invalid`, `approval_mode_invalid`,
  `hooks_host_forbidden`, `hook_target_invalid`, `hook_phase_invalid`,
  `push_requires_branch`, `branch_name_invalid`, `env_value_inline`,
  `non_json_value`. The checker reports all violations, not just the first.
- **`Spec.contract/0`.** Returns
  `%{allowed_keys: [...], forbidden_keys: [...], agent_keys: [...], efforts: [...], hook_targets: [...], hook_phases: [...], branch_pattern: String.t()}`
  built from the existing attributes (`Regex.source/1` for the pattern).
- **Contract JSON vs. server.** The checker deliberately does not model
  server-only state: project registration, `allow_remote_start`,
  `allow_host_sandbox`, `agent_env_allowlist`, capacity. Those are stated in the
  generated header.

### Error handling and failure paths

- Checker violation during generation → skill does not write files, shows the
  violations, and either repairs the mapping (if the violation came from the
  skill) or explains the refusal (if it came from the request).
- Target file exists → skill asks (interactive) or stops and reports
  (non-interactive); never overwrites silently.
- Runtime: `Foreman.Client.run/2` `{:error, reason}` → stderr + `System.halt(1)`
  (same as `basic`/`iterate`).

## Reused Capabilities

None registered (`trd-graph-cli capabilities docs/TRD` returned an empty
registry). Reuses existing code only: `Jobsite.Spec`, `Jobsite.Agent`,
`AgentRuntime.JidoHarness`, `foreman_client`, the `JobsiteControllerTest`
harness pattern.

## Master Task List

### PR 1: Machine-checked spec contract

**Shippable State:** An author (human or agent) can run `elixir scripts/check_spec.exs < spec.json` to see every reason the server would structurally reject a spec, and CI fails if the server's spec whitelist changes without the contract file changing.

- [ ] **TRD-001**: Add `ForemanServer.Jobsite.Spec.contract/0` returning the existing whitelist attributes and `branch_pattern` source; no change to `from_json/2` (2h) [satisfies REQ-015] [satisfies ARCH]
  - Validates PRD ACs: AC-015-1
  - Implementation AC:
    - [ ] Given the module compiled, when `Spec.contract/0` is called, then it returns maps whose lists equal `@allowed_keys`, `@forbidden_keys`, `@agent_keys`, `@efforts`, `@hook_targets`, `@hook_phases`
    - [ ] Given the existing `Spec` test suite, when run after the change, then it passes unchanged
- [ ] **TRD-002**: Author `contract.json` (keys, providers, approval modes, efforts, hooks, branch pattern, default sandbox `docker`, push remote `origin`, refusals catalogue with reason + alternative per forbidden capability) (2h) [satisfies REQ-004] [satisfies REQ-011] [depends: TRD-001]
  - Validates PRD ACs: AC-004-3, AC-011-1, AC-011-2
  - Implementation AC:
    - [ ] Given `contract.json`, when parsed by OTP `:json.decode/1`, then it decodes without error
    - [ ] Given the refusals catalogue, when listed, then it has an entry for `on_event`, `reply_to`, `prompt_file`, `repo_path`, `path`, `base`, `resume`, `resume?`, `logging`, `hooks.host`, and custom push remote
- [ ] **TRD-002-TEST**: Contract drift test comparing `contract.json` with `Spec.contract/0`, `Agent.approval_mode_names/0`, `JidoHarness.providers/0` (3h) [verifies TRD-002] [satisfies REQ-015] [depends: TRD-001, TRD-002]
  - Validates PRD ACs: AC-015-1, AC-015-2
  - Note: implement-trd-beads will run reqnroll-cli generate-bindings against the PRD to scaffold these scenarios, then delegate reqnroll-binding-specialist to fill bodies test-first; in this Elixir repo the scenarios are realized as ExUnit tests.
  - Test AC:
    - [ ] Scenario: contract in sync -- Given `contract.json` matches the server lists, When the drift test runs, Then it passes
    - [ ] Scenario: server adds a key -- Given a server allowed-key list with one extra key, When compared, Then the failure message names that key
    - [ ] Scenario: provider list diverges (derived) -- Given `contract.json` lists a provider `JidoHarness.providers/0` lacks, When compared, Then the test fails naming the provider
- [ ] **TRD-003**: Implement `scripts/check_spec.exs` offline checker over `contract.json` reporting every violation by rule id (5h) [satisfies REQ-014] [satisfies REQ-005] [satisfies REQ-006] [satisfies REQ-007] [satisfies REQ-009] [depends: TRD-002]
  - Validates PRD ACs: AC-014-1, AC-005-1, AC-006-3, AC-009-1
  - Implementation AC:
    - [ ] Given a valid spec on stdin, when the checker runs, then it exits 0 with empty stdout
    - [ ] Given a spec with two violations, when the checker runs, then it exits 1 and prints two `VIOLATION` lines
    - [ ] Given a spec with `agent.env` whose value is not `${NAME}` form, when checked, then `env_value_inline` is reported
- [ ] **TRD-003-TEST**: ExUnit tests driving `check_spec.exs` via `System.cmd("elixir", ...)` across every rule id (4h) [verifies TRD-003] [satisfies REQ-014] [satisfies REQ-006] [satisfies REQ-009] [depends: TRD-003]
  - Validates PRD ACs: AC-014-1, AC-004-3, AC-005-1, AC-006-1, AC-006-3, AC-009-1, AC-007-3
  - Test AC:
    - [ ] Scenario: unknown key rejected -- Given a spec with key `webhook`, When checked, Then exit 1 with `VIOLATION unknown_key webhook`
    - [ ] Scenario: required keys present -- Given a spec missing `agent`, When checked, Then `missing_required agent` is reported
    - [ ] Scenario: prompt_file forbidden -- Given a spec with `prompt_file`, When checked, Then `forbidden_key prompt_file` is reported
    - [ ] Scenario: push with branch accepted -- Given `push: true` and `strategy: {"branch": "agent/x"}`, When checked, Then exit 0
    - [ ] Scenario: bad branch name -- Given branch `-bad name`, When checked, Then `branch_name_invalid` is reported
    - [ ] Scenario: host hook forbidden -- Given `hooks.host.on_worktree_ready`, When checked, Then `hooks_host_forbidden` is reported
    - [ ] Scenario: unsupported provider -- Given `agent.provider` `gemini`, When checked, Then `provider_unsupported gemini` is reported

### PR 2: Dry-runnable template skeleton

**Shippable State:** A hand-filled copy of the reference skeleton runs against a server exactly like `iterate.exs`, and with `FOREMAN_JOBSITE_DRY_RUN=1` prints its spec as JSON offline so it can be checked before sending.

- [ ] **TRD-004**: Write `reference/template.exs` skeleton: header slots (run instructions, required server settings), spec built before `Mix.install`, dry-run branch, `FOREMAN_AGENT_ENV` names-only passthrough, `{{PLACEHOLDER}}` fill with fail-on-unfilled, run-and-wait, summary line, non-zero exit on failure (5h) [satisfies REQ-013] [satisfies REQ-005] [satisfies REQ-008] [satisfies REQ-017] [depends: TRD-003]
  - Validates PRD ACs: AC-013-1, AC-013-3, AC-005-2, AC-008-1, AC-008-3, AC-017-1, AC-017-2
  - Implementation AC:
    - [ ] Given `FOREMAN_JOBSITE_DRY_RUN=1` and no network, when the skeleton runs, then it prints one JSON object and exits 0 without calling `Mix.install`
    - [ ] Given `FOREMAN_AGENT_ENV=FOO` and `FOO` set, when dry-run, then `agent.env.FOO` is `"${FOO}"`, never the value
    - [ ] Given an unfilled `{{X}}` in the prompt file, when run, then it exits 1 naming `X` before any request
- [ ] **TRD-004-TEST**: ExUnit tests running a filled skeleton in dry-run and against a stub HTTP server for the failure path (4h) [verifies TRD-004] [satisfies REQ-013] [satisfies REQ-008] [satisfies REQ-017] [depends: TRD-004]
  - Validates PRD ACs: AC-013-1, AC-013-3, AC-005-2, AC-008-1, AC-008-3, AC-017-1, AC-017-2
  - Test AC:
    - [ ] Scenario: dry run is offline JSON -- Given dry-run mode, When the script runs, Then stdout decodes to a spec that passes `check_spec.exs`
    - [ ] Scenario: env passed by name -- Given `FOREMAN_AGENT_ENV=SECRET_X` with value `s3cr3t`, When dry-run, Then stdout contains `${SECRET_X}` and not `s3cr3t`
    - [ ] Scenario: unset env var stops early -- Given `FOREMAN_AGENT_ENV=MISSING` unset, When run, Then exit 1 naming `MISSING` and no request is made
    - [ ] Scenario: unfilled placeholder stops early -- Given prompt text with `{{TICKET}}` and no value, When run, Then exit 1 naming `TICKET`
    - [ ] Scenario: failed jobsite exits non-zero -- Given a stub server answering the jobsite as failed, When run, Then stderr carries the reason and exit is 1
    - [ ] Scenario: token never printed -- Given `FOREMAN_API_TOKEN=tok123`, When the script runs in either mode, Then neither stdout nor stderr contains `tok123`

### PR 3: The skill and its golden examples

**Shippable State:** In a Claude Code session on this repo, `foreman-jobsite-template` is listed as a skill; given a prompt it writes a `.foreman/<name>.exs` + prompt file whose spec the server accepts with 202, and it refuses host hooks, callbacks, and paths with an alternative.

- [ ] **TRD-005**: Write `SKILL.md`: frontmatter (`name: foreman-jobsite-template`, description); workflow steps; mapping table (behavior phrase → spec field); defaults table (single pass, `docker`, provider `claude`, recorded in header); one-question-at-a-time essentials when interactive; refusal handling from `contract.json`; secret-scrubbing rule; overwrite rule; mandatory dry-run + `check_spec.exs` before write; final report with run command (6h) [satisfies REQ-001] [satisfies REQ-002] [satisfies REQ-003] [satisfies REQ-004] [satisfies REQ-006] [satisfies REQ-007] [satisfies REQ-008] [satisfies REQ-009] [satisfies REQ-010] [satisfies REQ-011] [satisfies REQ-012] [satisfies REQ-013] [satisfies REQ-014] [depends: TRD-004]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-002-1, AC-002-2, AC-003-1, AC-003-2, AC-004-1, AC-004-2, AC-006-1, AC-006-2, AC-007-1, AC-007-2, AC-008-2, AC-009-2, AC-010-1, AC-010-2, AC-011-1, AC-011-2, AC-012-1, AC-012-2, AC-013-2, AC-014-2
  - Implementation AC:
    - [ ] Given the skill file, when its frontmatter is parsed, then `name` is `foreman-jobsite-template` and `description` mentions Jobsite spec authoring
    - [ ] Given the workflow, when read, then the dry-run + checker step precedes every file write
    - [ ] Given the refusal section, when read, then every refusal is sourced from `contract.json`, not restated independently
- [ ] **TRD-005-TEST**: Lint test for `SKILL.md` frontmatter and its references (every referenced file exists; every rule id the skill names exists in the checker) (2h) [verifies TRD-005] [satisfies REQ-001] [satisfies REQ-011] [depends: TRD-005]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-011-1
  - Test AC:
    - [ ] Scenario: frontmatter valid -- Given `SKILL.md`, When its frontmatter is parsed, Then `name` equals the directory name `foreman-jobsite-template`
    - [ ] Scenario: references resolve -- Given every relative path `SKILL.md` mentions, When checked, Then each file exists
    - [ ] Scenario: refusal catalogue linked (derived) -- Given `SKILL.md`, When scanned, Then it points at `contract.json` refusals and names no forbidden capability absent from it
- [ ] **TRD-006**: Generate the golden examples with the skill from a fixed prompt set (one-shot fix, iterate-until-done with push, sandbox setup hook, env passthrough, scope controls, smoke "write HELLO.md") and commit them under `examples/` with their source prompts (4h) [satisfies REQ-004] [satisfies REQ-006] [satisfies REQ-008] [satisfies REQ-009] [satisfies REQ-012] [satisfies REQ-016] [depends: TRD-005]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-006-1, AC-008-1, AC-009-1, AC-012-1, AC-016-1
  - Implementation AC:
    - [ ] Given each example, when dry-run and checked, then the checker exits 0
    - [ ] Given each example directory, when listed, then it contains `prompt.txt`, `<name>.exs`, `prompts/<name>.md`
- [ ] **TRD-006-TEST**: Acceptance test: for each example, dry-run → `check_spec.exs` → POST to `/api/jobsites` in the `JobsiteControllerTest` harness (registered non-git project, remote start on, host sandbox allowed for host examples, env allowlist set) → 202; plus negative POSTs for refused shapes (5h) [verifies TRD-006] [satisfies REQ-016] [satisfies REQ-014] [satisfies REQ-004] [depends: TRD-006, TRD-003]
  - Validates PRD ACs: AC-016-1, AC-014-2, AC-004-1, AC-004-2, AC-006-1, AC-009-1, AC-012-2, AC-016-2
  - Test AC:
    - [ ] Scenario: one-shot example accepted -- Given the one-shot example's dry-run spec, When POSTed, Then 202 with a `js-` id
    - [ ] Scenario: iterate+push example accepted -- Given the iterate example, When POSTed, Then 202 and the spec carries `max_iterations`, `completion_signal`, `push`, branch strategy
    - [ ] Scenario: hook example accepted -- Given the sandbox-hook example, When POSTed, Then 202 and no `hooks.host` exists
    - [ ] Scenario: no unrequested optional keys -- Given the one-shot example, When its spec is read, Then none of `exclude_paths`, `copy_to_worktree`, `resume_session`, timeouts is present
    - [ ] Scenario: remote start disabled -- Given `allow_remote_start` unset, When an example spec is POSTed, Then 403 (script would exit non-zero)

### PR 4: Smoke run and documentation

**Shippable State:** Operators can find the skill in the user guide and templates README, and a recorded end-to-end smoke run shows a generated template completing on a live server.

- [ ] **TRD-007**: Smoke run: start local dev server per D4, run the smoke example (no edits) end to end, record command, jobsite id, terminal status, branch, and commit count in the PR description (3h) [satisfies REQ-016] [depends: TRD-006]
  - Validates PRD ACs: AC-016-1, AC-016-2
  - Implementation AC:
    - [ ] Given the dev server with remote start on, when the smoke example runs, then the jobsite reaches `completed` and the script prints `branch=...`
    - [ ] Given remote start off, when the smoke example runs, then it exits non-zero with the server's refusal
- [ ] **TRD-007-TEST**: Opt-in live smoke test tagged `:jobsite_smoke` (excluded by default) running the smoke example against `FOREMAN_API_URL` and asserting completion (3h) [verifies TRD-007] [satisfies REQ-016] [depends: TRD-007]
  - Validates PRD ACs: AC-016-1, AC-016-2
  - Test AC:
    - [ ] Scenario: smoke completes -- Given a live server and token, When the tagged test runs, Then the example exits 0 and prints a branch
    - [ ] Scenario: excluded by default -- Given a plain `mix test`, When the suite runs, Then the smoke test is skipped
    - [ ] Scenario: refusal surfaces -- Given a live server with remote start off, When run, Then exit is non-zero and stderr names the refusal
- [ ] **TRD-008**: Documentation: `docs/user-guide.md` Jobsite section (what the skill does, how to invoke, server settings templates may need), `templates/shared/README.md` pointer, `AGENTS.md` Remote Jobsite paragraph pointer to `contract.json` as the client-side mirror, flag CLAUDE.md §5.1 `litellm` vs `JidoHarness.providers/0` discrepancy (3h) [satisfies REQ-018] [depends: TRD-005]
  - Validates PRD ACs: AC-018-1, AC-018-2
  - Implementation AC:
    - [ ] Given the user guide, when searched for `foreman-jobsite-template`, then invocation and server prerequisites are documented
    - [ ] Given `AGENTS.md`, when read, then it names `contract.json` and its drift test
- [ ] **TRD-008-TEST**: Docs consistency test: every forbidden key named in the `AGENTS.md` Remote Jobsite paragraph is in `contract.json` refusals and vice versa (2h) [verifies TRD-008] [satisfies REQ-018] [depends: TRD-008, TRD-002]
  - Validates PRD ACs: AC-018-1, AC-018-2
  - Test AC:
    - [ ] Scenario: docs and contract agree -- Given `AGENTS.md` and `contract.json`, When compared, Then the forbidden capability sets are equal
    - [ ] Scenario: user guide mentions skill -- Given `docs/user-guide.md`, When searched, Then `foreman-jobsite-template` appears
    - [ ] Scenario: divergence reported (derived) -- Given a forbidden key only in `AGENTS.md`, When compared, Then the failure names it

## Sprint Planning

## Sprint 1: Contract and skeleton

PR 1 (TRD-001, TRD-002, TRD-002-TEST, TRD-003, TRD-003-TEST) and PR 2
(TRD-004, TRD-004-TEST). ~25h.

## Sprint 2: Skill, examples, smoke, docs

PR 3 (TRD-005, TRD-005-TEST, TRD-006, TRD-006-TEST) and PR 4 (TRD-007,
TRD-007-TEST, TRD-008, TRD-008-TEST). ~28h.

Critical path: TRD-001 → TRD-002 → TRD-003 → TRD-004 → TRD-005 → TRD-006 →
TRD-006-TEST → TRD-007 (depth 7; inherent, since each layer consumes the
previous one's artifact).

## Acceptance Criteria Traceability

| REQ | Description | Implementation Tasks | Test Tasks |
|---|---|---|---|
| REQ-001 | Skill discoverable by name | TRD-005 | TRD-005-TEST |
| REQ-002 | Accepts NL prompt | TRD-005 | TRD-005-TEST, TRD-006-TEST |
| REQ-003 | Resolve missing essentials | TRD-005 | TRD-006-TEST (defaults recorded in examples) |
| REQ-004 | Map behaviors to whitelisted fields | TRD-002, TRD-005, TRD-006 | TRD-003-TEST, TRD-006-TEST |
| REQ-005 | Prompt inline, never a file ref | TRD-003, TRD-004 | TRD-003-TEST, TRD-004-TEST |
| REQ-006 | Branch/push rules | TRD-003, TRD-005, TRD-006 | TRD-003-TEST, TRD-006-TEST |
| REQ-007 | Agent fields/values | TRD-003, TRD-005 | TRD-003-TEST, TRD-002-TEST |
| REQ-008 | Env by name only | TRD-004, TRD-005, TRD-006 | TRD-004-TEST |
| REQ-009 | Sandbox hooks only | TRD-003, TRD-005, TRD-006 | TRD-003-TEST, TRD-006-TEST |
| REQ-010 | Docker default sandbox | TRD-005 | TRD-006-TEST |
| REQ-011 | Refuse with alternative | TRD-002, TRD-005 | TRD-005-TEST, TRD-008-TEST |
| REQ-012 | Optional scope controls | TRD-005, TRD-006 | TRD-006-TEST |
| REQ-013 | Runnable template layout | TRD-004, TRD-005 | TRD-004-TEST |
| REQ-014 | Pre-write validation | TRD-003, TRD-005 | TRD-003-TEST, TRD-006-TEST |
| REQ-015 | No silent drift | TRD-001 | TRD-002-TEST |
| REQ-016 | End-to-end smoke | TRD-006, TRD-007 | TRD-006-TEST, TRD-007-TEST |
| REQ-017 | No secrets in artifacts | TRD-004 | TRD-004-TEST |
| REQ-018 | Documentation | TRD-008 | TRD-008-TEST |

Traceability check: 18 requirements covered, 0 uncovered, 0 orphaned annotations.

## Quality Requirements

- **Security:** no secret values in any generated or committed file (REQ-017);
  `agent.env` by name only; token from env only; checker refuses inline env
  values. The skill never touches server operator flags.
- **Testing (constitution §1, §3):** every implementation task has a paired
  test task written first; `mix test` green with zero warnings; the live smoke
  test is opt-in and excluded from default runs and CI.
- **Dependencies (constitution §5):** none added. Checker and skeleton use OTP
  27+ `:json`; the skeleton uses the existing `foreman_client`.
- **Documentation (constitution §8):** TRD-008 is a gate for PR 4.
- **Architecture (constitution §4):** no event, command, aggregate, or route is
  added; `Spec.contract/0` is a pure read of compile-time attributes.

## Adversarial Review

**Architecture**
1. *Dry-run defaults `project_id`.* A dry-run spec with `"dry-run-project"`
   could be mistaken for real. Resolution: default applies only when
   `FOREMAN_JOBSITE_DRY_RUN=1`; the acceptance test overwrites `project_id`
   with the harness project before POSTing.
2. *Checker vs. server divergence beyond the lists.* `Spec` also validates
   value shapes via `Options.validate/1` (e.g. integer bounds). The checker does
   not mirror those. Resolution: TRD-006-TEST posts every example to the real
   controller, so value-level rejections surface in CI.

**Coverage**
1. REQ-003's interactive branch (AC-003-2) is LLM behavior and not
   automatically testable. Resolution: covered by SKILL.md instruction review in
   TRD-005 and noted as manual verification.
2. REQ-002 AC-002-2 (blank prompt) is skill behavior only. Resolution: same as
   above; recorded as manual check in TRD-005.
3. `trd-cli parse` self-check: all 15 task lines carry the `- [ ]` prefix.

**Dependency / estimate**
1. Critical-path depth 7 > 3. Accepted: each step consumes the previous
   artifact; PR 1 and PR 2 are small enough to land quickly. TRD-005 (6h) is the
   largest; it is a single document and does not need splitting.

**Testability**
1. "Recorded smoke run" (TRD-007) is evidence, not an automated gate.
   Resolution: TRD-007-TEST provides the repeatable opt-in version.

## Design Readiness Scorecard

| Dimension | Score |
|---|---:|
| Architecture completeness | 5 |
| Task coverage | 4 |
| Dependency clarity | 4 |
| Estimate confidence | 4 |
| **Overall** | **4.25 — PASS** |

Constitution compliance: passed.

## Companion Artifacts

No companion artifacts generated.
