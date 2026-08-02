defmodule ForemanServer.PrLifecycleTest.FakeChecker do
  def observe_pr(project_path, pr_url), do: observation(project_path, pr_url)
  def check_pr(project_path, pr_url), do: observation(project_path, pr_url)
  def check(project_path, pr_url), do: observation(project_path, pr_url)

  defp observation(project_path, pr_url) do
    send(test_pid(), {:checked_pr, project_path, pr_url})

    Application.fetch_env!(:foreman_server, :pr_lifecycle_test_observations)
    |> Map.fetch!(pr_url)
  end

  defp test_pid do
    Application.fetch_env!(:foreman_server, :pr_lifecycle_test_pid)
  end
end

defmodule ForemanServer.PrLifecycleTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{
    AggregateRouter,
    CommandRouter,
    EventStore,
    PrAssociate,
    PrGate,
    PrMonitor,
    ProjectionStore
  }

  alias ForemanServer.Webhooks.Github

  @checker ForemanServer.PrLifecycleTest.FakeChecker
  @project_id "project-pr-lifecycle"
  @project_path "/tmp/foreman-pr-lifecycle-project"

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-pr-lifecycle-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    Application.put_env(:foreman_server, :pr_lifecycle_test_pid, self())
    Application.put_env(:foreman_server, :pr_lifecycle_test_observations, %{})
    Application.put_env(:foreman_server, :command_handler, PrMonitor.CommandHandler)

    Application.put_env(:foreman_server, :pr_monitor,
      enabled: false,
      checker: @checker,
      command_handler: PrMonitor.CommandHandler
    )

    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      Application.delete_env(:foreman_server, :pr_lifecycle_test_pid)
      Application.delete_env(:foreman_server, :pr_lifecycle_test_observations)
      Application.delete_env(:foreman_server, :command_handler)
      Application.delete_env(:foreman_server, :pr_monitor)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    :ok
  end

  test "PrAssociated event appended on PR URL provided" do
    run_id = "run-pr-associated"
    task_id = "task-pr-associated"
    pr_url = "https://github.com/acme/foreman/pull/42"

    assert {:ok, _} =
             CommandRouter.handle(%{
               command_id: "seed:#{run_id}:start",
               command_type: "run.start",
               payload: %{run_id: run_id, task_id: task_id, project_id: "proj-#{run_id}"}
             })

    assert {:ok, _} =
             CommandRouter.handle(%{
               command_id: "seed:#{run_id}:complete",
               command_type: "run.complete",
               payload: %{run_id: run_id}
             })

    assert {:ok, association_id} = PrAssociate.store(run_id, pr_url)
    assert association_id == "#{run_id}:#{pr_url}"

    assert Enum.any?(EventStore.stream("run:#{run_id}"), fn event ->
             event.event_type == "PrAssociated"
           end)

    assert %{pr_url: ^pr_url, pr_number: "42"} = ProjectionStore.snapshot().runs[run_id]
  end

  test "GitHub webhook emits PrUpdated and updates the run projection" do
    run_id = "run-webhook-pr-updated"
    task_id = "task-webhook-pr-updated"
    pr_url = "https://github.com/acme/foreman/pull/99"
    branch_name = "foreman/#{task_id}"

    seed_recorded_pr!(
      run_id: run_id,
      task_id: task_id,
      pr_url: pr_url,
      pr_state: "open",
      branch_name: branch_name
    )

    payload = %{
      "action" => "converted_to_draft",
      "delivery_id" => "delivery-pr-updated",
      "pull_request" => %{
        "html_url" => pr_url,
        "state" => "open",
        "merged" => false,
        "draft" => true,
        "head" => %{"ref" => branch_name, "sha" => "head-sha-webhook"},
        "base" => %{"ref" => "main"}
      }
    }

    assert {:ok, %{commands_issued: 1}} = Github.process(payload)

    run_events = EventStore.stream("run:#{run_id}")

    assert Enum.any?(run_events, fn event ->
             event.event_type == "PrUpdated" and event.payload.pr_state == "draft"
           end)
    assert ProjectionStore.snapshot().runs[run_id].pr_state == "draft"
  end

  test "polling fallback reconciles PR state every 5 minutes" do
    run_id = "run-poll-pr-state"
    task_id = "task-poll-pr-state"
    pr_url = "https://github.com/acme/foreman/pull/123"
    branch_name = "foreman/#{task_id}"

    seed_recorded_pr!(
      run_id: run_id,
      task_id: task_id,
      pr_url: pr_url,
      pr_state: "draft",
      branch_name: branch_name
    )

    put_observations(%{
      pr_url =>
        {:ok,
         %{
           state: "OPEN",
           url: pr_url,
           head_ref_oid: "head-sha-poll",
           head_ref_name: branch_name,
           base_ref_name: "main"
         }}
    })

    assert PrMonitor.state().interval_ms == 300_000
    assert {:ok, %{updated: 1, errors: 0}} = PrMonitor.poll()
    assert_receive {:checked_pr, @project_path, ^pr_url}

    assert Enum.any?(EventStore.stream("run:#{run_id}"), fn event ->
             event.event_type == "PrReady"
           end)

    assert ProjectionStore.snapshot().runs[run_id].pr_state == "open"
  end
  test "scheduled tick fires and reconciles PR state via GenServer handle_info" do
    run_id = "run-scheduled-tick"
    task_id = "task-scheduled-tick"
    pr_url = "https://github.com/acme/foreman/pull/888"
    branch_name = "foreman/#{task_id}"

    seed_recorded_pr!(
      run_id: run_id,
      task_id: task_id,
      pr_url: pr_url,
      pr_state: "draft",
      branch_name: branch_name
    )

    put_observations(%{
      pr_url =>
        {:ok,
         %{
           state: "OPEN",
           url: pr_url,
           head_ref_oid: "head-sha-tick",
           head_ref_name: branch_name,
           base_ref_name: "main"
         }}
    })

    # Reconfigure env with short interval and enabled=true, then restart only
    # the PrMonitor child so it picks up the new config and schedules a tick,
    # leaving ProjectionStore / EventStore seeded data intact.
    :ok = Supervisor.terminate_child(ForemanServer.Supervisor, PrMonitor)
    Application.put_env(:foreman_server, :pr_monitor,
      enabled: true,
      interval_ms: 50,
      checker: @checker,
      command_handler: PrMonitor.CommandHandler
    )
    {:ok, _} = Supervisor.restart_child(ForemanServer.Supervisor, PrMonitor)
    # Wait for scheduled tick to fire (interval_ms == 50)
    assert_receive {:checked_pr, @project_path, ^pr_url}, 200
    # Mailbox barrier: drain all in-flight dispatches before inspecting EventStore
    :sys.get_state(PrMonitor)

    assert Enum.any?(EventStore.stream("run:#{run_id}"), fn event ->
             event.event_type == "PrReady"
           end)

    assert ProjectionStore.snapshot().runs[run_id].pr_state == "open"
  end

  test "PR not open or merged returns {:error, :pr_not_acceptable} from PrGate.check/1" do
    seed_run_with_pr_state!("run-pr-draft", "PrUpdated", %{
      project_id: "project-draft",
      task_id: "task-draft",
      pr_url: "https://github.com/acme/foreman/pull/201",
      branch_name: "foreman/task-draft",
      head_sha: "head-draft",
      base_branch: "main",
      phase: "developer",
      pr_state: "draft"
    })

    assert {:error, :pr_not_acceptable} = PrGate.check("run-pr-draft")

    seed_run_with_pr_state!("run-pr-closed", "PrReset", %{
      project_id: "project-closed",
      task_id: "task-closed",
      pr_url: "https://github.com/acme/foreman/pull/202",
      branch_name: "foreman/task-closed",
      action: "closed",
      reason: "closed by author"
    })

    assert {:error, :pr_not_acceptable} = PrGate.check("run-pr-closed")

    seed_run_with_pr_state!("run-pr-conflicted", "PrUpdated", %{
      project_id: "project-conflicted",
      task_id: "task-conflicted",
      pr_url: "https://github.com/acme/foreman/pull/203",
      branch_name: "foreman/task-conflicted",
      head_sha: "head-conflicted",
      base_branch: "main",
      phase: "developer",
      pr_state: "conflicted"
    })

    assert {:error, :pr_not_acceptable} = PrGate.check("run-pr-conflicted")
    assert {:error, :pr_not_acceptable} = PrGate.check("run-pr-missing")
  end

  test "PrGate blocks run from transitioning to merge-pending" do
    seed_merge_pending_run!("run-merge-pending-draft", "draft")

    assert {:error, :pr_not_acceptable} =
             AggregateRouter.route("run.update", %{
               run_id: "run-merge-pending-draft",
               current_phase: "merge-pending"
             })

    seed_merge_pending_run!("run-merge-pending-open", "open")

    assert {:ok, %{event_type: "RunUpdated", payload: payload}} =
             AggregateRouter.route("run.update", %{
               run_id: "run-merge-pending-open",
               current_phase: "merge-pending"
             })

    assert payload.current_phase == "merge-pending"
  end

  defp put_observations(observations) do
    Application.put_env(:foreman_server, :pr_lifecycle_test_observations, observations)
  end

  defp seed_recorded_pr!(attrs) do
    run_id = Keyword.fetch!(attrs, :run_id)
    task_id = Keyword.fetch!(attrs, :task_id)
    pr_url = Keyword.fetch!(attrs, :pr_url)
    pr_state = Keyword.fetch!(attrs, :pr_state)
    branch_name = Keyword.fetch!(attrs, :branch_name)
    task_status = Keyword.get(attrs, :task_status, "in_progress")

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
      status: task_status,
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

  defp seed_run_with_pr_state!(run_id, event_type, payload) do
    append!("run:#{run_id}", "RunStarted", %{
      run_id: run_id,
      task_id: Map.fetch!(payload, :task_id),
      project_id: Map.fetch!(payload, :project_id),
      status: "in_progress",
      base_branch: "main"
    })

    append!("run:#{run_id}", event_type, Map.put(payload, :run_id, run_id))
    assert ProjectionStore.snapshot().runs[run_id].run_id == run_id
  end

  defp seed_merge_pending_run!(run_id, pr_state) do
    assert {:ok, start_spec} =
             AggregateRouter.route("run.start", %{run_id: run_id, task_id: "task-#{run_id}"})

    assert {:ok, _event} = EventStore.append(start_spec)

    payload =
      case pr_state do
        "open" ->
          %{
            run_id: run_id,
            project_id: "project-1",
            task_id: "task-1",
            pr_url: "https://github.com/acme/foreman/pull/#{run_id}",
            branch_name: "foreman/task-1",
            head_sha: "head-#{run_id}",
            base_branch: "main"
          }

        "merged" ->
          %{
            run_id: run_id,
            project_id: "project-1",
            task_id: "task-1",
            pr_url: "https://github.com/acme/foreman/pull/#{run_id}",
            branch_name: "foreman/task-1"
          }

        other ->
          %{
            run_id: run_id,
            project_id: "project-1",
            task_id: "task-1",
            pr_url: "https://github.com/acme/foreman/pull/#{run_id}",
            branch_name: "foreman/task-1",
            head_sha: "head-#{run_id}",
            base_branch: "main",
            phase: "developer",
            pr_state: other
          }
      end

    {command_type, expected_state} =
      case pr_state do
        "open" -> {"run.pr.ready", "open"}
        "merged" -> {"run.pr.merge", "merged"}
        "closed" -> {"run.pr.reset", "closed"}
        other -> {"run.pr.update", other}
      end

    payload =
      case command_type do
        "run.pr.reset" -> Map.merge(payload, %{action: "closed", reason: "closed by test"})
        _ -> payload
      end

    assert {:ok, spec} = AggregateRouter.route(command_type, payload)
    assert {:ok, _event} = EventStore.append(spec)
    assert ProjectionStore.snapshot().runs[run_id].pr_state == expected_state
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
