# Hot-Loadable Workflow Format (HLW-T001, TRD-2026-4212be7e)
Bead: foreman-omn4
Authored: 2026-08-19

## Overview
Hot-loadable workflows support two formats: YAML and Elixir DSL.

## YAML schema
workflow:
  id: <string>
  name: <string>
  version: <semver>
  steps:
    - name: <string>
      skill: <string>
      idempotency_key: <string>
      timeout_ms: <integer>
      on_failure: halt|continue
      inputs:
        <key>: <value>

## Elixir DSL schema
defmodule MyApp.Workflows.MyWorkflow do
  use ForemanServer.Workflow.HotLoadable,
    id: "my-workflow",
    name: "My Workflow",
    version: "1.0.0",
    steps: [
      step(:create_prd, "ensemble:create-prd", idempotency_key: "my-wf-create-prd", timeout_ms: 600_000)
    ]
end

## Validation rules
- id: required, lowercase, dash-separated
- version: required, semver
- steps: required, non-empty
- skill: required, must be a known ensemble skill
- idempotency_key: optional, auto-generated if absent

## Loading
- YAML: parsed by ForemanServer.Workflow.Loader.load_yaml/1
- DSL: compiled at module load time

## Hot reload
File watcher: :file_system event listener. Debounce: 100ms.
