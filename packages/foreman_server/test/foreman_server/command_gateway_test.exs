defmodule ForemanServer.CommandGatewayTestHelper do
  def reset_projection_store do
    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      %{
        projects: %{},
        runs: %{},
        tasks: %{},
        phases: %{},
        pr_associations: %{},
        scheduler_intents: %{},
        subscribers: Map.get(state, :subscribers, %{}),
        project_active_runs: %{}
      }
    end)
  end
end

defmodule ForemanServer.CommandGatewayTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, ProjectStore}

  describe "envelope validation" do
    test "rejects command without command_id" do
      assert {:error, {:invalid_envelope, :missing_command_id}} =
               CommandGateway.dispatch_operator(%{
                 aggregate_id: "task:abc",
                 type: "task.create",
                 payload: %{task_id: "abc"}
               })
    end

    test "rejects command without aggregate_id" do
      assert {:error, {:invalid_envelope, :missing_aggregate_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 type: "task.create",
                 payload: %{task_id: "abc"}
               })
    end

    test "rejects command without type" do
      assert {:error, {:invalid_envelope, :missing_type}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 payload: %{task_id: "abc"}
               })
    end

    test "rejects non-allowed operator type" do
      assert {:error, {:command_not_allowed, "task.delete"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 type: "task.delete",
                 payload: %{task_id: "abc"}
               })
    end
  end

  describe "aggregate_id contract" do
    test "project.register requires prefixed aggregate_id matching project_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "abc",
                 type: "project.register",
                 payload: %{project_id: "abc", path: "/tmp/p"}
               })
    end

    test "task.create requires task:<id> aggregate_id matching task_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:wrong",
                 type: "task.create",
                 payload: %{task_id: "abc", project_id: "p1"}
               })

      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "abc",
                 type: "task.create",
                 payload: %{task_id: "abc", project_id: "p1"}
               })
    end

    test "task.approve requires task:<id> aggregate_id matching task_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:wrong",
                 type: "task.approve",
                 payload: %{task_id: "abc", approved_by: "alice"}
               })
    end

    test "rejects numeric and non-binary entity IDs without crashing" do
      assert {:error, {:invalid_envelope, :missing_project_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "project:123",
                 type: "project.register",
                 payload: %{project_id: 123, path: "/tmp/p"}
               })

      assert {:error, {:invalid_envelope, :missing_task_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 type: "task.create",
                 payload: %{task_id: ["nested"], project_id: "p1"}
               })

      # aggregate_id itself must be a binary - non-binary aggregate_id is
      # caught at the envelope-shape layer (missing_aggregate_id).
      assert {:error, {:invalid_envelope, :missing_aggregate_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: :not_a_string,
                 type: "task.create",
                 payload: %{task_id: "abc", project_id: "p1"}
               })

      assert {:error, {:invalid_envelope, :missing_task_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 type: "task.approve",
                 payload: %{task_id: nil, approved_by: "alice"}
               })
    end
  end

  describe "project lifecycle validation" do
    test "project.register rejects missing project_id" do
      assert {:error, {:invalid_envelope, :missing_project_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "project:abc",
                 type: "project.register",
                 payload: %{path: "/tmp/p"}
               })
    end

    test "project.update rejects missing project_id" do
      assert {:error, {:invalid_envelope, :missing_project_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-update-1",
                 aggregate_id: "project:abc",
                 type: "project.update",
                 payload: %{path: "/tmp/p"}
               })
    end

    test "project.archive rejects missing project_id" do
      assert {:error, {:invalid_envelope, :missing_project_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-archive-1",
                 aggregate_id: "project:abc",
                 type: "project.archive",
                 payload: %{}
               })
    end
  end

  describe "task.create validation" do
    test "rejects missing project_id when task_id present" do
      assert {:error, {:invalid_envelope, :missing_project_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 type: "task.create",
                 payload: %{task_id: "abc"}
               })
    end
  end

  describe "run.cancel validation" do
    test "rejects missing run_id" do
      assert {:error, {:invalid_envelope, :missing_run_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "run:abc",
                 type: "run.cancel",
                 payload: %{}
               })
    end

    test "rejects empty run_id" do
      assert {:error, {:invalid_envelope, :missing_run_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "run:abc",
                 type: "run.cancel",
                 payload: %{run_id: ""}
               })
    end

    test "rejects non-binary run_id" do
      assert {:error, {:invalid_envelope, :missing_run_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "run:abc",
                 type: "run.cancel",
                 payload: %{run_id: 123}
               })
    end

    test "rejects mismatched aggregate_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "run:wrong",
                 type: "run.cancel",
                 payload: %{run_id: "abc"}
               })
    end

    test "rejects non-prefixed aggregate_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "abc",
                 type: "run.cancel",
                 payload: %{run_id: "abc"}
               })
    end

    test "accepts well-formed run.cancel and surfaces aggregate-layer error" do
      # No run exists for this id, so dispatch will fail at the aggregate
      # layer with {:error, {:run_not_found, _}} or similar. The test
      # confirms envelope validation succeeds and the failure is NOT an
      # envelope error.
      result =
        CommandGateway.dispatch_operator(%{
          command_id: "cid-1",
          aggregate_id: "run:run-no-such",
          type: "run.cancel",
          payload: %{run_id: "run-no-such", reason: "test"}
        })

      refute match?({:error, {:invalid_envelope, _}}, result)
      refute match?({:error, {:command_not_allowed, _}}, result)
    end
  end

  describe "task.approve validation" do
    test "rejects missing task_id" do
      assert {:error, {:invalid_envelope, :missing_task_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 type: "task.approve",
                 payload: %{}
               })
    end

    test "rejects mismatched aggregate_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:wrong",
                 type: "task.approve",
                 payload: %{task_id: "abc"}
               })
    end

    test "rejects nonexistent task when payload is well-formed" do
      assert {:error, {:task_not_found, "missing-task"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:missing-task",
                 type: "task.approve",
                 payload: %{task_id: "missing-task"}
               })
    end
  end

  describe "task.retry validation" do
    setup do
      ForemanServer.CommandGatewayTestHelper.reset_projection_store()

      on_exit(fn ->
        ForemanServer.CommandGatewayTestHelper.reset_projection_store()
      end)

      :ok
    end

    test "rejects missing task_id" do
      assert {:error, {:invalid_envelope, :missing_task_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 type: "task.retry",
                 payload: %{}
               })
    end

    test "rejects mismatched aggregate_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:wrong",
                 type: "task.retry",
                 payload: %{task_id: "abc"}
               })
    end

    test "rejects nonexistent task" do
      assert {:error, {:task_not_found, "missing-task"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:missing-task",
                 type: "task.retry",
                 payload: %{task_id: "missing-task"}
               })
    end

    test "rejects when task has no bound run" do
      assert :ok =
               ForemanServer.ProjectionStore.apply_events([
                 %{
                   event_type: "TaskCreated",
                   payload: %{
                     task_id: "task-orphan",
                     project_id: "project-x",
                     title: "orphan",
                     status: "open",
                     task_type: "plan"
                   }
                 }
               ])

      assert {:error, {:missing_or_invalid, :run_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:task-orphan",
                 type: "task.retry",
                 payload: %{task_id: "task-orphan"}
               })
    end

    test "rejects nonterminal bound run (active spoof)" do
      # Operator sends task.retry, but the bound run is still in_progress.
      # Gateway MUST refuse to enrich — a client cannot synthesize
      # acknowledgement by hand.
      assert :ok =
               ForemanServer.ProjectionStore.apply_events([
                 %{
                   event_type: "RunStarted",
                   payload: %{
                     run_id: "run-active",
                     task_id: "task-active",
                     project_id: "project-x",
                     workflow_snapshot: %{}
                   }
                 },
                 %{
                   event_type: "TaskCreated",
                   payload: %{
                     task_id: "task-active",
                     project_id: "project-x",
                     title: "active",
                     status: "in_progress",
                     task_type: "plan"
                   }
                 },
                 %{
                   event_type: "TaskApproved",
                   payload: %{
                     task_id: "task-active",
                     run_id: "run-active",
                     approval_id: "approval-active",
                     approved_by: "alice",
                     approved_at: "2026-08-10T00:00:00Z",
                     workflow_snapshot: %{}
                   }
                 },
                 %{
                   event_type: "TaskDispatched",
                   payload: %{
                     task_id: "task-active",
                     run_id: "run-active",
                     approval_id: "approval-active"
                   }
                 }
               ])

      assert {:error, {:run_not_terminal, "in_progress"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:task-active",
                 type: "task.retry",
                 payload: %{task_id: "task-active"}
               })
    end

    test "rejects when run projection is missing despite task binding" do
      # Task says run-bound, but the run projection never landed (or
      # has been deleted). Gateway MUST refuse rather than enrich
      # against a stale or absent run.
      # We simulate by registering the run, then wiping the run map.
      assert :ok =
               ForemanServer.ProjectionStore.apply_events([
                 %{
                   event_type: "RunStarted",
                   payload: %{
                     run_id: "run-ghost",
                     task_id: "task-ghost",
                     project_id: "project-x",
                     workflow_snapshot: %{}
                   }
                 },
                 %{
                   event_type: "TaskCreated",
                   payload: %{
                     task_id: "task-ghost",
                     project_id: "project-x",
                     title: "ghost",
                     status: "open",
                     task_type: "plan"
                   }
                 },
                 %{
                   event_type: "TaskApproved",
                   payload: %{
                     task_id: "task-ghost",
                     run_id: "run-ghost",
                     approval_id: "approval-ghost",
                     approved_by: "alice",
                     approved_at: "2026-08-10T00:00:00Z",
                     workflow_snapshot: %{}
                   }
                 }
               ])

      # Wipe the run projection but keep the task's run_id binding.
      :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
        %{state | runs: Map.delete(state.runs, "run-ghost")}
      end)

      assert {:error, {:run_not_found, "run-ghost"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:task-ghost",
                 type: "task.retry",
                 payload: %{task_id: "task-ghost"}
               })
    end

    test "rejects when run.task_id drifts from the task being retried" do
      assert :ok =
               ForemanServer.ProjectionStore.apply_events([
                 %{
                   event_type: "RunStarted",
                   payload: %{
                     run_id: "run-drift",
                     task_id: "task-other",
                     project_id: "project-x",
                     workflow_snapshot: %{}
                   }
                 },
                 %{
                   event_type: "RunFlaggedStuck",
                   payload: %{
                     run_id: "run-drift",
                     task_id: "task-other",
                     project_id: "project-x",
                     flagged_at: "2026-08-10T00:00:00Z"
                   }
                 },
                 %{
                   event_type: "TaskCreated",
                   payload: %{
                     task_id: "task-claimed",
                     project_id: "project-x",
                     title: "claimed",
                     status: "open",
                     task_type: "plan"
                   }
                 },
                 %{
                   event_type: "TaskApproved",
                   payload: %{
                     task_id: "task-claimed",
                     run_id: "run-drift",
                     approval_id: "approval-drift",
                     approved_by: "alice",
                     approved_at: "2026-08-10T00:00:00Z",
                     workflow_snapshot: %{}
                   }
                 }
               ])

      assert {:error, {:run_task_binding_drift, "run-drift", "task-other", "task-claimed"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:task-claimed",
                 type: "task.retry",
                 payload: %{task_id: "task-claimed"}
               })
    end
  end

  describe "dispatch_system" do
    test "bypasses operator whitelist (does not enforce allowed types)" do
      # dispatch_system routes through CommandRouter.dispatch/1 directly.
      # We send project.archive (NOT in the operator whitelist) against a
      # non-existent project. The test confirms dispatch_system does NOT
      # short-circuit with {:error, :command_not_allowed, _} - the
      # Aggregate handles the rejection itself with
      # {:error, :project_not_found}.
      result =
        CommandGateway.dispatch_system(%{
          command_id: "cid-1",
          aggregate_id: "project:does-not-exist",
          type: "project.archive",
          payload: %{project_id: "does-not-exist"}
        })

      assert match?({:error, _}, result)
      refute match?({:error, {:command_not_allowed, _}}, result)
    end
  end

  describe "project lifecycle telemetry" do
    test "dispatch_operator emits project.register telemetry" do
      project_id = unique_id("project")
      handler_id = attach_telemetry(self(), [[:foreman_server, :project, :register]])

      try do
        assert {:ok, _} =
                 CommandGateway.dispatch_operator(%{
                   command_id: unique_id("command"),
                   aggregate_id: "project:#{project_id}",
                   type: "project.register",
                   payload: %{project_id: project_id, path: "/tmp/#{project_id}"}
                 })

        assert_receive {
          :telemetry_event,
          [:foreman_server, :project, :register],
          %{duration_ms: duration_ms},
          %{project_id: ^project_id, outcome: :ok}
        }

        assert is_integer(duration_ms) and duration_ms >= 0
      after
        :telemetry.detach(handler_id)
      end
    end

    test "dispatch_operator emits project.update telemetry" do
      project_id = unique_id("project")

      assert {:ok, _} =
               ProjectStore.save(%{
                 project_id: project_id,
                 path: "/tmp/#{project_id}",
                 task_provider: %{provider: :beads}
               })

      handler_id = attach_telemetry(self(), [[:foreman_server, :project, :update]])

      try do
        assert {:ok, _} =
                 CommandGateway.dispatch_operator(%{
                   command_id: unique_id("command"),
                   aggregate_id: "project:#{project_id}",
                   type: "project.update",
                   payload: %{project_id: project_id, path: "/tmp/#{project_id}/updated"}
                 })

        assert_receive {
          :telemetry_event,
          [:foreman_server, :project, :update],
          %{duration_ms: duration_ms},
          %{project_id: ^project_id, outcome: :ok}
        }

        assert is_integer(duration_ms) and duration_ms >= 0
      after
        :telemetry.detach(handler_id)
      end
    end

    test "dispatch_operator emits project.archive telemetry with code and retryable on active-run conflict" do
      project_id = unique_id("project")
      run_id = unique_id("run")

      assert {:ok, _} =
               ProjectStore.save(%{
                 project_id: project_id,
                 path: "/tmp/#{project_id}",
                 task_provider: %{provider: :beads}
               })

      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 command_id: unique_id("reserve"),
                 aggregate_id: "project:#{project_id}",
                 type: "project.reserve_run",
                 payload: %{
                   project_id: project_id,
                   run_id: run_id,
                   command_id: unique_id("run-start"),
                   sequence: 1,
                   run_start_payload: %{
                     project_id: project_id,
                     run_id: run_id,
                     task_id: unique_id("task"),
                     workflow_snapshot: %{}
                   }
                 }
               })

      handler_id = attach_telemetry(self(), [[:foreman_server, :project, :archive]])

      try do
        assert {:error, :project_has_active_runs, [^run_id]} =
                 CommandGateway.dispatch_operator(%{
                   command_id: unique_id("command"),
                   aggregate_id: "project:#{project_id}",
                   type: "project.archive",
                   payload: %{project_id: project_id}
                 })

        assert_receive {
          :telemetry_event,
          [:foreman_server, :project, :archive],
          %{duration_ms: duration_ms},
          %{
            project_id: ^project_id,
            outcome: :error,
            code: "project_has_active_runs",
            retryable: false
          }
        }

        assert is_integer(duration_ms) and duration_ms >= 0
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  defp attach_telemetry(test_pid, events) do
    handler_id = "command-gateway-telemetry-#{unique_id("handler")}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    handler_id
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end
end
