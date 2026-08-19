# Representative Action E2E Timing (ADT-T003)

TRD: TRD-2026-4212be7e / ADT-T003 / TRD-085
Bead: foreman-yef
Based on: docs/ADT/representative-action-run.md (ADT-T002)

## Timing methodology
- Wall-clock from task start to task close in fresh worktree
- Phases: scaffold, types, classification, registration, unit test, integration test, docs, deploy
- Use :timer.tc/1 around each phase; aggregate
- Run once for baseline; record in moduledoc

## Target
- NFR-01: ≤4 hours end-to-end
## Baseline

### GitStatusAction (JAF-T001) — rough retrospective estimate, not measured

`GitStatusAction` is the canonical representative action and is already fully
implemented and tested. The per-phase estimates below are rough retrospective
judgments from looking at the codebase; they were NOT measured with `:timer.tc/1`
in this session. They serve as a sanity check that NFR-01 (≤4 h) is plausible
for this action type, not as a verified benchmark.

| Phase | Rough estimate | Notes |
|---|---|---|
| Typed inputs (`schema:`) | ~10 min | Already implemented |
| Typed outputs (`output_schema:`) | ~10 min | Already implemented |
| Side-effect classification | ~15 min | `external` (spawns git); already in moduledoc |
| Integration classification | ~15 min | `fs`; already in moduledoc |
| Registration (`Registry`) | ~10 min | Already registered |
| Unit tests | ~30 min | `validate_params/1` + happy/error paths |
| Integration test | ~30 min | `GitStatusActionE2ETest`: clean→dirty→reset |
| Moduledoc | ~15 min | Purpose, output shape, failure modes |
| Deployment (supervisor restart) | ~5 min | Registry picks up module on restart |
| **Total (GitStatusAction)** | **~140 min** | **Well under 4-hour target** |

The ~140-minute estimate suggests NFR-01 is satisfied for this action class.
The first greenfield action built from scratch to this checklist will provide
a real empirical baseline with `:timer.tc/1` instrumentation.

### Next action benchmark (pending)

greenfield measurement with live timing. Target: ≤4 hours wall-clock.

## Benchmark log

| Date | Action | Result | Notes |
|---|---|---|---|
| 2026-08-19 | methodology established | — | foreman-5aa4 |
| 2026-08-19 | baseline recorded (rough retrospective estimate) | ~140 min | Not measured; see baseline table above |
| 2026-08-19 | E2E test not run | not run | Sandbox lacks erlexec; CI run needed |

## Result (ADT-T003)
Methodology documented. Rough retrospective estimate (~140 min for GitStatusAction)
suggests NFR-01 (≤4 h) is satisfiable for this action class. Actual empirical
baseline pending: first greenfield action built to the ADT checklist will be
timed with `:timer.tc/1`.
