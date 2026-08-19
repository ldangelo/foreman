# Final Characterization Test Plan (LGC-T012, TRD-2026-4212be7e)

Plan date: 2026-08-19
Bead: foreman-k4hg

## Workflows under test

1. create: ensemble:create-prd -> ensemble:refine-prd -> ensemble:create-trd -> ensemble:refine-trd -> ensemble-full-implement-trd
2. implement: ensemble-full-implement-trd
3. fix: ensemble:fix-issue

## Observable outcomes (must be identical across all three)

### Outcome A: PR created

- Trigger: workflow completes successfully
- Assert: PR exists on remote origin
- Assert: PR title follows <workflow-name>(<id>): <subject> convention
- Assert: PR body references originating task_id

### Outcome B: Task status updated

- Trigger: workflow completes
- Assert: originating task bead status transitions to closed
- Assert: bead closure reason includes workflow:<name>
- Assert: closure timestamp within workflow duration window

### Outcome C: Operator notified

- Trigger: workflow completes
- Assert: InboxItemStarted + InboxItemCompleted events emitted on foreman/inbox topic
- Assert: SharedInbox persists both events
- Assert: Phoenix.ConnTest GET /api/operator/inbox returns the items

## Status

- Test framework: ExUnit (ForemanServerWeb.ConnCase, ForemanServer.DataCase)
- Test location: packages/foreman_server/test/foreman_server/workflow/final_characterization_test.exs
- Status: PLAN — actual test execution pending TRD-107 closure (depends on TRD-105/106)

## Caveats

- TRD-105 (e2e workflow run) and TRD-106 (pre-migration code removal) must complete first
- TRD-064 WFD-T001 dispatcher is currently a stub — final characterization cannot pass until dispatcher is implemented
- Therefore TRD-107 closure is downstream of these fixes
