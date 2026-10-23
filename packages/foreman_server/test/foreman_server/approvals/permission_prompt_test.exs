defmodule ForemanServer.Approvals.PermissionPromptTest do
  # In-flight approvals end to end through the real gateway, aggregates, projection and
  # Deliverer: a claude permission prompt blocks in `PermissionPrompt.decide/3` until the
  # operator's `tool.approve` / `tool.deny` (or a timeout, or the run ending) answers it.
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.ToolCall
  alias ForemanServer.Approvals.{Deliverer, Inflight, PermissionPrompt}
  alias ForemanServer.{CommandGateway, CommandRouter, ProjectionStore}

  setup do
    :ok = ProjectionStore.subscribe(replay_existing: false)
    start_supervised!(Inflight)
    start_supervised!(Deliverer)
    :ok
  end

  defp start_run! do
    project_id = "p-#{System.unique_integer([:positive])}"
    run_id = "run-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        aggregate_id: "project:#{project_id}",
        command_id: "register:#{project_id}",
        type: "project.register",
        payload: %{project_id: project_id, name: project_id, path: System.tmp_dir!()}
      })

    {:ok, _} =
      CommandRouter.dispatch_run_start(project_id, %{
        run_id: run_id,
        task_id: "task-#{run_id}",
        workflow_snapshot: %{phases: [%{id: "phase-1", kind: "command"}]},
        phase_specs: [%{phase_id: "phase-1", kind: "command"}],
        approval_id: "approval-#{run_id}"
      })

    await("RunStarted", :run_id, run_id)
    {project_id, run_id}
  end

  # The agent's side: what `claude --permission-prompt-tool` sends, blocking in a task.
  defp prompt(run_id, use_id, opts \\ []) do
    args = %{
      "tool_name" => "Write",
      "input" => %{"file_path" => "/w/a.txt", "content" => "hi"},
      "tool_use_id" => use_id
    }

    Task.async(fn -> PermissionPrompt.decide(run_id, args, opts) end)
  end

  defp decide!(type, run_id, id) do
    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: type,
        command_id: "op:#{type}:#{run_id}:#{id}",
        aggregate_id: ToolCall.stream_id(run_id, id),
        payload: %{run_id: run_id, tool_call_id: id}
      })
  end

  defp field(data, key) do
    data = if is_struct(data), do: Map.from_struct(data), else: data
    Map.get(data, key, Map.get(data, to_string(key)))
  end

  defp await(type, key, id) do
    receive do
      {:projection_event, %{event_type: ^type, data: data}} ->
        if field(data, key) == id, do: data, else: await(type, key, id)

      {:projection_event, _other} ->
        await(type, key, id)
    after
      15_000 -> flunk("timed out waiting for #{type} on #{id}")
    end
  end

  test "the prompt blocks until the operator approves, then allows the same input and finishes the call" do
    {_project_id, run_id} = start_run!()
    task = prompt(run_id, "toolu_a")
    id = "inflight-toolu_a"

    requested = await("ToolCallRequested", :run_id, run_id)
    assert field(requested, :tool_call_id) == id
    assert field(requested, :delivery) == "inflight"
    assert field(requested, :tool_name) == "Write"
    assert %{status: "requested"} = ProjectionStore.tool_call(run_id, id)
    assert Task.yield(task, 100) == nil, "the call must stay blocked while undecided"

    decide!("tool.approve", run_id, id)

    assert %{"behavior" => "allow", "updatedInput" => %{"content" => "hi"}} = Task.await(task)
    finished = await("ToolCallFinished", :run_id, run_id)
    assert field(finished, :outcome) == "delivered"
    assert %{status: "finished"} = ProjectionStore.tool_call(run_id, id)
    # No phase re-run machinery: the run was never paused or steered.
    assert %{status: status} = ProjectionStore.run(run_id)
    refute status == "paused"
  end

  test "an operator denial reaches the agent as a refusal it can read" do
    {_project_id, run_id} = start_run!()
    task = prompt(run_id, "toolu_d")
    id = "inflight-toolu_d"
    await("ToolCallRequested", :run_id, run_id)

    decide!("tool.deny", run_id, id)

    assert %{"behavior" => "deny", "message" => message} = Task.await(task)
    assert message =~ "operator denied permission to use the `Write` tool"
    assert %{status: "denied"} = ProjectionStore.tool_call(run_id, id)
  end

  test "nobody answering denies by default, recorded as a system timeout denial" do
    {_project_id, run_id} = start_run!()

    task = prompt(run_id, "toolu_t", timeout_ms: 50, grace_ms: 5_000)

    assert %{"behavior" => "deny", "message" => message} = Task.await(task)
    assert message =~ "Nobody answered"

    assert %{status: "denied", decided_by: "system", reason: "timeout"} =
             ProjectionStore.tool_call(run_id, "inflight-toolu_t")
  end

  test "a run that ends while the call is blocked expires the request and denies" do
    {_project_id, run_id} = start_run!()
    task = prompt(run_id, "toolu_e")
    id = "inflight-toolu_e"
    await("ToolCallRequested", :run_id, run_id)

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.cancel",
        command_id: "test-cancel:#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{run_id: run_id}
      })

    assert %{"behavior" => "deny", "message" => message} = Task.await(task)
    assert message =~ "run ended"
    assert %{status: "expired", reason: "run_ended"} = ProjectionStore.tool_call(run_id, id)
  end

  test "a client that went away releases the blocked call and expires its request" do
    {_project_id, run_id} = start_run!()
    args = %{"tool_name" => "Write", "input" => %{}, "tool_use_id" => "toolu_gone"}
    task = Task.async(fn -> PermissionPrompt.decide(run_id, args, []) end)
    await("ToolCallRequested", :run_id, run_id)

    assert :ok = PermissionPrompt.client_gone(run_id, args)

    assert %{"behavior" => "deny"} = Task.await(task)

    assert %{status: "expired", reason: "client_gone"} =
             ProjectionStore.tool_call(run_id, "inflight-toolu_gone")
  end

  test "a run that is not active, or a malformed prompt, is denied without recording a request" do
    {_project_id, run_id} = start_run!()

    assert %{"behavior" => "deny"} =
             PermissionPrompt.decide(
               "no-such-run",
               %{"tool_name" => "Write", "tool_use_id" => "t"},
               []
             )

    assert %{"behavior" => "deny", "message" => message} =
             PermissionPrompt.decide(run_id, %{"tool_name" => "Write"}, [])

    assert message =~ "tool_use_id"
    assert ProjectionStore.run_approvals(run_id, status: :all) == []
  end

  test "a redelivered prompt for a call the operator already denied is denied again, not re-asked" do
    {_project_id, run_id} = start_run!()
    task = prompt(run_id, "toolu_x")
    await("ToolCallRequested", :run_id, run_id)
    decide!("tool.deny", run_id, "inflight-toolu_x")
    assert %{"behavior" => "deny"} = Task.await(task)

    assert %{"behavior" => "deny"} = Task.await(prompt(run_id, "toolu_x"))
    assert [_one] = ProjectionStore.run_approvals(run_id, status: :all)
  end

  test "claude_options hands the adapter the permission tool and a per-run credential" do
    Application.put_env(:foreman_server, :approvals, inflight_base_url: "http://127.0.0.1:4766/")
    on_exit(fn -> Application.delete_env(:foreman_server, :approvals) end)

    assert [mcp_config: %{"foreman_permission" => server}, provider_options: provider_options] =
             Inflight.claude_options("run-1")

    assert provider_options == %{cli_path: Inflight.wrapper_path()}
    assert server["url"] == "http://127.0.0.1:4766/agent-permission/run-1"
    assert server["headers"] == %{"Authorization" => "Bearer " <> Inflight.token("run-1")}
    assert Inflight.valid_token?("run-1", Inflight.token("run-1"))
    refute Inflight.valid_token?("run-2", Inflight.token("run-1"))
    refute Inflight.valid_token?("run-1", nil)
  end

  @tag :tmp_dir
  test "the claude wrapper adds the permission-prompt tool and passes every adapter argument through",
       %{tmp_dir: dir} do
    fake = Path.join(dir, "fake-claude")
    File.write!(fake, "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n")
    File.chmod!(fake, 0o755)

    {out, 0} =
      System.cmd(Inflight.wrapper_path(), ["--print", "--mcp-config", "{}", "--", "do it"],
        env: [{"FOREMAN_CLAUDE_CLI", fake}]
      )

    assert String.split(out, "\n", trim: true) ==
             [
               "--permission-prompt-tool",
               "mcp__foreman_permission__approve",
               "--print",
               "--mcp-config",
               "{}",
               "--",
               "do it"
             ]

    assert Inflight.prompt_tool() == "mcp__foreman_permission__approve"
  end
end
