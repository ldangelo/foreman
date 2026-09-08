---
document_id: PRD-2026-d852e34b
label: prd-phoenix-otel-signoz-observability
version: 1.0.0
status: Draft
date: 2026-09-08
scale_depth: STANDARD
total_requirements: 16
total_acceptance_criteria: 43
readiness_score: 4.4
---

# PRD: Phoenix Logger → OTel → SigNoz Observability Gap

Foreman task title read from `FOREMAN_TASK_TITLE`: **PRD: Phoenix Logger → OTel → SigNoz observability gap**

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 11 |
| Should | 5 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 16/16 (100%) |
| Acceptance criteria coverage | 16/16 (100%) |
| Risk flags | 11 |
| Dependencies | 14 |
| Open ambiguity markers | 10 |
| TRD decisions required | 10 |

## Acceptance Criteria Summary

| Requirement | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Preserve Langfuse as the LLM trace destination | Must | Medium | 3 |
| REQ-002 | Add SigNoz as the operational log destination | Must | High | 3 |
| REQ-003 | Route Phoenix Logger records through OpenTelemetry logs | Must | High | 3 |
| REQ-004 | Instrument RunExecutor lifecycle logs | Must | High | 4 |
| REQ-005 | Instrument AutoPR operational logs | Must | Medium | 3 |
| REQ-006 | Correlate logs with run, task, phase, worker, and trace context | Must | High | 3 |
| REQ-007 | Configure an OTel collector pipeline for SigNoz logs | Must | High | 3 |
| REQ-008 | Keep secrets and prompts out of logs and metadata | Must | High | 3 |
| REQ-009 | Provide operator configuration and rollout controls | Must | Medium | 3 |
| REQ-010 | Define log retention behavior | Must | Medium | 2 |
| REQ-011 | Prove local developer observability end to end | Must | Medium | 2 |
| REQ-012 | Document deployment and troubleshooting expectations | Should | Medium | 2 |
| REQ-013 | Add tests for log export shape and redaction | Should | Medium | 3 |
| REQ-014 | Avoid duplicate or noisy logs | Should | Medium | 2 |
| REQ-015 | Expose health signals for the log pipeline | Should | Medium | 2 |
| REQ-016 | Preserve existing trace/span behavior | Should | Medium | 2 |

## 1. Executive Summary

Foreman already routes LLM-call tracing through Langfuse, but Phoenix/RunExecutor operational logs do not have an equivalent SigNoz path. The product gap is dual observability: Langfuse remains the source for LLM traces and model-call auditability, while SigNoz becomes the source for Foreman server and workflow operational logs.

This PRD defines the requirements for OpenTelemetry log instrumentation in the Phoenix backend, with focused coverage for `RunExecutor` and `AutoPR`, plus an OTel collector pipeline that delivers those logs to SigNoz. It also defines retention, redaction, correlation, rollout, tests, and docs. It does not prescribe a final implementation library choice where the Elixir OTel log signal contract needs TRD verification.

Foreman mode auto-selected STANDARD depth. Interviews were skipped under `--foreman`; assumptions are stated and unresolved decisions are marked inline with `[NEEDS CLARIFICATION: ...]`.

## 2. Background and Evidence

### 2.1 Current codebase shape

Foreman is a multi-package repository:

- `packages/foreman_server` — Elixir/Phoenix/OTP backend, EventStore, projections, scheduler, MCP server, workflow executor, and Overwatch worker runtime.
- `packages/foreman_cli` — Go CLI.
- `packages/jido_harness` — Elixir harness integration and upstream-pinned Jido runtime dependencies.

Relevant source surfaces found during reconnaissance:

- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` emits many `Logger.info/warning/error/debug` records around task claims, phase startup, finalization, failure dispatch, VFS binding, worktree behavior, and phase artifacts.
- `packages/foreman_server/lib/foreman_server/workflow/auto_pr.ex` logs PR push/create/noop/failure paths.
- `packages/foreman_server/lib/foreman_server/telemetry.ex` centralizes many `:telemetry.execute/3` events but does not define an OTel log contract.
- `packages/foreman_server/config/config.exs` and `prod.exs` already configure OpenTelemetry traces and an OTLP HTTP exporter for Langfuse-compatible ingestion.
- `packages/foreman_server/mix.exs` already depends on `:opentelemetry_exporter` and Jido OTel-related forks.

### 2.2 Existing observability contract

Existing config comments describe `TRD-2026-4212be7e` work for Langfuse-compatible OTLP traces. The current service resource uses `service.name = foreman_server`, and production config reads `OTEL_EXPORTER_OTLP_ENDPOINT` plus Langfuse Basic auth headers. This PRD assumes that trace pipeline must stay intact and must not be repurposed exclusively for SigNoz.

### 2.3 Product problem

Operators need to debug Foreman run execution, phase failures, PR creation failures, worker restarts, and Phoenix runtime errors in SigNoz. Today the critical context is scattered across local Logger output, event projections, MCP log tools, and Langfuse traces. LLM call traces alone do not answer operational questions like: "why did RunExecutor fail finalization?", "did AutoPR push the branch?", or "which phase logged this error?"

## 3. Personas

### 3.1 Foreman operator

Runs Foreman locally or in a server deployment. Needs searchable, retained operational logs with run/task/phase correlation.

### 3.2 Foreman maintainer

Needs a typed, low-drift logging contract that fits existing `ForemanServer.Telemetry`, Logger, redaction, and docs discipline.

### 3.3 Incident responder

Needs to reconstruct workflow failures from SigNoz without reading local terminal scrollback or asking an agent to replay state.

## 4. Scope

### In scope

- Phoenix/Foreman Logger-to-OpenTelemetry log export requirements.
- RunExecutor and AutoPR operational log coverage.
- SigNoz collector/log pipeline requirements.
- Log correlation fields for run, task, phase, worker, project, severity, source module, and trace/span context when available.
- Retention expectations and operator configuration.
- Redaction, test, rollout, health, and docs requirements.

### Out of scope

- Replacing Langfuse for LLM tracing.
- Building a new run-log storage product beyond the existing MCP/log projection behavior.
- New workflow lifecycle states.
- New SigNoz dashboards beyond minimal validation queries [NEEDS CLARIFICATION: Should this PRD require shipped SigNoz dashboards, or only queries/operators docs?].
- Implementing the OTel collector or infrastructure in this PRD.

## 5. Assumptions From Foreman Mode

- Langfuse is already working for LLM call tracing and remains authoritative for LLM call traces.
- SigNoz is the target for Phoenix/RunExecutor operational logs.
- OpenTelemetry is the preferred transport boundary so the collector can fan out traces/logs without code-specific vendor coupling.
- The first release should be opt-in or explicitly configurable to reduce risk in local development.
- Retention must be declared, but the exact duration is not present in the task description [NEEDS CLARIFICATION: What default SigNoz log retention period should Foreman operators use: 7, 14, 30, or another number of days?].

## 6. Requirements

### 6a. Dual Observability Contract

### REQ-001: Preserve Langfuse as the LLM trace destination

Priority: Must
Complexity: Medium
Risk: Repointing existing OTLP config could silently break LLM call tracing.

Foreman MUST keep LLM call traces flowing to Langfuse while adding SigNoz operational logs.

- AC-001-1: Given existing Langfuse environment variables are configured, when a Foreman LLM call succeeds, then the Langfuse trace path continues to receive that call trace.
- AC-001-2: Given SigNoz log export is enabled, when Foreman emits operational logs, then enabling SigNoz does not remove or overwrite the Langfuse OTLP trace endpoint unless the operator explicitly configures a collector fan-out [NEEDS CLARIFICATION: Should the production default be direct-to-Langfuse traces plus collector-to-SigNoz logs, or one collector endpoint that fans out both traces and logs?].
- AC-001-3: Given a trace/log correlation field is present, when an operator opens a SigNoz log, then any referenced trace/span identifiers are compatible with the active Langfuse/SigNoz topology.

### REQ-002: Add SigNoz as the operational log destination

Priority: Must
Complexity: High
Risk: The app may appear instrumented while logs remain local-only.

Foreman MUST be able to export Phoenix/backend operational logs to SigNoz.

- AC-002-1: Given SigNoz log export is enabled and the collector is reachable, when Foreman writes a qualifying Logger record, then a corresponding log record appears in SigNoz with service name `foreman_server`.
- AC-002-2: Given the collector is unavailable, when Foreman writes logs, then Foreman continues running and surfaces exporter/collector failures without crashing RunExecutor or Phoenix request handling.
- AC-002-3: Given SigNoz log export is disabled, when Foreman writes logs, then current local Logger behavior remains unchanged.

### REQ-003: Route Phoenix Logger records through OpenTelemetry logs

Priority: Must
Complexity: High
Risk: Elixir/Erlang OpenTelemetry log support varies by library version and may need adapter validation.

Foreman MUST route structured Phoenix Logger records through an OpenTelemetry-compatible log pipeline before SigNoz ingestion.

- AC-003-1: Given a Logger record includes metadata, when exported as an OTel log, then severity, timestamp, message body, module/function/line where available, and whitelisted metadata are preserved.
- AC-003-2: Given a Phoenix endpoint or supervised process logs an error, when SigNoz receives it, then the record is queryable by `service.name`, severity, module, and message text.
- AC-003-3: Given the TRD selects an Elixir/Erlang OTel log bridge, when implementation begins, then the dependency API is verified against source/docs and pinned with tests rather than assumed from trace exporter behavior.

### 6b. Workflow Execution Log Coverage

### REQ-004: Instrument RunExecutor lifecycle logs

Priority: Must
Complexity: High
Risk: RunExecutor is broad; incomplete instrumentation can miss the failure path operators need most.

RunExecutor MUST emit structured operational logs for lifecycle and failure paths important to workflow debugging.

- AC-004-1: Given a run starts, claims a task, starts a phase, completes a phase, blocks, fails, or finalizes, when RunExecutor logs those transitions, then each log includes `run_id`, `task_id` when known, `project_id` when known, `workflow_name` when known, and `phase_index`/`phase_name` when applicable.
- AC-004-2: Given RunExecutor dispatches terminal failure or finalization errors, when a failure log is exported, then SigNoz shows the structured reason without losing the original error term shape.
- AC-004-3: Given RunExecutor handles worktrees, VFS binding, phase artifacts, or cleanup, when notable warning/error logs occur, then logs include enough path context to debug the issue while applying path/secret redaction.
- AC-004-4: Given a RunExecutor log lacks one of the preferred context fields because the state genuinely lacks it, when exported, then the missing field is absent or null and not filled with guessed data.

### REQ-005: Instrument AutoPR operational logs

Priority: Must
Complexity: Medium
Risk: AutoPR failures can decide whether a finished run produces reviewable work.

AutoPR MUST emit structured logs for PR creation decisions and failures.

- AC-005-1: Given AutoPR resolves branch context, checks commits ahead, pushes a branch, opens a PR, noops, or fails, when logs are exported, then SigNoz records include `run_id`, `base_branch`, `head_branch`, operation name, and outcome where available.
- AC-005-2: Given `git` or `gh` returns non-zero output, when AutoPR logs the failure, then the exit code and sanitized command output are present.
- AC-005-3: Given a PR is created, when AutoPR logs success, then the PR URL is present and queryable without requiring the operator to parse a free-form message.

### REQ-006: Correlate logs with run, task, phase, worker, and trace context

Priority: Must
Complexity: High
Risk: Uncorrelated logs are not useful during concurrent runs.

Operational logs MUST be correlated across Foreman execution entities.

- AC-006-1: Given multiple runs execute concurrently, when an operator filters SigNoz by `run_id`, then only logs for that run are returned.
- AC-006-2: Given a log occurs inside an active OTel span, when exported, then trace/span identifiers are attached according to OTel log semantic conventions [NEEDS CLARIFICATION: Which exact OTel log semantic convention/version should Foreman target?].
- AC-006-3: Given worker runtime logs are emitted by Overwatch/LaunchWorker paths related to a run, when exported, then logs include `worker_id` and `run_id` when known.

### 6c. Collector, Retention, and Operations

### REQ-007: Configure an OTel collector pipeline for SigNoz logs

Priority: Must
Complexity: High
Risk: App-side instrumentation alone does not ensure SigNoz ingestion.

Foreman MUST document and support an OTel collector route from app logs to SigNoz.

- AC-007-1: Given a local or deployment collector is configured, when Foreman exports logs over OTLP HTTP/protobuf or gRPC [NEEDS CLARIFICATION: Should log export standardize on OTLP HTTP/protobuf to match current trace config, or allow gRPC as first-class?], then the collector accepts them and forwards them to SigNoz.
- AC-007-2: Given both Langfuse and SigNoz are configured, when collector fan-out is used, then trace and log pipelines are independently configurable and one destination's outage does not silently disable the other.
- AC-007-3: Given a malformed collector/SigNoz endpoint, when Foreman starts or exports logs, then operator-facing diagnostics identify the bad endpoint/header/pipeline without leaking credentials.

### REQ-008: Keep secrets and prompts out of logs and metadata

Priority: Must
Complexity: High
Risk: Logs may carry task prompts, provider output, keys, or local filesystem data.

Foreman MUST redact sensitive values before they reach SigNoz.

- AC-008-1: Given environment variables, API keys, auth headers, database URLs, task prompt bodies, LLM prompts/responses, or provider credentials appear in an error path, when logs are exported, then the sensitive value is redacted or omitted.
- AC-008-2: Given a test emits sentinel secrets through Logger metadata and message text, when captured/exported through the log bridge test path, then the sentinel value is absent from exported log payloads.
- AC-008-3: Given redaction removes a field, when the exported log is inspected, then it preserves enough non-sensitive context to diagnose the failure.

### REQ-009: Provide operator configuration and rollout controls

Priority: Must
Complexity: Medium
Risk: Mandatory log export can break local/dev workflows or CI.

Foreman MUST make SigNoz log export explicitly configurable.

- AC-009-1: Given no SigNoz/OTel log variables are set, when Foreman starts in dev/test, then it does not require a collector to boot.
- AC-009-2: Given an operator sets the documented variables, when Foreman starts, then log export uses those settings without code changes.
- AC-009-3: Given test config is active, when tests run, then OTel log export is no-op or test-captured so the suite does not make network calls.

### REQ-010: Define log retention behavior

Priority: Must
Complexity: Medium
Risk: Operators may assume logs are available longer than SigNoz keeps them.

Foreman MUST define log retention expectations for SigNoz-backed operational logs.

- AC-010-1: Given SigNoz is the configured log store, when docs describe the integration, then they state the default retention window and how operators change it [NEEDS CLARIFICATION: Is retention configured in Foreman docs only, or should Foreman ship a collector/SigNoz config fragment that enforces retention?].
- AC-010-2: Given a run is older than the retention window, when an operator searches logs by `run_id`, then docs explain that absence may mean retention expiry rather than no logs.

### REQ-011: Prove local developer observability end to end

Priority: Must
Complexity: Medium
Risk: Instrumentation can pass unit tests but fail against the local stack.

Foreman MUST provide a reproducible local validation path for SigNoz logs.

- AC-011-1: Given a developer follows the documented local setup, when they trigger a known RunExecutor or AutoPR log event, then they can query that event in SigNoz by `run_id`.
- AC-011-2: Given the local collector is not running, when the developer runs the validation, then failure output points to the missing collector/SigNoz component.

### 6d. Docs, Tests, Noise, and Health

### REQ-012: Document deployment and troubleshooting expectations

Priority: Should
Complexity: Medium
Risk: Operators may confuse Langfuse traces with SigNoz logs.

Documentation SHOULD explain the dual-observability model and troubleshooting steps.

- AC-012-1: Given a user reads README/user-guide/CLI reference as applicable, when they configure observability, then docs clearly distinguish Langfuse LLM traces from SigNoz operational logs.
- AC-012-2: Given logs are missing, when the operator follows troubleshooting docs, then they check app config, collector reachability, SigNoz ingestion, redaction/noise filters, and retention.

### REQ-013: Add tests for log export shape and redaction

Priority: Should
Complexity: Medium
Risk: Logging contracts drift easily under maintenance.

Implementation SHOULD pin the exported log schema with tests.

- AC-013-1: Given RunExecutor emits a representative lifecycle/failure log in test, when captured through the log bridge, then required correlation fields are asserted.
- AC-013-2: Given AutoPR emits success and failure logs in test, when captured, then operation/outcome/branch/PR fields are asserted.
- AC-013-3: Given sensitive sentinels appear in log input, when exported payloads are inspected, then redaction assertions fail if any sentinel leaks.

### REQ-014: Avoid duplicate or noisy logs

Priority: Should
Complexity: Medium
Risk: Naive Logger + OTel wiring can duplicate every record or flood SigNoz.

Foreman SHOULD avoid duplicate exports and control high-volume debug logs.

- AC-014-1: Given a single Logger event is emitted, when the log bridge and console logger are both enabled, then SigNoz receives at most one operational log record for that event [NEEDS CLARIFICATION: Should console logging remain enabled in production when SigNoz export is enabled?].
- AC-014-2: Given debug-level logs are enabled locally, when production export runs, then debug verbosity is controlled by documented log level/filter settings [NEEDS CLARIFICATION: Which log levels should be exported by default in production?].

### REQ-015: Expose health signals for the log pipeline

Priority: Should
Complexity: Medium
Risk: Silent exporter failures recreate the current observability gap.

Foreman SHOULD surface whether the log export path is healthy.

- AC-015-1: Given the exporter or collector rejects logs, when failures repeat, then Foreman surfaces a warning/error metric or log that can be detected locally [NEEDS CLARIFICATION: Should this be a Telemetry event, a Logger warning, a CLI doctor check, or all three?].
- AC-015-2: Given a doctor/troubleshooting check exists, when the SigNoz path is correctly configured, then it reports success without requiring a real Foreman run.

### REQ-016: Preserve existing trace/span behavior

Priority: Should
Complexity: Medium
Risk: Adding logs could change span processors/exporters and regress Jido/Langfuse observability.

Implementation SHOULD preserve existing OpenTelemetry trace behavior.

- AC-016-1: Given existing OTel span tests or local Langfuse validation are run after log export is added, then trace export still works.
- AC-016-2: Given logs are disabled, when trace export is enabled, then trace export behavior is unchanged from the pre-log-export configuration.

## 7. Non-Functional Requirements

Non-functional requirements are included in the unified numbering above:

- Performance: REQ-014 limits duplicate/noisy logs; exporter outage must not block runtime paths in REQ-002.
- Security: REQ-008 redaction; REQ-003 metadata whitelist.
- Reliability: REQ-002 outage behavior; REQ-015 health signals.
- Scalability: REQ-006 concurrent-run correlation and REQ-014 volume controls.
- Observability: REQ-002 through REQ-007 define end-to-end log visibility.
- Accessibility: no end-user UI is in scope.

## 8. Dependency Map

| Requirement | Depends On | Blocked By | Notes |
|---|---|---|---|
| REQ-001 | Existing Langfuse/OTel trace config | Collector topology decision | Preserve before adding logs. |
| REQ-002 | REQ-003, REQ-007, REQ-009 | OTel log bridge choice | Product-level destination requirement. |
| REQ-003 | Existing Logger metadata patterns | Library/API verification | Must be proven in TRD. |
| REQ-004 | REQ-003, REQ-006, REQ-008 | RunExecutor context availability | Key coverage area. |
| REQ-005 | REQ-003, REQ-006, REQ-008 | AutoPR metadata availability | Key coverage area. |
| REQ-006 | REQ-003, REQ-004, REQ-005 | Semantic convention decision | Enables search during concurrency. |
| REQ-007 | REQ-001, REQ-002 | Collector/SigNoz config details | Integration boundary. |
| REQ-008 | REQ-003, REQ-004, REQ-005 | Redaction policy decision | Security gate for all exported logs. |
| REQ-009 | REQ-002, REQ-007 | Env var naming decision | Rollout control. |
| REQ-010 | REQ-007 | Retention duration decision | Operator expectation. |
| REQ-011 | REQ-002, REQ-004, REQ-005, REQ-007 | Local SigNoz availability | End-to-end proof. |
| REQ-012 | REQ-001, REQ-002, REQ-010, REQ-015 | None | Docs required if behavior changes. |
| REQ-013 | REQ-003, REQ-004, REQ-005, REQ-008 | Test capture harness | Drift protection. |
| REQ-014 | REQ-003, REQ-009 | Production logging policy | Cost/noise control. |
| REQ-015 | REQ-007, REQ-009 | Health-check mechanism choice | Avoid silent failure. |
| REQ-016 | REQ-001, REQ-003, REQ-007 | Existing trace validation | Regression prevention. |

Implementation clusters:

- Cluster A: REQ-001, REQ-003, REQ-007, REQ-009, REQ-016 — topology/config foundation.
- Cluster B: REQ-004, REQ-005, REQ-006, REQ-008, REQ-013, REQ-014 — structured log contract and tests.
- Cluster C: REQ-010, REQ-011, REQ-012, REQ-015 — operator proof, retention, docs, and health.

No circular dependencies identified.

## 9. Adversarial Review

Foreman mode auto-applied safe issue resolutions and marked unresolved points inline.

| Issue | Category | Resolution |
|---|---|---|
| The subject could imply replacing Langfuse with SigNoz. | Contradiction | Added REQ-001 and REQ-016 to preserve Langfuse traces and existing span behavior. |
| "OTel logs" may not be supported by the same exporter config used for traces. | Feasibility | Added REQ-003 AC-003-3 requiring TRD verification of the Elixir/Erlang log bridge API. |
| RunExecutor logging is broad and could miss critical paths. | Gap | Added REQ-004 with explicit lifecycle/failure/worktree/artifact contexts. |
| Logs can leak prompts, secrets, auth headers, DB URLs, or provider output. | Security | Added REQ-008 and redaction tests in REQ-013. |
| Collector topology is ambiguous: direct endpoints vs fan-out. | Ambiguity | Added inline clarification markers in REQ-001 and REQ-007. |
| Retention was requested but no duration was provided. | Ambiguity | Added REQ-010 and clarification markers for duration/config enforcement. |
| SigNoz validation could pass unit tests but fail locally. | Testability | Added REQ-011 for end-to-end local validation. |
| Naive Logger handlers can duplicate every log line. | Missing edge case | Added REQ-014 duplicate/noise requirement. |
| Pipeline outage could be silent. | Reliability | Added REQ-015 health-signal requirement. |
| Console and exported logging policy is unspecified. | Ambiguity | Added clarification marker in REQ-014. |

## 10. Implementation Readiness Gate

| Dimension | Score | Rationale |
|---|---:|---|
| Completeness | 4.5 | Covers dual observability, app logging, RunExecutor/AutoPR, collector, retention, redaction, tests, health, and docs. |
| Testability | 4.5 | Every Must/Should requirement has verifiable ACs; local end-to-end proof is required. |
| Clarity | 4.0 | Core product boundary is clear; several topology/retention details are intentionally marked for TRD/refinement. |
| Feasibility | 4.5 | Builds on existing Phoenix Logger, OpenTelemetry exporter config, and known Foreman modules; library contract still needs TRD verification. |

Overall readiness score: **4.4**

Gate decision: **PASS**. Save PRD.

## 11. Open Clarifications

Ambiguity scan complete: 10 items marked for clarification.

1. Should this PRD require shipped SigNoz dashboards, or only queries/operators docs?
2. What default SigNoz log retention period should Foreman operators use?
3. Should the production default be direct-to-Langfuse traces plus collector-to-SigNoz logs, or one collector endpoint that fans out both traces and logs?
4. Which exact OTel log semantic convention/version should Foreman target?
5. Should log export standardize on OTLP HTTP/protobuf to match current trace config, or allow gRPC as first-class?
6. Is retention configured in Foreman docs only, or should Foreman ship a collector/SigNoz config fragment that enforces retention?
7. Should console logging remain enabled in production when SigNoz export is enabled?
8. Should exporter health be a Telemetry event, a Logger warning, a CLI doctor check, or all three?
9. What correlation behavior is expected when trace/span IDs exist only in Langfuse and not SigNoz?
10. Which log levels should be exported by default in production?

## 12. Suggested Next Step

Create a TRD from this PRD:

```bash
/ensemble-create-trd docs/PRD/PRD-2026-d852e34b-phoenix-otel-signoz-observability.md
```
