# Authoritative Event Vocabulary

> TRD Reference: `docs/TRD/TRD-2026-96872fc5-go-elixir-cqrs-parity.md#trd-001`
> PRD Reference: `#req-010`
> Satisfaction: REQ-010

This document is the **authoritative list** of every domain event emitted by any aggregate.
It is the source of truth for typed struct generation (TRD-002) and the enforcement contract
for `EventCodec.decode!/2` (TRD-003).

All events below are emitted exclusively through `CommandRouter.dispatch/1` from an
aggregate's `handle_command/2` callback. No module may emit these events directly.

---

## Event Index

| Event | Module | Emitted By | Phase |
|---|---|---|---|
| `ProjectRegistered` | `ForemanServer.Events.ProjectRegistered` | Project | 1 |
| `ProjectUpdated` | `ForemanServer.Events.ProjectUpdated` | Project | 1 |
| `ProjectArchived` | `ForemanServer.Events.ProjectArchived` | Project | 1 |
| `ProjectReactivated` | `ForemanServer.Events.ProjectReactivated` | Project | 1 |
| `RunStarted` | `ForemanServer.Events.RunStarted` | Run | 1 |
| `RunUpdated` | `ForemanServer.Events.RunUpdated` | Run | 1 |
| `RunCompleted` | `ForemanServer.Events.RunCompleted` | Run | 1 |
| `RunFailed` | `ForemanServer.Events.RunFailed` | Run | 1 |
| `RunBlocked` | `ForemanServer.Events.RunBlocked` | Run | 1 |
| `RunDeleted` | `ForemanServer.Events.RunDeleted` | Run | 1 |
| `PrUpdated` | `ForemanServer.Events.PrUpdated` | Run | 1 |
| `PrReady` | `ForemanServer.Events.PrReady` | Run | 1 |
| `PrRetargeted` | `ForemanServer.Events.PrRetargeted` | Run | 1 |
| `PrReset` | `ForemanServer.Events.PrReset` | Run | 1 |
| `PrMerged` | `ForemanServer.Events.PrMerged` | Run | 1 |
| `TaskCreated` | `ForemanServer.Events.TaskCreated` | Task | 1 |
| `TaskUpdated` | `ForemanServer.Events.TaskUpdated` | Task | 1 |
| `TaskAnnotated` | `ForemanServer.Events.TaskAnnotated` | Task | 1 |
| `TaskDependencyAdded` | `ForemanServer.Events.TaskDependencyAdded` | Task | 1 |
| `PhaseStarted` | `ForemanServer.Events.PhaseStarted` | Phase | 1 |
| `PhaseCompleted` | `ForemanServer.Events.PhaseCompleted` | Phase | 1 |
| `PhaseFailed` | `ForemanServer.Events.PhaseFailed` | Phase | 1 |
| `PhaseTimedOut` | `ForemanServer.Events.PhaseTimedOut` | Phase | 1 |
| `PhaseRetried` | `ForemanServer.Events.PhaseRetried` | Phase | 1 |
| `PhaseSkipped` | `ForemanServer.Events.PhaseSkipped` | Phase | 1 |
| `WorkerStarted` | `ForemanServer.Events.WorkerStarted` | Worker | 1 |
| `WorkerHeartbeat` | `ForemanServer.Events.WorkerHeartbeat` | Worker | 1 |
| `WorkerExited` | `ForemanServer.Events.WorkerExited` | Worker | 1 |
| `AssistantMessage` | `ForemanServer.Events.AssistantMessage` | Worker | 1 |
| `WorkerStdout` | `ForemanServer.Events.WorkerStdout` | Worker | 1 |
| `WorkerStderr` | `ForemanServer.Events.WorkerStderr` | Worker | 1 |
| `ToolCallRequested` | `ForemanServer.Events.ToolCallRequested` | ToolCall | 1 |
| `ToolCallApproved` | `ForemanServer.Events.ToolCallApproved` | ToolCall | 1 |
| `ToolCallDenied` | `ForemanServer.Events.ToolCallDenied` | ToolCall | 1 |
| `ToolCallFinished` | `ForemanServer.Events.ToolCallFinished` | ToolCall | 1 |
| `SchedulerTicked` | `ForemanServer.Events.SchedulerTicked` | Scheduler | 2 |
| `SchedulerTaskClaimed` | `ForemanServer.Events.SchedulerTaskClaimed` | Scheduler | 2 |
| `SchedulerTaskSkipped` | `ForemanServer.Events.SchedulerTaskSkipped` | Scheduler | 2 |
| `WorktreeCleaned` | `ForemanServer.Events.WorktreeCleaned` | VcsOperation | 2 |
| `VcsMergeRequested` | `ForemanServer.Events.VcsMergeRequested` | VcsOperation | 2 |
| `PrGateObserved` | `ForemanServer.Events.PrGateObserved` | VcsOperation | 2 |
| `PrMerged` | `ForemanServer.Events.PrMerged` | VcsOperation | 2 |
| `MergeFailed` | `ForemanServer.Events.MergeFailed` | VcsOperation | 2 |
| `MergeBlocked` | `ForemanServer.Events.MergeBlocked` | VcsOperation | 2 |
| `PhaseReportProduced` | `ForemanServer.Events.PhaseReportProduced` | ArtifactReport | 2 |
| `PhaseVerdict` | `ForemanServer.Events.PhaseVerdict` | ArtifactReport | 2 |
| `AttachRequested` | `ForemanServer.Events.AttachRequested` | Attachment | 2 |
| `AttachUnsupported` | `ForemanServer.Events.AttachUnsupported` | Attachment | 2 |
| `ExternalTriggerCommand` | `ForemanServer.Events.ExternalTriggerCommand` | ExternalTrigger | 2 |
| `CommandAccepted` | `ForemanServer.Events.CommandAccepted` | ExternalTrigger | 2 |
| `ExternalWorkerObserved` | `ForemanServer.Events.ExternalWorkerObserved` | ExternalTrigger | 2 |
| `MigrationImportStarted` | `ForemanServer.Events.MigrationImportStarted` | ImportMigration | 2 |
| `MigrationRecordImported` | `ForemanServer.Events.MigrationRecordImported` | ImportMigration | 2 |
| `MigrationImportCompleted` | `ForemanServer.Events.MigrationImportCompleted` | ImportMigration | 2 |
| `InboxMessageAppended` | `ForemanServer.Events.InboxMessageAppended` | InboxThread | 2 |
| `InboxDeliveryUpdated` | `ForemanServer.Events.InboxDeliveryUpdated` | InboxThread | 2 |
| `IntegrationCommandIngested` | `ForemanServer.Events.IntegrationCommandIngested` | Integration | 2 |
| `IntegrationConfigured` | `ForemanServer.Events.IntegrationConfigured` | Integration | 2 |
| `IntegrationSyncRequested` | `ForemanServer.Events.IntegrationSyncRequested` | Integration | 2 |
| `IntegrationSyncCompleted` | `ForemanServer.Events.IntegrationSyncCompleted` | Integration | 2 |
| `NeedsOperator` | `ForemanServer.Events.NeedsOperator` | OperatorIntervention | 3 |
| `HumanInterruptionRecorded` | `ForemanServer.Events.HumanInterruptionRecorded` | OperatorIntervention | 3 |
| `InteractiveRecoveryResumed` | `ForemanServer.Events.InteractiveRecoveryResumed` | OperatorIntervention | 3 |
| `PlanningFlowStarted` | `ForemanServer.Events.PlanningFlowStarted` | PlanningFlow | 3 |
| `PlanningFlowCommand` | `ForemanServer.Events.PlanningFlowCommand` | PlanningFlow | 3 |
| `PlanningTraceLinked` | `ForemanServer.Events.PlanningTraceLinked` | PlanningFlow | 3 |
| `PlanningFlowCompleted` | `ForemanServer.Events.PlanningFlowCompleted` | PlanningFlow | 3 |
| `WorkerRecoveryRequired` | `ForemanServer.Events.WorkerRecoveryRequired` | Recovery | 3 |
| `WorkerReattached` | `ForemanServer.Events.WorkerReattached` | Recovery | 3 |
| `WorkerRestarted` | `ForemanServer.Events.WorkerRestarted` | Recovery | 3 |
| `RecoveryResolved` | `ForemanServer.Events.RecoveryResolved` | Recovery | 3 |

**Total: 70 events across 15 aggregates.**

---

## Event Definitions

### Project Aggregate (`ForemanServer.Aggregates.Project`)

#### `ProjectRegistered`
- **Module:** `ForemanServer.Events.ProjectRegistered`
- **Emitted by command:** `project.register`
- **Stream:** `project:<project_id>`
- **Fields:**
  - `project_id` (string, required) — canonical project identifier
  - `path` (string, required) — filesystem path to project root
  - `status` (string, optional, default: `"active"`)
  - `default_branch` (string, optional, default: `"main"`)
  - `config` (map, optional) — arbitrary project configuration
  - `health` (map, optional) — health check results
- **Consumed by:** `Project` aggregate (`apply_event`)

#### `ProjectUpdated`
- **Module:** `ForemanServer.Events.ProjectUpdated`
- **Emitted by command:** `project.update`
- **Stream:** `project:<project_id>`
- **Fields:**
  - `project_id` (string, required)
  - `name` (string, optional) — project display name
  - `status` (string, optional) — active/paused
  - `default_branch` (string, optional)
  - `config` (map, optional) — merged into existing config
  - `health` (map, optional) — merged into existing health
- **Consumed by:** `Project` aggregate (`apply_event`)

#### `ProjectArchived`
- **Module:** `ForemanServer.Events.ProjectArchived`
- **Emitted by command:** `project.archive`
- **Stream:** `project:<project_id>`
- **Fields:**
  - `project_id` (string, required)
- **Consumed by:** `Project` aggregate (`apply_event`)

#### `ProjectReactivated`
- **Module:** `ForemanServer.Events.ProjectReactivated`
- **Emitted by command:** `project.reactivate`
- **Stream:** `project:<project_id>`
- **Fields:**
  - `project_id` (string, required)
- **Consumed by:** `Project` aggregate (`apply_event`)

---

### Run Aggregate (`ForemanServer.Aggregates.Run`)

#### `RunStarted`
- **Module:** `ForemanServer.Events.RunStarted`
- **Emitted by command:** `run.start`
- **Stream:** `run:<run_id>`
- **Fields:**
  - `run_id` (string, required)
  - `task_id` (string, required)
- **Consumed by:** `Run` aggregate (`apply_event`), `Task` aggregate (`apply_event`)

#### `RunUpdated`
- **Module:** `ForemanServer.Events.RunUpdated`
- **Emitted by command:** `run.update`
- **Stream:** `run:<run_id>`
- **Fields:**
  - `run_id` (string, required)
  - `task_id` (string, optional)
- **Consumed by:** `Run` aggregate (`apply_event`)

#### `RunCompleted`
- **Module:** `ForemanServer.Events.RunCompleted`
- **Emitted by command:** `run.complete`
- **Stream:** `run:<run_id>`
- **Fields:**
  - `run_id` (string, required)
  - `sequence` (integer, optional) — last event sequence in the run
- **Consumed by:** `Run` aggregate (`apply_event`), `Task` aggregate (`apply_event`)

#### `RunFailed`
- **Module:** `ForemanServer.Events.RunFailed`
- **Emitted by command:** `run.fail`
- **Stream:** `run:<run_id>`
- **Fields:**
  - `run_id` (string, required)
  - `sequence` (integer, optional)
- **Consumed by:** `Run` aggregate (`apply_event`), `Task` aggregate (`apply_event`)

#### `RunBlocked`
- **Module:** `ForemanServer.Events.RunBlocked`
- **Emitted by command:** `run.block`
- **Stream:** `run:<run_id>`
- **Fields:**
  - `run_id` (string, required)
  - `sequence` (integer, optional)
- **Consumed by:** `Run` aggregate (`apply_event`)

#### `RunDeleted`
- **Module:** `ForemanServer.Events.RunDeleted`
- **Emitted by command:** `run.delete`
- **Stream:** `run:<run_id>`
- **Fields:**
  - `run_id` (string, required)
- **Consumed by:** `Run` aggregate (`apply_event`)

#### `PrUpdated`
- **Module:** `ForemanServer.Events.PrUpdated`
- **Emitted by command:** `run.pr.update`
- **Stream:** `run:<run_id>`
- **Fields:**
  - `run_id` (string, required)
- **Consumed by:** `Run` aggregate (`apply_event`)

#### `PrReady`
- **Module:** `ForemanServer.Events.PrReady`
- **Emitted by command:** `run.pr.ready`
- **Stream:** `run:<run_id>`
- **Fields:**
  - `run_id` (string, required)
- **Consumed by:** `Run` aggregate (`apply_event`)

#### `PrRetargeted`
- **Module:** `ForemanServer.Events.PrRetargeted`
- **Emitted by command:** `run.pr.retarget`
- **Stream:** `run:<run_id>`
- **Fields:**
  - `run_id` (string, required)
- **Consumed by:** `Run` aggregate (`apply_event`)

#### `PrReset`
- **Module:** `ForemanServer.Events.PrReset`
- **Emitted by command:** `run.pr.reset`
- **Stream:** `run:<run_id>`
- **Fields:**
  - `run_id` (string, required)
- **Consumed by:** `Run` aggregate (`apply_event`)

#### `PrMerged`
- **Module:** `ForemanServer.Events.PrMerged`
- **Emitted by command:** `run.pr.merge`
- **Stream:** `run:<run_id>`
- **Fields:**
  - `run_id` (string, required)
- **Consumed by:** `Run` aggregate (`apply_event`)

---

### Task Aggregate (`ForemanServer.Aggregates.Task`)

#### `TaskCreated`
- **Module:** `ForemanServer.Events.TaskCreated`
- **Emitted by command:** `task.create`
- **Stream:** `task:<task_id>`
- **Fields:**
  - `task_id` (string, required)
  - `project_id` (string, required)
  - `status` (string, optional, default: `"open"`)
  - `dependencies` (list of strings, optional)
- **Consumed by:** `Task` aggregate (`apply_event`)

#### `TaskUpdated`
- **Module:** `ForemanServer.Events.TaskUpdated`
- **Emitted by command:** `task.update`
- **Stream:** `task:<task_id>`
- **Fields:**
  - `task_id` (string, required)
  - `status` (string, optional)
- **Consumed by:** `Task` aggregate (`apply_event`)

#### `TaskAnnotated`
- **Module:** `ForemanServer.Events.TaskAnnotated`
- **Emitted by command:** `task.annotate`
- **Stream:** `task:<task_id>`
- **Fields:**
  - `body` (string, required)
  - `author` (string, required)
  - `created_at` (string, required)
  - `metadata` (map, optional) — remaining payload fields
- **Consumed by:** `Task` aggregate (`apply_event`)

#### `TaskDependencyAdded`
- **Module:** `ForemanServer.Events.TaskDependencyAdded`
- **Emitted by command:** `task.add_dependency`
- **Stream:** `task:<task_id>`
- **Fields:**
  - `task_id` (string, required)
  - `depends_on` (string, required) — ID of the dependency task
- **Consumed by:** `Task` aggregate (`apply_event`)

---

### Phase Aggregate (`ForemanServer.Aggregates.Phase`)

#### `PhaseStarted`
- **Module:** `ForemanServer.Events.PhaseStarted`
- **Emitted by command:** `phase.start`
- **Stream:** `phase:<run_id>:<phase_id>`
- **Fields:**
  - `run_id` (string, required)
  - `phase_id` (string, required)
- **Consumed by:** `Run` aggregate (`apply_event`), `Phase` aggregate (`apply_event`)

#### `PhaseCompleted`
- **Module:** `ForemanServer.Events.PhaseCompleted`
- **Emitted by command:** `phase.complete`
- **Stream:** `phase:<run_id>:<phase_id>`
- **Fields:**
  - `run_id` (string, required)
  - `phase_id` (string, required)
- **Consumed by:** `Run` aggregate (`apply_event`), `Phase` aggregate (`apply_event`)

#### `PhaseFailed`
- **Module:** `ForemanServer.Events.PhaseFailed`
- **Emitted by command:** `phase.fail`
- **Stream:** `phase:<run_id>:<phase_id>`
- **Fields:**
  - `run_id` (string, required)
  - `phase_id` (string, required)
- **Consumed by:** `Run` aggregate (`apply_event`), `Phase` aggregate (`apply_event`)

#### `PhaseTimedOut`
- **Module:** `ForemanServer.Events.PhaseTimedOut`
- **Emitted by command:** `phase.timeout`
- **Stream:** `phase:<run_id>:<phase_id>`
- **Fields:**
  - `run_id` (string, required)
  - `phase_id` (string, required)
- **Consumed by:** `Run` aggregate (`apply_event`), `Phase` aggregate (`apply_event`)

#### `PhaseRetried`
- **Module:** `ForemanServer.Events.PhaseRetried`
- **Emitted by command:** `phase.retry`
- **Stream:** `phase:<run_id>:<phase_id>`
- **Fields:**
  - `run_id` (string, required)
  - `phase_id` (string, required)
- **Consumed by:** `Run` aggregate (`apply_event`), `Phase` aggregate (`apply_event`)

#### `PhaseSkipped`
- **Module:** `ForemanServer.Events.PhaseSkipped`
- **Emitted by command:** `phase.skip`
- **Stream:** `phase:<run_id>:<phase_id>`
- **Fields:**
  - `run_id` (string, required)
  - `phase_id` (string, required)
- **Consumed by:** `Phase` aggregate (`apply_event`)

---

### Worker Aggregate (`ForemanServer.Aggregates.Worker`)

#### `WorkerStarted`
- **Module:** `ForemanServer.Events.WorkerStarted`
- **Emitted by command:** `worker.start`
- **Stream:** `worker:<worker_id>`
- **Fields:**
  - `worker_id` (string, required)
  - `run_id` (string, required)
- **Consumed by:** `Run` aggregate (`apply_event`), `Worker` aggregate (`apply_event`)

#### `WorkerHeartbeat`
- **Module:** `ForemanServer.Events.WorkerHeartbeat`
- **Emitted by command:** `worker.heartbeat`
- **Stream:** `worker:<worker_id>`
- **Fields:**
  - `worker_id` (string, required)
  - `run_id` (string, required)
- **Consumed by:** `Run` aggregate (`apply_event`), `Worker` aggregate (`apply_event`)

#### `WorkerExited`
- **Module:** `ForemanServer.Events.WorkerExited`
- **Emitted by command:** `worker.exit`
- **Stream:** `worker:<worker_id>`
- **Fields:**
  - `worker_id` (string, required)
  - `run_id` (string, required)
- **Consumed by:** `Run` aggregate (`apply_event`), `Worker` aggregate (`apply_event`)

#### `AssistantMessage`
- **Module:** `ForemanServer.Events.AssistantMessage`
- **Emitted by command:** `worker.assistant_message`
- **Stream:** `worker:<worker_id>`
- **Fields:**
  - `worker_id` (string, required)
  - `run_id` (string, required)
- **Consumed by:** `Worker` aggregate (`apply_event`)

#### `WorkerStdout`
- **Module:** `ForemanServer.Events.WorkerStdout`
- **Emitted by command:** `worker.stdout`
- **Stream:** `worker:<worker_id>`
- **Fields:**
  - `worker_id` (string, required)
  - `run_id` (string, required)
- **Consumed by:** `Worker` aggregate (`apply_event`)

#### `WorkerStderr`
- **Module:** `ForemanServer.Events.WorkerStderr`
- **Emitted by command:** `worker.stderr`
- **Stream:** `worker:<worker_id>`
- **Fields:**
  - `worker_id` (string, required)
  - `run_id` (string, required)
- **Consumed by:** `Worker` aggregate (`apply_event`)

---

### ToolCall Aggregate (`ForemanServer.Aggregates.ToolCall`)

#### `ToolCallRequested`
- **Module:** `ForemanServer.Events.ToolCallRequested`
- **Emitted by command:** `tool.request`
- **Stream:** `tool_call:<tool_call_id>`
- **Fields:**
  - `tool_call_id` (string, required)
  - `tool_name` (string, required)
  - `input` (map, optional)
- **Consumed by:** `ToolCall` aggregate (`apply_event`)

#### `ToolCallApproved`
- **Module:** `ForemanServer.Events.ToolCallApproved`
- **Emitted by command:** `tool.approve`
- **Stream:** `tool_call:<tool_call_id>`
- **Fields:**
  - `tool_call_id` (string, required)
- **Consumed by:** `ToolCall` aggregate (`apply_event`)

#### `ToolCallDenied`
- **Module:** `ForemanServer.Events.ToolCallDenied`
- **Emitted by command:** `tool.deny`
- **Stream:** `tool_call:<tool_call_id>`
- **Fields:**
  - `tool_call_id` (string, required)
- **Consumed by:** `ToolCall` aggregate (`apply_event`)

#### `ToolCallFinished`
- **Module:** `ForemanServer.Events.ToolCallFinished`
- **Emitted by command:** `tool.finish`
- **Stream:** `tool_call:<tool_call_id>`
- **Fields:**
  - `tool_call_id` (string, required)
  - `worker_id` (string, optional)
  - `run_id` (string, optional)
- **Consumed by:** `Run` aggregate (`apply_event`), `Worker` aggregate (`apply_event`), `ToolCall` aggregate (`apply_event`)

---

### Scheduler Aggregate (`ForemanServer.Aggregates.Scheduler`)

#### `SchedulerTicked`
- **Module:** `ForemanServer.Events.SchedulerTicked`
- **Emitted by command:** `scheduler.tick`
- **Stream:** `scheduler:<project_id>`
- **Fields:**
  - `project_id` (string, optional, default: `"global"`)
- **Consumed by:** `Scheduler` aggregate (`apply_event`)

#### `SchedulerTaskClaimed`
- **Module:** `ForemanServer.Events.SchedulerTaskClaimed`
- **Emitted by command:** `scheduler.claim`
- **Stream:** `scheduler:<project_id>`
- **Fields:**
  - `task_id` (string, required)
  - `project_id` (string, optional, default: `"global"`)
- **Consumed by:** `Scheduler` aggregate (`apply_event`)

#### `SchedulerTaskSkipped`
- **Module:** `ForemanServer.Events.SchedulerTaskSkipped`
- **Emitted by command:** `scheduler.skip`
- **Stream:** `scheduler:<project_id>`
- **Fields:**
  - `task_id` (string, required)
  - `project_id` (string, optional, default: `"global"`)
- **Consumed by:** `Scheduler` aggregate (`apply_event`)

---

### VcsOperation Aggregate (`ForemanServer.Aggregates.VcsOperation`)

#### `WorktreeCleaned`
- **Module:** `ForemanServer.Events.WorktreeCleaned`
- **Emitted by command:** `vcs.worktree.clean`
- **Stream:** `vcs:<operation_id>`
- **Fields:**
  - `operation_id` (string, required)
- **Consumed by:** `VcsOperation` aggregate (`apply_event`)

#### `VcsMergeRequested`
- **Module:** `ForemanServer.Events.VcsMergeRequested`
- **Emitted by command:** `vcs.merge.request`
- **Stream:** `vcs:<operation_id>`
- **Fields:**
  - `operation_id` (string, required)
- **Consumed by:** `VcsOperation` aggregate (`apply_event`)

#### `PrGateObserved`
- **Module:** `ForemanServer.Events.PrGateObserved`
- **Emitted by command:** `vcs.pr.observe`
- **Stream:** `vcs:<operation_id>`
- **Fields:**
  - `operation_id` (string, required)
- **Consumed by:** `VcsOperation` aggregate (`apply_event`)

#### `PrMerged` (VCS)
- **Module:** `ForemanServer.Events.PrMerged`
- **Emitted by command:** `vcs.pr.merge`
- **Stream:** `vcs:<operation_id>`
- **Fields:**
  - `operation_id` (string, required)
- **Consumed by:** `VcsOperation` aggregate (`apply_event`)

#### `MergeFailed`
- **Module:** `ForemanServer.Events.MergeFailed`
- **Emitted by command:** `vcs.merge.fail`
- **Stream:** `vcs:<operation_id>`
- **Fields:**
  - `operation_id` (string, required)
- **Consumed by:** `VcsOperation` aggregate (`apply_event`)

#### `MergeBlocked`
- **Module:** `ForemanServer.Events.MergeBlocked`
- **Emitted by command:** `vcs.merge.block`
- **Stream:** `vcs:<operation_id>`
- **Fields:**
  - `operation_id` (string, required)
- **Consumed by:** `VcsOperation` aggregate (`apply_event`)

---

### ArtifactReport Aggregate (`ForemanServer.Aggregates.ArtifactReport`)

#### `PhaseReportProduced`
- **Module:** `ForemanServer.Events.PhaseReportProduced`
- **Emitted by command:** `phase.report.produce`
- **Stream:** `artifact_report:<run_id>:<phase_id>`
- **Fields:**
  - `report_id` (string, optional)
  - `run_id` (string, required)
  - `phase_id` (string, required)
  - `metadata` (map, optional)
- **Consumed by:** `ArtifactReport` aggregate (`apply_event`)

#### `PhaseVerdict`
- **Module:** `ForemanServer.Events.PhaseVerdict`
- **Emitted by command:** `phase.verdict`
- **Stream:** `artifact_report:<run_id>:<phase_id>`
- **Fields:**
  - `run_id` (string, required)
  - `phase_id` (string, required)
  - `verdict` (string, optional)
  - `status` (string, optional)
  - `final` (boolean, optional, default: true)
- **Consumed by:** `ArtifactReport` aggregate (`apply_event`)

---

### Attachment Aggregate (`ForemanServer.Aggregates.Attachment`)

#### `AttachRequested`
- **Module:** `ForemanServer.Events.AttachRequested`
- **Emitted by command:** `attach.request`
- **Stream:** `attach:<run_id>:<worker_id>`
- **Fields:**
  - `run_id` (string, required)
  - `worker_id` (string, optional, default: `"default"`)
- **Consumed by:** `Attachment` aggregate (`apply_event`)

#### `AttachUnsupported`
- **Module:** `ForemanServer.Events.AttachUnsupported`
- **Emitted by command:** `attach.unsupported`
- **Stream:** `attach:<run_id>:<worker_id>`
- **Fields:**
  - `run_id` (string, required)
  - `worker_id` (string, optional, default: `"default"`)
- **Consumed by:** `Attachment` aggregate (`apply_event`)

---

### ExternalTrigger Aggregate (`ForemanServer.Aggregates.ExternalTrigger`)

#### `ExternalTriggerCommand`
- **Module:** `ForemanServer.Events.ExternalTriggerCommand`
- **Emitted by command:** `external.trigger`
- **Stream:** `external:<trigger_id>`
- **Fields:**
  - `trigger_id` (string, required)
- **Consumed by:** `ExternalTrigger` aggregate (`apply_event`)

#### `CommandAccepted`
- **Module:** `ForemanServer.Events.CommandAccepted`
- **Emitted by command:** `external.accept`
- **Stream:** `external:<trigger_id>`
- **Fields:**
  - `trigger_id` (string, required)
- **Consumed by:** `ExternalTrigger` aggregate (`apply_event`)

#### `ExternalWorkerObserved`
- **Module:** `ForemanServer.Events.ExternalWorkerObserved`
- **Emitted by command:** `external.worker.observe`
- **Stream:** `external:<trigger_id>`
- **Fields:**
  - `trigger_id` (string, required)
- **Consumed by:** `ExternalTrigger` aggregate (`apply_event`), `Recovery` aggregate (`apply_event`)

---

### ImportMigration Aggregate (`ForemanServer.Aggregates.ImportMigration`)

#### `MigrationImportStarted`
- **Module:** `ForemanServer.Events.MigrationImportStarted`
- **Emitted by command:** `migration.import.start`
- **Stream:** `migration:<import_id>`
- **Fields:**
  - `import_id` (string, required)
- **Consumed by:** `ImportMigration` aggregate (`apply_event`)

#### `MigrationRecordImported`
- **Module:** `ForemanServer.Events.MigrationRecordImported`
- **Emitted by command:** `migration.record.import`
- **Stream:** `migration:<import_id>`
- **Fields:**
  - `import_id` (string, required)
  - `record_id` (string, optional) — derived from `record_type:index` if absent
- **Consumed by:** `ImportMigration` aggregate (`apply_event`)

#### `MigrationImportCompleted`
- **Module:** `ForemanServer.Events.MigrationImportCompleted`
- **Emitted by command:** `migration.import.complete`
- **Stream:** `migration:<import_id>`
- **Fields:**
  - `import_id` (string, required)
- **Consumed by:** `ImportMigration` aggregate (`apply_event`)

---

### InboxThread Aggregate (`ForemanServer.Aggregates.InboxThread`)

#### `InboxMessageAppended`
- **Module:** `ForemanServer.Events.InboxMessageAppended`
- **Emitted by command:** `inbox.send`
- **Stream:** `inbox:<run_id>`
- **Fields:**
  - `run_id` (string, required)
  - `message_id` (string, required)
  - `body` (string, required)
  - `metadata` (map, optional) — remaining payload fields
- **Consumed by:** `InboxThread` aggregate (`apply_event`)

#### `InboxDeliveryUpdated`
- **Module:** `ForemanServer.Events.InboxDeliveryUpdated`
- **Emitted by command:** `inbox.delivery.update`
- **Stream:** `inbox:<run_id>`
- **Fields:**
  - `run_id` (string, required)
  - `message_id` (string, required)
  - `delivery_status` (string, required)
  - `metadata` (map, optional)
- **Consumed by:** `InboxThread` aggregate (`apply_event`)

---

### Integration Aggregate (`ForemanServer.Aggregates.Integration`)

#### `IntegrationCommandIngested`
- **Module:** `ForemanServer.Events.IntegrationCommandIngested`
- **Emitted by command:** `integration.ingest`
- **Stream:** `integration:<dedupe_key>`
- **Fields:**
  - `dedupe_key` (string, required)
  - `config` (map, optional)
- **Consumed by:** `Integration` aggregate (`apply_event`)

#### `IntegrationConfigured`
- **Module:** `ForemanServer.Events.IntegrationConfigured`
- **Emitted by command:** `integration.configure`
- **Stream:** `integration:<dedupe_key>`
- **Fields:**
  - `dedupe_key` (string, required)
  - `config` (map, optional)
- **Consumed by:** `Integration` aggregate (`apply_event`)

#### `IntegrationSyncRequested`
- **Module:** `ForemanServer.Events.IntegrationSyncRequested`
- **Emitted by command:** `integration.sync.request`
- **Stream:** `integration:<dedupe_key>`
- **Fields:**
  - `dedupe_key` (string, required)
- **Consumed by:** `Integration` aggregate (`apply_event`)

#### `IntegrationSyncCompleted`
- **Module:** `ForemanServer.Events.IntegrationSyncCompleted`
- **Emitted by command:** `integration.sync.complete`
- **Stream:** `integration:<dedupe_key>`
- **Fields:**
  - `dedupe_key` (string, required)
- **Consumed by:** `Integration` aggregate (`apply_event`)

---

### OperatorIntervention Aggregate (`ForemanServer.Aggregates.OperatorIntervention`)

#### `NeedsOperator`
- **Module:** `ForemanServer.Events.NeedsOperator`
- **Emitted by command:** `operator.needs`
- **Stream:** `operator:<run_id>`
- **Fields:**
  - `run_id` (string, required)
- **Consumed by:** `OperatorIntervention` aggregate (`apply_event`), `Recovery` aggregate (`apply_event`)

#### `HumanInterruptionRecorded`
- **Module:** `ForemanServer.Events.HumanInterruptionRecorded`
- **Emitted by command:** `operator.interrupt`
- **Stream:** `operator:<run_id>`
- **Fields:**
  - `run_id` (string, required)
- **Consumed by:** `OperatorIntervention` aggregate (`apply_event`)

#### `InteractiveRecoveryResumed`
- **Module:** `ForemanServer.Events.InteractiveRecoveryResumed`
- **Emitted by command:** `operator.resume`
- **Stream:** `operator:<run_id>`
- **Fields:**
  - `run_id` (string, required)
- **Consumed by:** `OperatorIntervention` aggregate (`apply_event`)

---

### PlanningFlow Aggregate (`ForemanServer.Aggregates.PlanningFlow`)

#### `PlanningFlowStarted`
- **Module:** `ForemanServer.Events.PlanningFlowStarted`
- **Emitted by command:** `planning.start`, `PlanningFlowCommand`, `plan.prd`, `plan.trd`
- **Stream:** `planning:<flow_id>`
- **Fields:**
  - `flow_id` (string, required)
- **Consumed by:** `PlanningFlow` aggregate (`apply_event`)

#### `PlanningFlowCommand`
- **Module:** `ForemanServer.Events.PlanningFlowCommand`
- **Emitted by command:** `planning.command`
- **Stream:** `planning:<flow_id>`
- **Fields:**
  - `flow_id` (string, required)
- **Consumed by:** `PlanningFlow` aggregate (`apply_event`)

#### `PlanningTraceLinked`
- **Module:** `ForemanServer.Events.PlanningTraceLinked`
- **Emitted by command:** `planning.trace.link`
- **Stream:** `planning:<flow_id>`
- **Fields:**
  - `flow_id` (string, required)
- **Consumed by:** `PlanningFlow` aggregate (`apply_event`)

#### `PlanningFlowCompleted`
- **Module:** `ForemanServer.Events.PlanningFlowCompleted`
- **Emitted by command:** `planning.complete`
- **Stream:** `planning:<flow_id>`
- **Fields:**
  - `flow_id` (string, required)
- **Consumed by:** `PlanningFlow` aggregate (`apply_event`)

---

### Recovery Aggregate (`ForemanServer.Aggregates.Recovery`)

#### `WorkerRecoveryRequired`
- **Module:** `ForemanServer.Events.WorkerRecoveryRequired`
- **Emitted by command:** `recovery.require`
- **Stream:** `recovery:<run_id>`
- **Fields:**
  - `run_id` (string, required)
- **Consumed by:** `Recovery` aggregate (`apply_event`)

#### `WorkerReattached`
- **Module:** `ForemanServer.Events.WorkerReattached`
- **Emitted by command:** `recovery.reattach`
- **Stream:** `recovery:<run_id>`
- **Fields:**
  - `run_id` (string, required)
- **Consumed by:** `Recovery` aggregate (`apply_event`)

#### `WorkerRestarted`
- **Module:** `ForemanServer.Events.WorkerRestarted`
- **Emitted by command:** `recovery.restart`
- **Stream:** `recovery:<run_id>`
- **Fields:**
  - `run_id` (string, required)
- **Consumed by:** `Recovery` aggregate (`apply_event`)

#### `RecoveryResolved`
- **Module:** `ForemanServer.Events.RecoveryResolved`
- **Emitted by command:** `recovery.resolve`
- **Stream:** `recovery:<run_id>`
- **Fields:**
  - `run_id` (string, required)
- **Consumed by:** `Recovery` aggregate (`apply_event`)

---

## Aggregates Not Yet Implemented

The following aggregates are defined in the domain model but have no `handle_command` implementations in the current codebase. Events are listed as planned.

| Aggregate | Events |
|---|---|
| `ForemanServer.Aggregates.Scheduler` | `SchedulerTicked`, `SchedulerTaskClaimed`, `SchedulerTaskSkipped` |
| `ForemanServer.Aggregates.VcsOperation` | `WorktreeCleaned`, `VcsMergeRequested`, `PrGateObserved`, `PrMerged`, `MergeFailed`, `MergeBlocked` |
| `ForemanServer.Aggregates.ArtifactReport` | `PhaseReportProduced`, `PhaseVerdict` |
| `ForemanServer.Aggregates.Attachment` | `AttachRequested`, `AttachUnsupported` |
| `ForemanServer.Aggregates.ExternalTrigger` | `ExternalTriggerCommand`, `CommandAccepted`, `ExternalWorkerObserved` |
| `ForemanServer.Aggregates.ImportMigration` | `MigrationImportStarted`, `MigrationRecordImported`, `MigrationImportCompleted` |
| `ForemanServer.Aggregates.InboxThread` | `InboxMessageAppended`, `InboxDeliveryUpdated` |
| `ForemanServer.Aggregates.Integration` | `IntegrationCommandIngested`, `IntegrationConfigured`, `IntegrationSyncRequested`, `IntegrationSyncCompleted` |
| `ForemanServer.Aggregates.OperatorIntervention` | `NeedsOperator`, `HumanInterruptionRecorded`, `InteractiveRecoveryResumed` |
| `ForemanServer.Aggregates.PlanningFlow` | `PlanningFlowStarted`, `PlanningFlowCommand`, `PlanningTraceLinked`, `PlanningFlowCompleted` |
| `ForemanServer.Aggregates.Recovery` | `WorkerRecoveryRequired`, `WorkerReattached`, `WorkerRestarted`, `RecoveryResolved` |

---

## Updating This Document

When a new event is added to the vocabulary:

1. Add the event to the index table with its module path, emitting aggregate, and phase.
2. Add a full definition section with all fields, their types, and which aggregates consume it.
3. Commit the change before the event is used in production (satisfies TRD-001 AC2).
