defmodule ForemanServer.Workflow.RunExecutorProjectContextTest do
  # Standing project context reaches the REAL `Jido.Harness.RunRequest` of a
  # workflow agent phase: the launch's `driver_opts` are handed to
  # `JidoHarness.Driver.run/3` (the call `JidoHarnessWorker` makes) against a
  # recording provider adapter.
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.JidoHarness.Driver
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.RunExecutor
  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, Event, ProviderStatus}

  defmodule Recorder do
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :pi,
        name: "project-context recorder",
        executable: "stub",
        capabilities: %Capabilities{streaming?: true, resume?: true},
        normalized_options: [:system_prompt],
        provider_options: []
      }
    end

    @impl true
    def status(_config) do
      {:ok,
       %ProviderStatus{
         provider: :pi,
         installed: true,
         compatible: true,
         authenticated: true,
         smoke_ready: true,
         capabilities: %Capabilities{streaming?: true, resume?: true},
         executable: "stub"
       }}
    end

    @impl true
    def run(request, _context) do
      send(Application.fetch_env!(:jido_harness, :project_context_test_pid), {:request, request})

      {:ok,
       [
         Event.new!(provider: :pi, type: :output_text_final, payload: %{"text" => "ok"}),
         Event.new!(provider: :pi, type: :run_completed, payload: %{})
       ]}
    end
  end

  defmodule Unsupported do
    @behaviour Adapter

    @impl true
    def spec, do: %{Recorder.spec() | normalized_options: []}
    @impl true
    defdelegate status(config), to: Recorder
    @impl true
    defdelegate run(request, context), to: Recorder
  end

  setup do
    ProjectionStoreReset.reset!()
    original = Application.get_env(:jido_harness, :providers, %{})
    Application.put_env(:jido_harness, :providers, %{pi: Recorder})
    Application.put_env(:jido_harness, :project_context_test_pid, self())

    on_exit(fn ->
      Application.put_env(:jido_harness, :providers, original)
      Application.delete_env(:jido_harness, :project_context_test_pid)
      ProjectionStoreReset.reset!()
    end)

    :ok
  end

  defp register(id, config) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: id, path: "/srv/repos/#{id}", config: config}
        }
      ])
  end

  defp state(project_id, workflow_name \\ "implement") do
    %{
      run_id: "run-ctx",
      plan_context: %{},
      task: %{
        task_id: "t1",
        project_id: project_id,
        workflow_snapshot: %{"workflow_name" => workflow_name, "input" => %{"prompt" => "go"}}
      },
      completed: [],
      phase_specs: [],
      artifact_base: System.tmp_dir!()
    }
  end

  defp launch(state, phase_spec) do
    {:ok, launch} =
      RunExecutor.__prepare_agent_launch_for_test__(
        state,
        Map.put_new(phase_spec, :name, :implement),
        0,
        1,
        nil
      )

    launch
  end

  defp request_for(launch) do
    opts = launch.driver_opts.(60_000)
    assert {:ok, _result} = Driver.run(:pi, launch.launch_opts[:prompt], opts)
    assert_receive {:request, request}
    request
  end

  test "project instructions reach RunRequest.system_prompt for an ordinary agent phase" do
    register("ctx-1", %{instructions: "Always use tabs"})

    request = request_for(launch(state("ctx-1"), %{}))

    assert request.system_prompt =~ "Always use tabs"
    assert request.system_prompt =~ "/srv/repos/ctx-1"
  end

  test "a project with no instructions or memory launches with no system_prompt" do
    register("ctx-2", %{})
    request = request_for(launch(state("ctx-2"), %{}))
    assert request.system_prompt == nil
  end

  test "an unregistered project launches with the pre-existing system_prompt (nil)" do
    request = request_for(launch(state("never-registered"), %{}))
    assert request.system_prompt == nil
  end

  test "covered command phases keep the inbox prompt AFTER the project context" do
    register("ctx-3", %{instructions: "Always use tabs"})

    phase =
      ForemanServer.Workflow.PhaseSpec.normalize(%{
        "name" => "create-prd",
        "command" => "/skill:ensemble-create-prd {{input.prompt}}"
      })

    request = request_for(launch(state("ctx-3", "prd"), phase))

    inbox = RunExecutor.__command_phase_inbox_progress_system_prompt_for_test__()
    assert {ctx_at, _} = :binary.match(request.system_prompt, "Always use tabs")
    assert {inbox_at, _} = :binary.match(request.system_prompt, inbox)
    assert ctx_at < inbox_at
  end

  test "a provider without system_prompt support gets the context prefixed to the prompt" do
    register("ctx-5", %{instructions: "Always use tabs"})

    Application.put_env(:jido_harness, :providers, %{pi: Unsupported})

    launch = launch(state("ctx-5"), %{})

    refute Keyword.has_key?(launch.driver_opts.(60_000), :system_prompt)
    assert launch.launch_opts[:prompt] =~ "Always use tabs"
  end

  test "append_system_prompt merges with, and never overwrites, an existing prompt" do
    assert RunExecutor.__append_system_prompt_for_test__([system_prompt: "first"], "second")[
             :system_prompt
           ] == "first\n\nsecond"

    assert RunExecutor.__append_system_prompt_for_test__([], nil) == []
  end

  describe "prompt template assigns" do
    test "expose project_context, project_instructions and project_memory" do
      register("ctx-4", %{instructions: "Rule one"})

      assigns = RunExecutor.prompt_template_assigns(state("ctx-4"), %{name: "implement"}, 0, %{})

      assert assigns["project_instructions"] =~ "Rule one"
      assert assigns["project_context"] =~ "Rule one"
      assert assigns["project_memory"] == ""
    end

    test "default to empty strings for a project with no context" do
      assigns =
        RunExecutor.prompt_template_assigns(state("missing"), %{name: "implement"}, 0, %{})

      assert %{"project_context" => "", "project_instructions" => "", "project_memory" => ""} =
               assigns
    end
  end
end
