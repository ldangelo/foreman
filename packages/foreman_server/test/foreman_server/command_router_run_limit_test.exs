defmodule ForemanServer.CommandRouterRunLimitTest do
  use ExUnit.Case

  alias ForemanServer.{Aggregate, CommandRouter, EventStore, ProjectionStore}
  alias ForemanServer.Aggregates.ProjectRunLimit

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-command-router-run-limit-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    :ok
  end

  test "concurrent starts reserve exactly 100 project slots" do
    project_id = unique_id("project")

    results =
      1..101
      |> Task.async_stream(
        fn index -> start_run(project_id, "run-#{index}") end,
        max_concurrency: 101,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 100
    assert Enum.count(results, &(&1 == {:error, :run_limit_exceeded})) == 1

    {state, _version} = Aggregate.load(ProjectRunLimit, "project_run_limit:#{project_id}")
    assert MapSet.size(state.active_run_ids) == 100

    assert Enum.count(EventStore.stream("project_run_limit:#{project_id}"), fn event ->
             event.event_type == "RunLimitRejected"
           end) == 1
  end

  test "duplicate start keeps the existing slot reserved" do
    project_id = unique_id("project")
    run_id = unique_id("run")

    assert {:ok, _} = start_run(project_id, run_id)
    assert {:ok, _} = start_run(project_id, run_id)
    {state, _version} = Aggregate.load(ProjectRunLimit, "project_run_limit:#{project_id}")

    assert state.active_run_ids == MapSet.new([run_id])
    assert Enum.count(EventStore.stream("run:#{run_id}")) == 1
  end

  test "canonical start failure compensates a fresh reservation" do
    project_id = unique_id("project")
    run_id = unique_id("run")

    assert {:ok, _} =
             EventStore.append(%{
               stream_id: "run:#{run_id}",
               event_type: "RunStarted",
               payload: %{run_id: run_id, project_id: project_id},
               metadata: %{}
             })

    assert {:ok, _} = start_run(project_id, run_id)

    {state, _version} = Aggregate.load(ProjectRunLimit, "project_run_limit:#{project_id}")
    assert state.active_run_ids == MapSet.new([run_id])

    assert Enum.map(EventStore.stream("project_run_limit:#{project_id}"), & &1.event_type) == [
             "ProjectRunStarted"
           ]
  end

  test "missing project id resolves from the run projection" do
    project_id = unique_id("project")
    run_id = unique_id("run")

    assert {:ok, _} =
             EventStore.append(%{
               stream_id: "run:#{run_id}",
               event_type: "RunStarted",
               payload: %{run_id: run_id, project_id: project_id},
               metadata: %{}
             })

    assert ProjectionStore.run(run_id).project_id == project_id

    assert {:ok, _} =
             CommandRouter.handle(%{
               command_id: unique_id("command"),
               command_type: "run.start",
               payload: %{run_id: run_id}
             })

    {state, _version} = Aggregate.load(ProjectRunLimit, "project_run_limit:#{project_id}")
    assert state.active_run_ids == MapSet.new([run_id])
  end

  defp start_run(project_id, run_id) do
    CommandRouter.handle(%{
      command_id: unique_id("command"),
      command_type: "run.start",
      payload: %{
        project_id: project_id,
        run_id: run_id,
        phase_order: ["developer"],
        workflow: "default"
      }
    })
  end

  defp unique_id(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
