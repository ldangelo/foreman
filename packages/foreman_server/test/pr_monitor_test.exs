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

defmodule ForemanServer.PrMonitor.GhWebhookHandlerTest do
  use ExUnit.Case

  alias ForemanServer.{EventStore, ProjectionStore, PrMonitor}

  @project_id "proj-webhook-test"
  @project_path "/tmp/foreman-webhook-test-project"
  @task_id "task-webhook-test"
  @run_id "run-webhook-test"
  @pr_url "https://github.com/acme/foreman/pull/99"

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-webhook-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    Application.put_env(:foreman_server, :pr_monitor_test_pid, self())

    Application.put_env(
      :foreman_server,
      :command_handler,
      ForemanServer.PrMonitorTest.FakeCommandHandler
    )

    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      Application.delete_env(:foreman_server, :pr_monitor_test_pid)
      Application.delete_env(:foreman_server, :command_handler)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    :ok
  end

  defp seed_pr_run!(attrs \\ []) do
    pr_url = Keyword.get(attrs, :pr_url, @pr_url)
    pr_state = Keyword.get(attrs, :pr_state, "open")
    branch_name = Keyword.get(attrs, :branch_name, "foreman/task-webhook-test")

    append!("project:#{@project_id}", "ProjectRegistered", %{
      project_id: @project_id,
      path: @project_path,
      status: "active",
      default_branch: "main",
      config: %{},
      health: %{ok: true}
    })

    append!("task:#{@task_id}", "TaskCreated", %{
      task_id: @task_id,
      project_id: @project_id,
      title: @task_id,
      status: "in_progress",
      run_id: @run_id
    })

    append!("run:#{@run_id}", "RunStarted", %{
      run_id: @run_id,
      task_id: @task_id,
      project_id: @project_id,
      status: "in_progress",
      base_branch: "main"
    })

    append!("run:#{@run_id}", "PrUpdated", %{
      run_id: @run_id,
      project_id: @project_id,
      task_id: @task_id,
      pr_url: pr_url,
      pr_state: pr_state,
      branch_name: branch_name,
      head_sha: "head-sha-webhook",
      base_branch: "main",
      phase: "developer"
    })

    :ok
  end

  describe "handle/1" do
    test "merged pull_request event emits run.pr.merge and task.update merged" do
      :ok = seed_pr_run!()

      payload = %{
        "action" => "closed",
        "delivery_id" => "delivery-merged-#{:rand.uniform(999_999)}",
        "repository" => %{"full_name" => "acme/foreman"},
        "pull_request" => %{
          "html_url" => @pr_url,
          "state" => "closed",
          "merged" => true,
          "merged_at" => "2026-07-22T10:00:00Z",
          "merge_commit_sha" => "merge-sha-webhook",
          "head" => %{"ref" => "foreman/task-webhook-test", "sha" => "head-sha-webhook"},
          "base" => %{"ref" => "main"}
        }
      }

      assert {:ok, %{commands_issued: 2}} = PrMonitor.GhWebhookHandler.handle(payload)

      commands = drain_commands()

      assert Enum.any?(commands, fn c ->
               c.command_type == "run.pr.merge"
             end)

      assert Enum.any?(commands, fn c ->
               c.command_type == "task.update" and c.payload[:status] == "merged"
             end)
    end

    test "closed pull_request (not merged) emits run.pr.reset and task.close" do
      :ok = seed_pr_run!(pr_state: "open")

      payload = %{
        "action" => "closed",
        "delivery_id" => "delivery-closed-#{:rand.uniform(999_999)}",
        "pull_request" => %{
          "html_url" => @pr_url,
          "state" => "closed",
          "merged" => false,
          "head" => %{"ref" => "foreman/task-webhook-test", "sha" => "head-sha-webhook"},
          "base" => %{"ref" => "main"}
        }
      }

      assert {:ok, %{commands_issued: 2}} = PrMonitor.GhWebhookHandler.handle(payload)

      commands = drain_commands()

      assert Enum.any?(commands, fn c ->
               c.command_type == "run.pr.reset" and c.payload[:action] == "closed"
             end)

      assert Enum.any?(commands, fn c ->
               c.command_type == "task.close"
             end)
    end

    test "duplicate delivery returns error without emitting commands" do
      :ok = seed_pr_run!()
      delivery_id = "delivery-duplicate-#{:rand.uniform(999_999)}"

      payload = %{
        "action" => "closed",
        "delivery_id" => delivery_id,
        "pull_request" => %{
          "html_url" => @pr_url,
          "state" => "closed",
          "merged" => true,
          "merged_at" => "2026-07-22T10:00:00Z",
          "merge_commit_sha" => "merge-sha-dup",
          "head" => %{"ref" => "foreman/task-webhook-test", "sha" => "head-sha-webhook"},
          "base" => %{"ref" => "main"}
        }
      }

      assert {:ok, %{commands_issued: 2}} = PrMonitor.GhWebhookHandler.handle(payload)

      commands_after_first = drain_commands()
      assert length(commands_after_first) == 2

      # Same delivery_id should be deduped
      assert {:error, :duplicate} = PrMonitor.GhWebhookHandler.handle(payload)

      # No new commands should have been emitted
      refute_receive {:handled_command, _}, 100
    end

    test "no matching run returns error gracefully" do
      payload = %{
        "action" => "closed",
        "delivery_id" => "delivery-no-run-#{:rand.uniform(999_999)}",
        "pull_request" => %{
          "html_url" => "https://github.com/acme/foreman/pull/99999",
          "state" => "closed",
          "merged" => true,
          "merged_at" => "2026-07-22T10:00:00Z",
          "head" => %{"ref" => "nonexistent/branch", "sha" => "abc"},
          "base" => %{"ref" => "main"}
        }
      }

      assert {:error, :no_matching_run} = PrMonitor.GhWebhookHandler.handle(payload)
    end

    test "draft pull_request event updates pr state to draft" do
      :ok = seed_pr_run!(pr_state: "open")

      payload = %{
        "action" => "converted_to_draft",
        "delivery_id" => "delivery-draft-#{:rand.uniform(999_999)}",
        "pull_request" => %{
          "html_url" => @pr_url,
          "state" => "open",
          "merged" => false,
          "draft" => true,
          "head" => %{"ref" => "foreman/task-webhook-test", "sha" => "head-sha-webhook"},
          "base" => %{"ref" => "main"}
        }
      }

      assert {:ok, %{commands_issued: 1}} = PrMonitor.GhWebhookHandler.handle(payload)

      commands = drain_commands()

      assert Enum.any?(commands, fn c ->
               c.command_type == "run.pr.update" and c.payload[:pr_state] == "draft"
             end)
    end

    test "open pull_request event updates pr state to ready" do
      :ok = seed_pr_run!(pr_state: "draft")

      payload = %{
        "action" => "ready_for_review",
        "delivery_id" => "delivery-open-#{:rand.uniform(999_999)}",
        "pull_request" => %{
          "html_url" => @pr_url,
          "state" => "open",
          "merged" => false,
          "draft" => false,
          "head" => %{"ref" => "foreman/task-webhook-test", "sha" => "head-sha-webhook"},
          "base" => %{"ref" => "main"}
        }
      }

      assert {:ok, %{commands_issued: 1}} = PrMonitor.GhWebhookHandler.handle(payload)

      commands = drain_commands()
      assert Enum.any?(commands, fn c -> c.command_type == "run.pr.ready" end)
    end
  end

  describe "verify_signature/3" do
    @secret "test-webhook-secret"

    test "valid HMAC-SHA256 signature returns true" do
      body = ~s({"action":"closed","pull_request":{"merged":true}})
      signature = PrMonitor.GhWebhookHandler.build_signature(body, @secret)
      assert PrMonitor.GhWebhookHandler.verify_signature(body, signature, @secret)
    end

    test "invalid HMAC-SHA256 signature returns false" do
      body = ~s({"action":"closed","pull_request":{"merged":true}})
      bad_signature = "sha256=0000000000000000000000000000000000000000000000000000000000000000"
      refute PrMonitor.GhWebhookHandler.verify_signature(body, bad_signature, @secret)
    end

    test "tampered body fails verification" do
      body = ~s({"action":"closed","pull_request":{"merged":true}})
      signature = PrMonitor.GhWebhookHandler.build_signature(body, @secret)
      tampered = ~s({"action":"closed","pull_request":{"merged":false}})
      refute PrMonitor.GhWebhookHandler.verify_signature(tampered, signature, @secret)
    end
  end

  defp drain_commands(commands \\ []) do
    receive do
      {:handled_command, command} -> drain_commands([command | commands])
    after
      50 -> Enum.reverse(commands)
    end
  end

  defp append!(stream_id, event_type, payload) do
    {:ok, _event} =
      EventStore.append(%{
        stream_id: stream_id,
        event_type: event_type,
        payload: payload,
        metadata: %{}
      })
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

  test "terminal task with stale open PR state is reconciled when PR is merged" do
    # Previously this was a skip (per the old `terminal_task_status?`
    # guard). The new behavior: skip only when BOTH `terminal_task_status?`
    # AND `pr_state == "merged"`. If the task is terminal but `pr_state`
    # disagrees (e.g. an old poll mis-recorded the PR as `open`),
    # re-observe is a one-way repair path that emits `run.pr.merge`
    # + `task.update merged`. This is the user-reported bug case.
    seed_recorded_pr!(pr_state: "open", task_status: "closed")

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

    assert {:ok, %{merged: 1, errors: 0}} = PrMonitor.tick_once()
    assert_receive {:checked_pr, @project_path, @pr_url}

    assert_receive {:handled_command,
                    %{
                      command_type: "run.pr.merge",
                      payload: merge_payload
                    }}

    assert_receive {:handled_command,
                    %{
                      command_type: "task.update",
                      payload: task_payload
                    }}

    assert merge_payload.pr_url == @pr_url
    assert merge_payload.merged_at == merged_at
    assert task_payload.task_id == @task_id
    assert task_payload.status == "merged"
  end

  test "REST-shaped CLOSED + merged_at observation is normalized to :merged and reconciled" do
    # GitHub's REST API reports merged PRs as `state: "CLOSED"` with
    # `merged_at` set. The polling normalizer (`normalize_state/3`) must
    # distinguish merged-but-CLOSED from closed-without-merge by checking
    # `merged_at`. The previous normalizer discarded `merged_at` and
    # always emitted `PrReset` for these — which is what made the user's
    # landed PRs surface as `blocked` on the board.
    #
    # Use `pr_state: "open"` so the run passes the tick filter; the
    # bug we're guarding against is the normalizer mis-classifying a
    # REST-shaped merged observation. `task_status: "closed"` exercises
    # the reconciliation path through `handle_observation`.
    seed_recorded_pr!(pr_state: "open", task_status: "closed")

    put_observations(%{
      @pr_url =>
        {:ok,
         %{
           state: "CLOSED",
           url: @pr_url,
           merged_at: "2026-07-22T10:00:00Z",
           merge_commit_sha: "merge-sha-rest",
           head_ref_oid: "head-sha-rest",
           head_ref_name: "foreman/task-pr-monitor",
           base_ref_name: "main"
         }}
    })

    assert {:ok, %{merged: 1, errors: 0}} = PrMonitor.tick_once()
    assert_receive {:checked_pr, @project_path, @pr_url}

    assert_receive {:handled_command,
                    %{
                      command_type: "run.pr.merge",
                      payload: merge_payload
                    }}

    assert_receive {:handled_command,
                    %{
                      command_type: "task.update",
                      payload: task_payload
                    }}

    # No reset must be emitted — the normalizer's `merged` classification
    # means the run is reconciled, not reset.
    refute_receive {:handled_command, %{command_type: "run.pr.reset"}}

    assert merge_payload.merged_at == "2026-07-22T10:00:00Z"
    assert merge_payload.merge_commit_sha == "merge-sha-rest"
    assert task_payload.status == "merged"
  end

  test "REST-shaped CLOSED + nil merged_at observation is normalized to :closed" do
    # Companion case: a PR that was actually closed without merge.
    # `state: "CLOSED"`, `merged_at: nil` → `:closed` → emits reset.
    seed_recorded_pr!(pr_state: "open")

    put_observations(%{
      @pr_url =>
        {:ok,
         %{
           state: "CLOSED",
           url: @pr_url,
           merged_at: nil,
           merge_commit_sha: nil,
           head_ref_oid: "head-sha",
           head_ref_name: "foreman/task-pr-monitor",
           base_ref_name: "main"
         }}
    })

    assert {:ok, %{closed: 1, errors: 0}} = PrMonitor.tick_once()
    assert_receive {:checked_pr, @project_path, @pr_url}

    assert_receive {:handled_command,
                    %{
                      command_type: "run.pr.reset",
                      payload: reset_payload
                    }}

    refute_receive {:handled_command, %{command_type: "run.pr.merge"}}
    assert reset_payload.action == "closed"
  end

  test "locally-merged run is preserved against a later closed observation" do
    # One-way merge preservation: once `pr_state == "merged"` is
    # recorded locally, a later `:closed` observation must NOT
    # downgrade it. GitHub merges are irreversible, and a task can
    # have multiple PRs (re-targets, follow-up attempts).
    #
    # `tick_once` filters terminal pr_state runs entirely, so call
    # `handle_observation/3` directly with a hand-built context.
    context = %{
      run_id: @run_id,
      task_id: @task_id,
      task_status: "merged",
      project_id: @project_id,
      project_path: @project_path,
      pr_url: @pr_url,
      pr_state: "merged",
      branch_name: "foreman/#{@task_id}",
      phase: "pr-monitor"
    }

    observation = %{
      state: :closed,
      url: @pr_url,
      merged_at: nil,
      head_ref_oid: "head-sha",
      head_ref_name: "foreman/#{@task_id}",
      base_ref_name: "main"
    }

    summary = PrMonitor.handle_observation(context, observation, @command_handler)

    assert summary.skipped == 1
    assert summary.closed == 0
    assert summary.errors == 0
    refute_receive {:handled_command, _command}
  end

  test "terminal task with stale open PR state is skipped when PR is closed" do
    seed_recorded_pr!(pr_state: "open", task_status: "closed")

    put_observations(%{
      @pr_url =>
        {:ok,
         %{
           state: :closed,
           url: @pr_url,
           head_ref_oid: "head-sha",
           head_ref_name: "foreman/task-pr-monitor",
           base_ref_name: "main"
         }}
    })

    assert {:ok, %{skipped: 1, closed: 0, errors: 0}} = PrMonitor.tick_once()
    assert_receive {:checked_pr, @project_path, @pr_url}
    refute_receive {:handled_command, _command}
  end

  test "closed recorded PR records run reset then closes task" do
    seed_recorded_pr!(pr_state: "open")

    put_observations(%{
      @pr_url =>
        {:ok,
         %{
           state: :closed,
           url: @pr_url,
           head_ref_oid: "head-sha",
           head_ref_name: "foreman/task-pr-monitor",
           base_ref_name: "main"
         }}
    })

    assert {:ok, %{closed: 1, errors: 0}} = PrMonitor.tick_once()

    assert_receive {:checked_pr, @project_path, @pr_url}
    assert_receive {:handled_command,
                    %{
                      command_type: "run.pr.reset",
                      payload: reset_payload
                    }}

    assert reset_payload.run_id == @run_id
    assert reset_payload.project_id == @project_id
    assert reset_payload.task_id == @task_id
    assert reset_payload.pr_url == @pr_url
    assert reset_payload.action == "closed"
    assert reset_payload.reason == "GitHub reports PR closed without merge"

    assert_receive {:handled_command,
                    %{
                      command_type: "task.close",
                      payload: close_payload
                    }}

    assert close_payload.project_id == @project_id
    assert close_payload.task_id == @task_id
  end

  test "reconcile_terminal_prs re-observes runs with terminal pr_state" do
    # Bug-recovery entry point: a run whose `pr_state` was
    # mis-recorded (e.g. merged PR recorded as closed by the old
    # normalizer) gets re-observed. The normalizer now classifies
    # the merged observation correctly, and the :merged handler
    # emits `run.pr.merge` + `task.update merged`. `tick_once`
    # filters terminal pr_state runs out entirely, so this is the
    # only path that repairs existing bad rows.
    seed_recorded_pr!(pr_state: "open", task_status: "closed")

    # Flip pr_state to closed so the bad-row state is simulated and
    # the tick filter would now skip this run.
    append!("run:#{@run_id}", "PrReset", %{
      run_id: @run_id,
      task_id: @task_id,
      project_id: @project_id,
      pr_url: @pr_url,
      action: "closed",
      reason: "simulate bad row"
    })

    assert ProjectionStore.snapshot().runs[@run_id].pr_state == "closed"

    put_observations(%{
      @pr_url =>
        {:ok,
         %{
           state: "CLOSED",
           url: @pr_url,
           merged_at: "2026-07-22T10:00:00Z",
           merge_commit_sha: "merge-sha-reconcile",
           head_ref_oid: "head-sha",
           head_ref_name: "foreman/task-pr-monitor",
           base_ref_name: "main"
         }}
    })

    assert {:ok, %{merged: 1, errors: 0}} = PrMonitor.reconcile_terminal_prs()
    assert_receive {:checked_pr, @project_path, @pr_url}

    assert_receive {:handled_command,
                    %{command_type: "run.pr.merge", payload: merge_payload}}

    assert_receive {:handled_command,
                    %{command_type: "task.update", payload: task_payload}}

    assert merge_payload.merged_at == "2026-07-22T10:00:00Z"
    assert task_payload.status == "merged"
  end

  test "reconcile_terminal_prs skips already-merged runs (scope is closed only)" do
    # The scope is intentionally narrow: only `pr_state == "closed"`
    # runs are re-observed. Already-merged runs are skipped to avoid
    # accidental downgrade via follow-up/reused branches. This test
    # pins that contract.
    seed_recorded_pr!(pr_state: "merged", task_status: "merged")

    assert {:ok, %{checked: 0, merged: 0, errors: 0}} = PrMonitor.reconcile_terminal_prs()
    refute_receive {:checked_pr, _, _}
    refute_receive {:handled_command, _command}
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
      status: Keyword.get(attrs, :task_status, "in_progress"),
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
