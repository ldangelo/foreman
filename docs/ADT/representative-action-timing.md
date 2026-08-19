# Representative Action E2E Timing (ADT-T003)

TRD: TRD-2026-4212be7e / ADT-T003 / TRD-085
Bead: foreman-5aa4
Based on: docs/ADT/representative-action-run.md (ADT-T002)

## Timing methodology
- Wall-clock from task start to task close in fresh worktree
- Phases: scaffold, types, classification, registration, unit test, integration test, docs, deploy
- Use :timer.tc/1 around each phase; aggregate
- Run once for baseline; record in moduledoc

## Target
- NFR-01: ≤4 hours end-to-end

## Baseline
- Pending actual run; methodology defined here.

## Benchmark log
- 2026-08-19: methodology established
