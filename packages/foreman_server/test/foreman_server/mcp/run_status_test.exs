defmodule ForemanServer.MCP.RunStatusTest do
  @moduledoc """
  `RunStatus.recovery` (TRD-005): the run projection's `run.recovery`, as the
  `foreman_run_status` tool reports it.

  `PhaseStatus.input_artifacts`, `run_id` and `task_id` (TRD-016): a two-phase
  run through `RunExecutor`, the command gateway, the aggregates and the
  projection, then read back through `phases_for_run/1` and the status tool.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, CommandRouter, Identity, ProjectionStore}
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.MCP.Tools
  alias ForemanServer.TestSupport.{ProjectionStoreReset, RunSlotsReset, UniqueIds}
  alias ForemanServer.Workflow.RunExecutor

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    run_id = "run-status-#{System.unique_integer([:positive])}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunStarted",
          payload: %{run_id: run_id, project_id: "p", task_id: "t", workflow_snapshot: %{}}
        }
      ])

    %{run_id: run_id}
  end

  test "a run that never needed recovery reports nil", %{run_id: run_id} do
    assert %{recovery: nil} = status!(run_id)
  end

  test "a resumed run reports outcome and elapsed time and nothing else", %{run_id: run_id} do
    record!(run_id, %{outcome: "resumed", elapsed_since_boot_ms: 640})

    assert %{recovery: recovery} = status!(run_id)
    assert recovery == %{outcome: "resumed", elapsed_since_boot_ms: 640}
    assert {:ok, _json} = Jason.encode(status!(run_id))
  end

  test "an effect outcome carries the effect fields, next to the blocked reason", %{
    run_id: run_id
  } do
    record!(run_id, %{
      outcome: "effect_blocked",
      elapsed_since_boot_ms: 910,
      effect_class: "push",
      effect_key: "effect:push:abc",
      effect_verdict: "unknown"
    })

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunBlocked",
          payload: %{run_id: run_id, project_id: "p", reason: "effect_outcome_ambiguous"}
        }
      ])

    assert %{
             status: "blocked",
             failure_reason: "effect_outcome_ambiguous",
             recovery: %{
               outcome: "effect_blocked",
               elapsed_since_boot_ms: 910,
               effect_class: "push",
               effect_key: "effect:push:abc",
               effect_verdict: "unknown"
             }
           } = status!(run_id)
  end

  describe "input artifacts of a two-phase run" do
    setup do
      :ok = ForemanServer.DispatcherQuiesce.suspend!()
      RunSlotsReset.reset!()

      run_id = UniqueIds.unique_run_id("inputs")
      project_id = "project-#{run_id}"
      repo = Path.join(System.tmp_dir!(), "inputs-#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo)
      on_exit(fn -> File.rm_rf(repo) end)

      {:ok, _} =
        CommandRouter.dispatch(%{
          type: "project.register",
          payload: %{project_id: project_id, path: repo},
          aggregate_id: "project:#{project_id}"
        })

      assert {:ok, started} =
               ForemanServer.RunAdmission.start(project_id, %{
                 run_id: run_id,
                 task_id: "task-#{run_id}",
                 workflow_snapshot: %{phases: []},
                 phase_specs: []
               })

      refute started in [:queued, :slot_queued]

      state = %{
        run_id: run_id,
        task: %{task_id: "task-#{run_id}", project_id: project_id},
        resuming?: false,
        resume_from: 0,
        phase_specs: [%{name: "first"}, %{name: "second"}],
        worktree_spec: %{enabled: false},
        plan_context: nil,
        artifact_base: Path.join(repo, "artifacts")
      }

      %{run_id: run_id, state: state, first: Identity.phase_id(run_id, 1)}
    end

    test "phase 1 starts with no inputs; phase 2 lists phase 1's artifact", ctx do
      %{run_id: run_id, state: state, first: first} = ctx
      sha = String.duplicate("a", 64)

      assert {:ok, state, _} = RunExecutor.phase_begin(state, Enum.at(state.phase_specs, 0), 0)
      assert %{input_artifacts: []} = phase_entry(run_id, 1)

      complete!(run_id, first, "artifacts/one.md", sha)
      assert {:ok, _state, _} = RunExecutor.phase_begin(state, Enum.at(state.phase_specs, 1), 1)

      assert %{input_artifacts: [input]} = phase_entry(run_id, 2)
      assert input == %{index: 0, source_phase: first, path: "artifacts/one.md", sha256: sha}
    end

    test "a phase whose predecessor recorded no artifact has no inputs", ctx do
      %{run_id: run_id, state: state} = ctx

      assert {:ok, state, _} = RunExecutor.phase_begin(state, Enum.at(state.phase_specs, 0), 0)
      assert {:ok, _state, _} = RunExecutor.phase_begin(state, Enum.at(state.phase_specs, 1), 1)

      assert %{input_artifacts: []} = phase_entry(run_id, 2)
    end

    test "a host launch records its execution profile, and the status DTO carries it", ctx do
      %{run_id: run_id, state: state} = ctx

      assert {:ok, _state, _} = RunExecutor.phase_begin(state, Enum.at(state.phase_specs, 0), 0)

      assert %{execution_profile: profile} = phase_entry(run_id, 1)
      assert profile.backend == "host_workflow"
      assert %{state: "unenforced", reason: fs_reason} = profile.filesystem
      assert %{state: "unenforced", reason: net_reason} = profile.network
      assert fs_reason != net_reason
      assert %{state: "unenforced"} = profile.credentials
      # The workflow disabled its worktree: nothing to clean up.
      assert %{state: "unenforced", reason: cleanup_reason} = profile.cleanup
      assert cleanup_reason =~ "no worktree"

      assert %{current_phase: %{execution_profile: ^profile}} = status!(run_id)
      assert {:ok, _json} = Jason.encode(status!(run_id))

      assert {:ok, events} = Store.read_all_streams_forward(0, 99_999_999)
      assert :ok = ProjectionStore.rebuild(events)
      assert [%{execution_profile: ^profile}] = ProjectionStore.phases_for_run(run_id)
    end

    test "a resumed retry records the inputs too", ctx do
      %{run_id: run_id, state: state, first: first} = ctx
      sha = String.duplicate("b", 64)

      assert {:ok, state, _} = RunExecutor.phase_begin(state, Enum.at(state.phase_specs, 0), 0)
      complete!(run_id, first, "artifacts/one.md", sha)
      assert {:ok, state, _} = RunExecutor.phase_begin(state, Enum.at(state.phase_specs, 1), 1)

      resume = %{state | resuming?: true, resume_from: 1}
      assert {:ok, _} = RunExecutor.__resume_prelude_for_test__(resume)

      second = Identity.phase_id(run_id, 2)
      assert {:ok, events} = Store.read_stream_forward("phase:#{run_id}:#{second}", 0, 50)
      assert [retried] = Enum.filter(events, &(&1.event_type == "PhaseRetried"))
      assert [%{source_phase: ^first, sha256: ^sha}] = atomized(retried.data.input_artifacts)

      assert %{attempt: 2, input_artifacts: [%{source_phase: ^first, sha256: ^sha}]} =
               phase_entry(run_id, 2)
    end

    test "the status DTO's current phase carries run_id, task_id and the inputs", ctx do
      %{run_id: run_id, state: state, first: first} = ctx
      sha = String.duplicate("c", 64)

      assert {:ok, state, _} = RunExecutor.phase_begin(state, Enum.at(state.phase_specs, 0), 0)
      complete!(run_id, first, "artifacts/one.md", sha)
      assert {:ok, _state, _} = RunExecutor.phase_begin(state, Enum.at(state.phase_specs, 1), 1)

      assert %{current_phase: current, task_id: task_id} = status!(run_id)
      assert task_id == "task-#{run_id}"

      assert %{
               phase_id: second,
               index: 2,
               run_id: ^run_id,
               task_id: ^task_id,
               input_artifacts: [%{index: 0, source_phase: ^first, sha256: ^sha}]
             } = Map.from_struct(current)

      assert second == Identity.phase_id(run_id, 2)
      assert {:ok, _json} = Jason.encode(status!(run_id))
    end

    test "the inputs survive a rebuild of the projection from the event log", ctx do
      %{run_id: run_id, state: state, first: first} = ctx

      assert {:ok, state, _} = RunExecutor.phase_begin(state, Enum.at(state.phase_specs, 0), 0)
      complete!(run_id, first, "artifacts/one.md", String.duplicate("d", 64))
      assert {:ok, _state, _} = RunExecutor.phase_begin(state, Enum.at(state.phase_specs, 1), 1)

      before = ProjectionStore.phases_for_run(run_id)
      assert [%{input_artifacts: []}, %{input_artifacts: [_]}] = before

      assert {:ok, events} = Store.read_all_streams_forward(0, 99_999_999)
      assert :ok = ProjectionStore.rebuild(events)

      assert ProjectionStore.phases_for_run(run_id) |> Enum.map(& &1.input_artifacts) ==
               Enum.map(before, & &1.input_artifacts)
    end
  end

  # TRD-017: the context identity of a launch, through the real launch path.
  describe "project context of a launch" do
    @describetag :tmp_dir

    defmodule NotesProvider do
      @behaviour ForemanServer.ProjectContext.SectionProvider

      def section(_project_id) do
        body = Enum.map_join(1..40, "\n", &"- note #{&1}, the key is sk-launch-secret-9999")
        {:ok, ForemanServer.ProjectContext.Section.new(:memory, "Project memory", body)}
      end
    end

    setup %{tmp_dir: dir} do
      :ok = ForemanServer.DispatcherQuiesce.suspend!()
      RunSlotsReset.reset!()

      store = Application.get_env(:foreman_server, :secret_store)
      Application.put_env(:foreman_server, :secret_store, Keyword.put(store, :dir, dir))
      original = Application.get_env(:foreman_server, :project_context)

      Application.put_env(:foreman_server, :project_context,
        section_providers: [NotesProvider],
        section_caps: %{memory: 300}
      )

      on_exit(fn ->
        Application.put_env(:foreman_server, :secret_store, store)

        if original,
          do: Application.put_env(:foreman_server, :project_context, original),
          else: Application.delete_env(:foreman_server, :project_context)
      end)

      run_id = UniqueIds.unique_run_id("ctx")
      project_id = "project-#{run_id}"

      {:ok, _} =
        CommandRouter.dispatch(%{
          type: "project.register",
          payload: %{project_id: project_id, path: dir},
          aggregate_id: "project:#{project_id}"
        })

      assert {:ok, :stored} =
               ForemanServer.SecretStore.put(project_id, "LAUNCH_KEY", "sk-launch-secret-9999")

      assert {:ok, started} =
               ForemanServer.RunAdmission.start(project_id, %{
                 run_id: run_id,
                 task_id: "task-#{run_id}",
                 workflow_snapshot: %{phases: []},
                 phase_specs: []
               })

      refute started in [:queued, :slot_queued]

      state = %{
        run_id: run_id,
        task: %{task_id: "task-#{run_id}", project_id: project_id},
        resuming?: false,
        resume_from: 0,
        phase_specs: [%{name: "first"}],
        completed: [],
        worktree_spec: %{enabled: false},
        plan_context: nil,
        artifact_base: Path.join(dir, "artifacts")
      }

      %{run_id: run_id, state: state}
    end

    test "the phase entry and the DTO's current phase carry the truncating, redacting launch",
         %{run_id: run_id, state: state} do
      spec = Enum.at(state.phase_specs, 0)
      assert {:ok, state, _} = RunExecutor.phase_begin(state, spec, 0)
      assert {:ok, launch} = RunExecutor.phase_launch(state, spec, 0, nil)

      assert %{context: context} = phase_entry(run_id, 1)

      assert Map.keys(context) |> Enum.sort() ==
               [:bytes, :redaction_scope, :redactions, :sections, :sha256, :truncated]

      assert context.redaction_scope == "project_context_sections"
      assert context.redactions > 0
      assert [%{section: "memory", omitted_bytes: omitted}] = context.truncated
      assert omitted > 0
      assert %{bytes: bytes} = Enum.find(context.sections, &(&1.id == "memory"))
      assert bytes < context.bytes

      # The hash is of the text the agent was handed.
      assert [system_prompt: system_text] =
               Keyword.take(launch.driver_opts.(1_000), [:system_prompt])

      assert context.sha256 == Identity.sha256(system_text)
      refute system_text =~ "sk-launch-secret-9999"

      assert %{current_phase: %{context: ^context}} = status!(run_id)
      assert {:ok, _json} = Jason.encode(status!(run_id))
    end

    test "a phase that recorded no context reports nil", %{run_id: run_id, state: state} do
      Application.put_env(:foreman_server, :project_context, section_providers: [])
      spec = Enum.at(state.phase_specs, 0)

      assert {:ok, state, _} = RunExecutor.phase_begin(state, spec, 0)
      assert {:ok, _launch} = RunExecutor.phase_launch(state, spec, 0, nil)

      assert %{current_phase: %{context: nil}} = status!(run_id)
    end
  end

  # Events read back from the store carry whatever key form the writer used.
  defp atomized(entries) do
    Enum.map(entries, fn entry ->
      Map.new(entry, fn
        {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
        pair -> pair
      end)
    end)
  end

  defp phase_entry(run_id, index),
    do: Enum.find(ProjectionStore.phases_for_run(run_id), &(&1.index == index))

  defp complete!(run_id, phase_id, path, sha) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "phase.complete",
        command_id: "test:complete:#{phase_id}",
        aggregate_id: "phase:#{run_id}:#{phase_id}",
        payload: %{
          run_id: run_id,
          phase_id: phase_id,
          index: 1,
          artifact_path: path,
          artifact_sha256: sha,
          artifact_bytes: 12
        }
      })
  end

  defp record!(run_id, fields) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunRecoveryAttempted",
          payload: Map.put(fields, :run_id, run_id)
        }
      ])
  end

  defp status!(run_id) do
    assert {:ok, dto} = Tools.call_tool("foreman_run_status", %{run_id: run_id})
    dto
  end
end
