defmodule ForemanServer.PrMonitorTest.FakeChecker do
  def observe_pr(project_path, pr_url), do: observation(project_path, pr_url)
  def check_pr(project_path, pr_url), do: observation(project_path, pr_url)
  def check(project_path, pr_url), do: observation(project_path, pr_url)

  defp observation(project_path, pr_url) do
    send(test_pid(), {:checked_pr, project_path, pr_url})

    :foreman_server
    |> Application.fetch_env!(:pr_monitor_test_observations)
    |> Map.fetch!(pr_url)
  end

  defp test_pid do
    Application.fetch_env!(:foreman_server, :pr_monitor_test_pid)
  end
end

defmodule ForemanServer.PrMonitorTest.FakeCommandHandler do
  def handle(command), do: record(command)
  def handle_command(command), do: record(command)

  defp record(command) do
    send(
      Application.fetch_env!(:foreman_server, :pr_monitor_test_pid),
      {:handled_command, command}
    )

    {:ok, %{command: command}}
  end
end

defmodule ForemanServer.PrMonitorTest do
  use ExUnit.Case

  alias ForemanServer.{EventStore, ProjectionStore, PrMonitor}

  @checker ForemanServer.PrMonitorTest.FakeChecker
  @command_handler ForemanServer.PrMonitorTest.FakeCommandHandler
  @project_id "project-pr-monitor"
  @project_path "/tmp/foreman-pr-monitor-project"
  @task_id "task-pr-monitor"
  @run_id "run-pr-monitor"
  @pr_url "https://github.com/acme/foreman/pull/42"

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-pr-monitor-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    Application.put_env(:foreman_server, :pr_monitor_test_pid, self())
    Application.put_env(:foreman_server, :pr_monitor_test_observations, %{})

    Application.put_env(:foreman_server, :pr_monitor,
      enabled: false,
      checker: @checker,
      command_handler: @command_handler,
      interval_ms: 60_000
    )

    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      Application.delete_env(:foreman_server, :pr_monitor)
      Application.delete_env(:foreman_server, :pr_monitor_test_pid)
      Application.delete_env(:foreman_server, :pr_monitor_test_observations)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    :ok
  end

  test "merged recorded PR sends run.pr.merge before task.update merged" do
    seed_recorded_pr!(pr_state: "open")

    merged_at = "2026-07-09T12:34:56Z"

    put_observations(%{
      @pr_url =>
        {:ok,
         %{
           state: :merged,
           url: @pr_url,
           merged_at: merged_at,
           merge_commit_sha: "merge-sha",
           head_ref_oid: "head-sha",
           head_ref_name: "foreman/task-pr-monitor",
           base_ref_name: "main"
         }}
    })

    assert {:ok, _summary} = PrMonitor.tick_once()

    assert_receive {:checked_pr, @project_path, @pr_url}

    assert_receive {:handled_command,
                    %{
                      command_type: "run.pr.merge",
                      payload: merge_payload
                    }}

    assert merge_payload.run_id == @run_id
    assert merge_payload.project_id == @project_id
    assert merge_payload.task_id == @task_id
    assert merge_payload.pr_url == @pr_url
    assert merge_payload.branch_name == "foreman/task-pr-monitor"
    assert merge_payload.merged_at == merged_at
    assert merge_payload.merge_commit_sha == "merge-sha"

    assert_receive {:handled_command,
                    %{
                      command_type: "task.update",
                      payload: task_payload
                    }}

    assert task_payload.task_id == @task_id
    assert task_payload.status == "merged"
  end

  test "closed open and draft observations never mark the task merged" do
    observations =
      [:closed, :open, :draft]
      |> Enum.map(fn state ->
        run_id = "#{@run_id}-#{state}"
        task_id = "#{@task_id}-#{state}"
        pr_url = "#{@pr_url}-#{state}"

        seed_recorded_pr!(run_id: run_id, task_id: task_id, pr_url: pr_url, pr_state: "open")

        {pr_url,
         {:ok,
          %{
            state: state,
            url: pr_url,
            head_ref_oid: "head-sha-#{state}",
            head_ref_name: "foreman/#{task_id}",
            base_ref_name: "main"
          }}}
      end)
      |> Map.new()

    put_observations(observations)

    assert {:ok, _summary} = PrMonitor.tick_once()

    for pr_url <- Map.keys(observations) do
      assert_receive {:checked_pr, @project_path, ^pr_url}
    end

    commands = drain_handled_commands()

    refute Enum.any?(commands, fn
             %{command_type: "task.update", payload: %{status: "merged"}} -> true
             _command -> false
           end)
  end

  defp put_observations(observations) do
    Application.put_env(:foreman_server, :pr_monitor_test_observations, observations)
  end

  defp drain_handled_commands(commands \\ []) do
    receive do
      {:handled_command, command} -> drain_handled_commands([command | commands])
    after
      0 -> Enum.reverse(commands)
    end
  end

  defp seed_recorded_pr!(attrs) do
    run_id = Keyword.get(attrs, :run_id, @run_id)
    task_id = Keyword.get(attrs, :task_id, @task_id)
    pr_url = Keyword.get(attrs, :pr_url, @pr_url)
    pr_state = Keyword.fetch!(attrs, :pr_state)
    branch_name = "foreman/#{task_id}"

    append!("project:#{@project_id}", "ProjectRegistered", %{
      project_id: @project_id,
      path: @project_path,
      status: "active",
      default_branch: "main",
      config: %{},
      health: %{ok: true}
    })

    append!("task:#{task_id}", "TaskCreated", %{
      task_id: task_id,
      project_id: @project_id,
      title: task_id,
      status: "in_progress",
      run_id: run_id
    })

    append!("run:#{run_id}", "RunStarted", %{
      run_id: run_id,
      task_id: task_id,
      project_id: @project_id,
      status: "in_progress",
      base_branch: "main"
    })

    append!("run:#{run_id}", "PrUpdated", %{
      run_id: run_id,
      project_id: @project_id,
      task_id: task_id,
      pr_url: pr_url,
      pr_state: pr_state,
      branch_name: branch_name,
      head_sha: "head-sha",
      base_branch: "main",
      phase: "developer"
    })

    assert ProjectionStore.snapshot().runs[run_id].pr_url == pr_url
  end

  defp append!(stream_id, event_type, payload) do
    {:ok, event} =
      EventStore.append(%{
        stream_id: stream_id,
        event_type: event_type,
        payload: payload,
        metadata: %{}
      })

    event
  end
end
