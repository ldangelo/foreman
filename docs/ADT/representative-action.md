# Representative Action Template (ADT-T001, TRD-2026-4212be7e)

Defined: 2026-08-19
Bead: foreman-d2r7
Task: ADT-T001

## Representative action: ForemanServer.Actions.GitStatusAction

`GitStatusAction` is the canonical "representative action" for Foreman's
Jido.Action migration. The TRD explicitly designates it as the first
concrete Jido.Action in the codebase (JAF-T001) and the pattern that
JAF-T002 onward will follow. It exercises the full checklist (typed
input, typed output, side-effect classification, integration
classification, registration, unit + integration tests, moduledoc,
deployment via supervisor restart) without depending on the
Jido.Signal runtime — so it is the right anchor for the per-action
estimate.

### Why this action (not another)

- **Idempotent and read-only** (it shells out to `git status --porcelain`
  with no mutation), which keeps the unit-test surface small.
- **External side-effect** (`System.cmd/3` → spawns `git`) and
  **filesystem integration** classification — both must be reflected in
  the action's `tags`/`category` so the tool catalog can advertise it.
- **Has both unit (`Jido.Action` contract, `validate_params/1`) and
  integration (`run/2` against a tmp git repo) test blocks** — i.e. it
  already demonstrates the unit-vs-integration split the checklist
  asks for.

## Completion checklist (4-hour target)

The list below is the per-action deliverable for any new
`Jido.Action` landing under `packages/foreman_server/lib/foreman_server/actions/`.

- [ ] Typed inputs (`schema: [field: [type: ..., required: ..., doc: ...]]`
      or `@spec` + custom types via `typedspec`)
- [ ] Typed outputs (`output_schema: [...]` or `@spec` with
      `typedspec_result`)
- [ ] Side-effect classification: `none | read | write | external`
      (recorded in `tags:` and in the moduledoc "Failure modes"
      section)
- [ ] Integration classification: `none | api | db | fs | signal`
      (recorded in `tags:`)
- [ ] Registration in `ForemanServer.Actions.Registry`
      (add the module to the default list in
      `ForemanServer.Application`'s child spec, or document the operator
      config override `:foreman_server, ForemanServer.Actions.Registry,
      :actions`)
- [ ] Unit test (`describe "Jido.Action contract"` + `describe
      "validate_params/1"`; covers typed input validation, happy path,
      error path)
- [ ] Integration test (`describe "run/2"`; covers side-effect,
      classification, and the realistic failure modes)
- [ ] Docs in moduledoc (`@moduledoc`) with purpose, output shape,
      and failure modes; per-callback `@doc` strings on public
      functions
- [ ] Deployment: process restart (`ForemanServer.Application` supervisor
      restart is sufficient — no migrations, no schema changes, no
      hot-reload path; confirm `ForemanServer.Actions.Registry` child
      picks up the new module list)
- [ ] Time logged: <hours>

## Existing action inventory (found in repo)

1. `packages/foreman_server/lib/foreman_server/actions/git_status_action.ex`
   — `ForemanServer.Actions.GitStatusAction` — `git_status`: returns
   parsed `git status --porcelain` output for a path (the
   representative action itself; JAF-T001).
2. `packages/foreman_server/lib/foreman_server/actions/read_prompt_action.ex`
   — `ForemanServer.Actions.ReadPromptAction` — `read_prompt`: returns
   the current prompt-body text for a tracked workflow prompt path
   via `Workflow.Catalog.read_prompt/1` (JAF-T004).
3. `packages/foreman_server/lib/foreman_server/actions/registry.ex`
   — `ForemanServer.Actions.Registry` — GenServer that holds the
   registered action modules and exposes `list_actions/1`,
   `list_tools/1`, `lookup/2` for the tool catalog.
4. `packages/foreman_server/test/foreman_server/actions/git_status_action_test.exs`
   — Reference unit + integration test layout for any new action.
5. `packages/foreman_server/test/foreman_server/actions/read_prompt_action_test.exs`
   — Test layout for a delegation-style action.

## Benchmark baseline

- Target: ≤4 hours end-to-end per representative action
  (TRD-2026-4212be7e acceptance criterion for ADT-T001).
- First representative action will populate the actual time once the
  4-hour target is exercised end-to-end (moduledoc + schema +
  run/2 + tests + registry + restart). `GitStatusAction` already
  exists; the next action landing under this checklist will be the
  first true benchmark sample.