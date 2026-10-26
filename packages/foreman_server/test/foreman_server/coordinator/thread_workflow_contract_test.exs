defmodule ForemanServer.Coordinator.ThreadWorkflowContractTest do
  @moduledoc """
  foreman-ig27o: the one captured case of "no threads after a three-item paste" was three
  `start_thread` actions that named neither a `workflow` nor a `task_type`, so
  `WorkflowSelector` rejected all three ("no workflow could be chosen") and nothing started.
  The action schema (`Action`) marks both keys optional and the selector demands one of them,
  so the model has to be TOLD that: by the prompt, and by the types each listed workflow serves.
  Measured on the real coordinator (pi/MiniMax, the flow's paste, `Context.build/2` plus
  `Agent.Harness.turn/2` on a live node): 7 of 88 answers (8%) carried no selectable workflow
  before this contract was spelled out, 0 of 76 after.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Coordinator.Context.Sources.Live
  alias ForemanServer.Coordinator.WorkflowSelector
  alias ForemanServer.Workflow.AssetCatalog
  alias ForemanServer.Workflow.Catalog

  @moduletag :tmp_dir

  @prompt_path "coordinator/system_prompt.md"

  defp manifest(name, task_types) do
    types = if task_types == [], do: "", else: "task_types: [#{Enum.join(task_types, ", ")}]\n"

    "name: #{name}\ndescription: #{name} workflow\n#{types}phases:\n  - name: p1\n    command: /skill:x\n"
  end

  describe "Sources.Live.workflows/0" do
    setup %{tmp_dir: tmp} do
      server_name = :"thread_workflow_contract_#{System.unique_integer([:positive])}"
      prev_server = Application.get_env(:foreman_server, :workflow_catalog)
      prev_poll = Application.get_env(:foreman_server, :workflow_catalog_poll_ms)
      Application.put_env(:foreman_server, :workflow_catalog, server_name)
      Application.put_env(:foreman_server, :workflow_catalog_poll_ms, 600_000)

      on_exit(fn ->
        if prev_server,
          do: Application.put_env(:foreman_server, :workflow_catalog, prev_server),
          else: Application.delete_env(:foreman_server, :workflow_catalog)

        if prev_poll,
          do: Application.put_env(:foreman_server, :workflow_catalog_poll_ms, prev_poll),
          else: Application.delete_env(:foreman_server, :workflow_catalog_poll_ms)
      end)

      File.mkdir_p!(Path.join(tmp, "prompts"))
      File.write!(Path.join(tmp, "edit.yaml"), manifest("edit", ["task", "bug", "chore"]))
      File.write!(Path.join(tmp, "review.yaml"), manifest("review", []))

      start_supervised!({Catalog, name: server_name, catalog: AssetCatalog.new(tmp)},
        id: server_name
      )

      :ok
    end

    test "names, per workflow, the task types that resolve to it through the selector's own map" do
      workflows = Map.new(Live.workflows(), &{&1.name, &1})

      assert %{task_types: ["bug", "chore", "task"]} = workflows["edit"]
      assert %{task_types: []} = workflows["review"]

      # Every type shown is one the selector accepts, and it lands on the workflow it was shown under.
      for %{name: name, task_types: types} <- Map.values(workflows), type <- types do
        assert {:ok, ^name} =
                 WorkflowSelector.select(
                   %{"title" => "t", "prompt" => "p", "task_type" => type},
                   Map.keys(workflows),
                   []
                 )
      end
    end
  end

  describe "the system prompt" do
    setup do
      {:ok, prompt: File.read!(Path.join(:code.priv_dir(:foreman_server), @prompt_path))}
    end

    test "says a thread needs a workflow or a task_type, as WorkflowSelector enforces", %{
      prompt: prompt
    } do
      # The selector: neither key -> rejected, which is what the prompt must warn about.
      assert {:error, :no_workflow} =
               WorkflowSelector.select(%{"title" => "t", "prompt" => "p"}, ["edit"], [])

      [start_thread] = Regex.run(~r/^- `start_thread`.*$/m, prompt)
      [propose_threads] = Regex.run(~r/^- `propose_threads`.*$/m, prompt)

      for line <- [start_thread, propose_threads] do
        assert line =~ "workflow or task_type (at least one)"
        refute line =~ "workflow?"
        refute line =~ "task_type?"
      end

      assert start_thread =~ "rejected and nothing starts"

      assert [rule6] = Regex.run(~r/^6\. .*$/m, prompt)
      assert rule6 =~ "MUST say which workflow runs it"
      assert rule6 =~ "NOTHING starts"
      assert rule6 =~ "listed in brackets on a WORKFLOWS line"
    end
  end
end
