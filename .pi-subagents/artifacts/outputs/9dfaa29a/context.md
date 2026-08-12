# Code Context

## Files Retrieved
1. `packages/foreman_server/lib/foreman_server/aggregates/vcs_operation.ex` (lines 1-180) - VCS cmds/events/state machine.
2. `packages/foreman_server/lib/foreman_server/vcs_adapter.ex` (lines 1-105) - VCS behaviour + retry wrapper.
3. `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex` (lines 1-172) - default git/gh shell impl.
4. `packages/foreman_server/lib/foreman_server/events/vcs_operation_started.ex` (lines 1-5), `...completed.ex` (1-5), `...failed.ex` (1-5) - typed event payload structs.
5. `packages/foreman_server/lib/foreman_server/workflow/interpreter.ex` (lines 1-340) - workflow YAML phase schema/parser/validation.
6. `packages/foreman_server/lib/foreman_server/workflow/catalog.ex` (lines 70-190) - runtime catalog API/root/reload behavior.
7. `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` (lines 1-560) - phase dispatch, command handling, context/cwd field.
8. `packages/foreman_server/priv/defaults/workflows/plan.yaml` (lines 1-8), `implement.yaml` (1-10) - current fixture manifests.
9. `packages/foreman_server/test/foreman_server/aggregates/vcs_operation_test.exs` (lines 1-119) - aggregate coverage.
10. `packages/foreman_server/test/foreman_server/vcs_adapter_default_test.exs` (lines 1-37) - Default adapter API/retry coverage.
11. `packages/foreman_server/test/foreman_server/workflow/run_executor_command_test.exs` (lines 1-308) - command phase + requiredFile + working_directory assertions.
12. `packages/foreman_server/test/foreman_server/workflow/run_executor_gates_test.exs` (lines 31-66 from grep) - requiredFile traversal edge cases.
13. `docs/cli-reference.md` (lines 156-230, 260-277), `README.md` (lines 20-35) - docs refs.

## Key Code

### VcsOperation cmds/events
- `VcsOperation.State`: `%State{exists?, operation_id, status, terminal?}`. Terminal statuses: `cleaned|merged|failed|blocked`. `packages/foreman_server/lib/foreman_server/aggregates/vcs_operation.ex:7-12`.
- Existing worktree/merge/PR cmds: `vcs.worktree.create`, `vcs.worktree.clean`, `vcs.merge.request`, `vcs.pr.observe`, `vcs.pr.merge`, `vcs.merge.fail`, `vcs.merge.block`. Map to `WorktreeCreated`, `WorktreeCleaned`, `VcsMergeRequested`, `PrGateObserved`, `PrMerged`, `MergeFailed`, `MergeBlocked`. `.../vcs_operation.ex:108-139`.
- Generic adapter lifecycle cmds: `vcs_operation.start|complete|fail` -> `VcsOperationStarted|Completed|Failed`, stream `vcs_operation:<id>`. `.../vcs_operation.ex:143-177`.
- Event structs only cover generic lifecycle: started fields `operation_id, operation_type, target`; completed adds `result`; failed adds `error, retries`. `packages/foreman_server/lib/foreman_server/events/vcs_operation_*.ex:1-5`.
- Risk: worktree-specific event structs not found. Aggregate accepts event_type string/payload maps.

### VcsAdapter.Default funcs
- Behaviour callbacks only: `clone(url, opts)`, `branch(path, name)`, `create_pr(path, opts)`. No `worktree` callback. `packages/foreman_server/lib/foreman_server/vcs_adapter.ex:28-47`.
- Retry wrapper supports only `:clone | :branch | :create_pr`. `.../vcs_adapter.ex:59-66,82-89`.
- Default `clone`: `git clone --depth 1 <url> <target>`, default target `/tmp/vcs-<operation_id>`, emits generic lifecycle. `.../vcs_adapter/default.ex:18-36`.
- Default `branch`: `git -C <path> checkout -b <name>`. `.../vcs_adapter/default.ex:39-56`.
- Default `create_pr`: `gh pr create ...`, `System.cmd(..., cd: path)`. `.../vcs_adapter/default.ex:59-82`.
- Emitters dispatch `vcs_operation.start|complete|fail` via `CommandGateway.dispatch_system`. `.../vcs_adapter/default.ex:126-170`.
- Severity high: git command builds charlist then `String.split`, so URL/target spaces not safe. Relevant if worktree paths are workflow-configured. `.../vcs_adapter/default.ex:23-26`.

### Workflow interpreter/catalog phase schema
- Required top-level keys: `name`, `phases`. Required phase key: `name`. Allowed phase actions exactly one of `prompt`, `command`, `bash`. `packages/foreman_server/lib/foreman_server/workflow/interpreter.ex:9-11,165-245`.
- Parser supports top-level scalar mappings, `phases:` list, phase scalar props, and one-level nested maps at indent 6. `.../interpreter.ex:86-163`.
- `command` must be slash invocation starting `/`. `bash` currently allowed by interpreter. `.../interpreter.ex:248-260`.
- `requiredFile` optional. Must be non-empty dotted key. `.../interpreter.ex:266-306`.
- Catalog loads by filename, reads prompts by basename, root default via `AssetCatalog.default()`, auto-installs when no manifests, reloadable/polled. `packages/foreman_server/lib/foreman_server/workflow/catalog.ex:72-190`.
- Fixtures: `plan.yaml` has command phases + `requiredFile`; `implement.yaml` has prompt phase with model/artifact/mail keys (parser accepts extra scalar/nested keys). `packages/foreman_server/priv/defaults/workflows/plan.yaml:1-8`, `implement.yaml:1-10`.

### RunExecutor dispatch/cwd handling
- `init/2` takes `task_projection.workflow_snapshot.phases` as-is into `state.phase_specs`. No obvious normalization in executor. `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:116-140`.
- Kickoff claims task, starts phase 0. Next phases via `handle_cast({:advance_to, index})`, `Process.send_after({:start_at,next})`. `.../run_executor.ex:146-207`.
- Phase seq: validate action -> emit `phase.start` -> `execute_agent` -> write artifact -> enforce `requiredFile` -> describe artifact -> emit `phase.complete`; else emit `phase.fail`. `.../run_executor.ex:226-247`.
- Command dispatch: if `phase_spec.action == :command`, prompt passed to agent is `phase_spec.command` at byte zero; not shell-executed. `.../run_executor.ex:249-305`.
- `:bash` rejected at executor despite interpreter allowing it. `.../run_executor.ex:249-260`.
- Context includes string keys `phase_id`, `run_id`, `task_id`, `working_directory`. `working_directory` = `task[:working_directory]` if present/non-empty, else `$HOME`. Then merges plan_context, then phase `context`. `.../run_executor.ex:515-531`.
- No actual process cwd/chdir in RunExecutor. Agent receives cwd only as context key. No `cd:` option in AgentRuntime call. `.../run_executor.ex:299-305,515-531`.
- Artifact path templates only expand `{run_id}` and `{task_id}`. `.../run_executor.ex:352-372`.

## Architecture
- Workflows live as YAML under `priv/defaults/workflows` and runtime `~/.foreman/workflows`.
- `Workflow.Interpreter` parses permissive phase maps, validates action/requiredFile.
- `Workflow.Catalog` owns loaded manifests/prompts, hot-reloads, returns snapshots.
- Run admission stores `workflow_snapshot` on task/run projection; `RunExecutor` consumes `workflow_snapshot.phases`.
- RunExecutor executes all phases through AgentRuntime Pi backend. `command:` means slash command prompt, not OS command. `bash` manifests load but executor fails as unsupported.
- VCS domain is separate today. `VcsAdapter.Default` can clone/branch/create_pr and emits generic `VcsOperation*` events. Aggregate also has older logical worktree/merge/PR commands/events, but Default does not call them.
- CWD model today is context-only. Worktree support likely needs explicit resolved execution root passed to AgentRuntime and/or task `working_directory` mutation/snapshot.

## Start Here
Open `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`. It owns phase dispatch and currently only supplies `working_directory` as context, making it the integration point for workflow-configured worktree cwd.

## Tests / fixtures likely impacted
- `packages/foreman_server/test/foreman_server/workflow/run_executor_command_test.exs:154-308` - command prompt + working_directory assertions; add worktree-cwd regression here.
- `packages/foreman_server/test/foreman_server/workflow/interpreter_test.exs` - add schema validation for any new workflow `vcs`/`worktree` fields.
- `packages/foreman_server/test/foreman_server/workflow/catalog_test.exs` - if catalog normalization/digest changes.
- `packages/foreman_server/test/foreman_server/vcs_adapter_default_test.exs` - add `git worktree add/remove` shell behavior or exported funcs.
- `packages/foreman_server/test/foreman_server/aggregates/vcs_operation_test.exs` - extend for new cmds/events if aggregate contract changes.
- Fixtures: `packages/foreman_server/priv/defaults/workflows/*.yaml`, esp `implement.yaml`/`plan.yaml`.

## Docs refs
- Docs discipline in `AGENTS.md`: update `CLAUDE.md`, `AGENTS.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md` when behavior/workflows/operator expectations change.
- `docs/cli-reference.md:156-198` documents workflow install/catalog root semantics.
- `docs/cli-reference.md:200-230` documents plan workflow phases/context/requiredFile.
- `README.md:20-35` points to Workflow.Catalog and RunExecutor task-provider boundary.
- No direct docs found for VcsAdapter/Default worktree support. Only `docs/standards/constitution.md:240` mentions `VcsOperation` noncompliance.

## Review Findings
- high: `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:515-531` - cwd is context-only; adding worktree support must define whether AgentRuntime actually runs in worktree or only prompts agents to cd.
- high: `packages/foreman_server/lib/foreman_server/vcs_adapter.ex:28-47` - adapter behaviour lacks worktree callbacks; Default cannot be used polymorphically for worktree ops without behaviour change.
- medium: `packages/foreman_server/lib/foreman_server/workflow/interpreter.ex:147-163` - YAML parser supports only one-level nested maps; complex VCS config arrays/lists likely need parser expansion or constrained schema.
- medium: `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:249-260` - interpreter allows `bash`, executor rejects; avoid designing worktree setup as `bash:` unless executor support is intended.
- medium: `packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex:23-26` - clone command split is unsafe for paths/URLs with spaces; worktree path config may hit this.

## Residual Risks
- Did not trace run admission workflow snapshot normalization due time; executor suggests phases already atom-keyed in tests but manifests parse string-keyed.
- Did not inspect AgentRuntime adapters for cwd support; RunExecutor call passes none.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Concrete file/line findings listed for VcsOperation, VcsAdapter.Default, workflow schema/catalog, RunExecutor cwd/dispatch, tests/fixtures, docs; severity included under Review Findings."
    }
  ],
  "changedFiles": [],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "find/grep/read targeted repo inspection plus nl/sed line anchoring",
      "result": "passed",
      "summary": "Mapped requested VCS/workflow/RunExecutor/docs areas."
    }
  ],
  "validationOutput": [
    "No edits made except required artifact write."
  ],
  "residualRisks": [
    "Did not trace run admission workflow snapshot normalization.",
    "Did not inspect AgentRuntime adapters for cwd support."
  ],
  "noStagedFiles": true,
  "diffSummary": "No repo source diff; wrote scout artifact only.",
  "reviewFindings": [
    "high: packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:515-531 - cwd is context-only; worktree support must define actual execution cwd vs prompt context.",
    "high: packages/foreman_server/lib/foreman_server/vcs_adapter.ex:28-47 - behaviour lacks worktree callbacks.",
    "medium: packages/foreman_server/lib/foreman_server/workflow/interpreter.ex:147-163 - parser only supports one-level nested maps.",
    "medium: packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:249-260 - interpreter allows bash but executor rejects it.",
    "medium: packages/foreman_server/lib/foreman_server/vcs_adapter/default.ex:23-26 - git clone arg splitting unsafe for paths with spaces."
  ],
  "manualNotes": "Recon only. Artifact written to requested path."
}
```