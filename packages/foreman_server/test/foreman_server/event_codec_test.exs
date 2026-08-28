defmodule ForemanServer.EventCodecTest do
  use ExUnit.Case, async: true

  alias ForemanServer.EventCodec

  alias ForemanServer.Events.{
    ProjectRunReservationReleased,
    ProjectRunReserved,
    RunBlocked,
    RunCancelled,
    RunCompleted,
    RunFailed,
    RunFlaggedStuck,
    RunPaused,
    WorkerHeartbeat,
    WorkerStarted,
    WorkerUnresponsive,
    WorkerExited,
    WorktreeCreated,
    WorktreeCleaned
  }

  describe "decode!/2 pass-through" do
    test "returns struct as-is when __struct__ matches the registered module" do
      struct = %WorkerHeartbeat{worker_id: "w1", run_id: "r1", sequence: 7}
      assert EventCodec.decode!("WorkerHeartbeat", struct) == struct
    end
  end

  describe "decode!/2 mismatch" do
    test "raises ArgumentError when input has a different struct" do
      wrong = %WorkerStarted{
        worker_id: "w1",
        run_id: "r1",
        session_id: "s1",
        adapter: "Ad",
        prompt_path: "/p"
      }

      assert_raise ArgumentError, ~r/EventCodec mismatch/, fn ->
        EventCodec.decode!("WorkerHeartbeat", wrong)
      end
    end
  end

  describe "decode!/2 plain map" do
    test "builds struct from atom-keyed map and preserves declared defaults" do
      result =
        EventCodec.decode!("WorkerHeartbeat", %{
          worker_id: "w1",
          run_id: "r1",
          sequence: 7
        })

      assert %WorkerHeartbeat{worker_id: "w1", run_id: "r1", sequence: 7, timestamp: nil} = result
    end

    test "builds struct from string-keyed map" do
      result =
        EventCodec.decode!("WorkerHeartbeat", %{
          "worker_id" => "w1",
          "run_id" => "r1",
          "sequence" => 7
        })

      assert result == %WorkerHeartbeat{worker_id: "w1", run_id: "r1", sequence: 7}
    end

    test "rejects duplicate atom/string forms of the same field" do
      assert_raise ArgumentError, ~r/both atom and string/, fn ->
        EventCodec.decode!("WorkerHeartbeat", %{
          "worker_id" => "w1",
          worker_id: "w-other"
        })
      end
    end

    test "rejects unknown keys" do
      assert_raise ArgumentError, ~r/unknown fields/, fn ->
        EventCodec.decode!("WorkerHeartbeat", %{
          worker_id: "w1",
          run_id: "r1",
          bogus_field: "x"
        })
      end
    end

    test "raises on missing enforced keys" do
      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("WorkerHeartbeat", %{run_id: "r1"})
      end
    end

    test "allows optional fields to be absent (defaults preserved)" do
      result = EventCodec.decode!("WorkerExited", %{worker_id: "w1"})
      assert %WorkerExited{worker_id: "w1", run_id: nil} = result
    end
    end
  describe "decode!/2 TaskCreated replay safety" do
    test "a historical TaskCreated with neither new field decodes tracker-backed" do
      result =
        EventCodec.decode!("TaskCreated", %{
          "task_id" => "t1",
          "project_id" => "p",
          "title" => "t",
          "status" => "open",
          "task_type" => "task"
        })

      assert %ForemanServer.Events.TaskCreated{
               task_id: "t1",
               provider_tracked: true,
               prompt: nil
             } = result
    end
  end

  describe "decode!/2 terminal run events" do
    test "builds typed terminal events and preserves project_id" do
      assert EventCodec.decode!("RunCompleted", %{run_id: "r1", project_id: "p1", sequence: 7}) ==
               %RunCompleted{run_id: "r1", project_id: "p1", sequence: 7}

      assert EventCodec.decode!("RunFailed", %{
               "run_id" => "r1",
               "project_id" => "p1",
               "sequence" => 8,
               "reason" => "worker_crashed"
             }) ==
               %RunFailed{
                 run_id: "r1",
                 project_id: "p1",
                 sequence: 8,
                 reason: "worker_crashed"
               }

      assert EventCodec.decode!("RunCancelled", %{
               run_id: "r1",
               project_id: "p1",
               reason: "operator_abort",
               sequence: 9
             }) ==
               %RunCancelled{
                 run_id: "r1",
                 project_id: "p1",
                 reason: "operator_abort",
                 sequence: 9
               }

      assert EventCodec.decode!("RunBlocked", %{
               run_id: "r1",
               project_id: "p1",
               reason: "awaiting_review",
               status: "blocked"
             }) ==
               %RunBlocked{
                 run_id: "r1",
                 project_id: "p1",
                 reason: "awaiting_review",
                 status: "blocked"
               }

      assert EventCodec.decode!("RunFlaggedStuck", %{
               run_id: "r1",
               project_id: "p1",
               flagged_at: 1_234
             }) ==
               %RunFlaggedStuck{run_id: "r1", project_id: "p1", flagged_at: 1_234}
    end

    test "rejects terminal run events that omit project_id" do
      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("RunCompleted", %{run_id: "r1", sequence: 1})
      end

      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("RunFailed", %{run_id: "r1", sequence: 1})
      end

      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("RunCancelled", %{run_id: "r1", reason: "operator_abort"})
      end

      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("RunBlocked", %{run_id: "r1", reason: "awaiting_review"})
      end

      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("RunFlaggedStuck", %{run_id: "r1", flagged_at: 1_234})
      end
    end

    test "RunCancelled round-trips the operator-supplied status field" do
      # `run.cancel` injects `status: "cancelled"` into the persisted
      # payload. The typed struct declares that field so replay decoding
      # accepts it; apply_event hardcodes "cancelled" on the in-memory
      # state but the event itself preserves the operator intent.
      assert EventCodec.decode!("RunCancelled", %{
               run_id: "r1",
               project_id: "p1",
               reason: "operator_abort",
               status: "cancelled",
               sequence: 9
             }) ==
               %RunCancelled{
                 run_id: "r1",
                 project_id: "p1",
                 reason: "operator_abort",
                 status: "cancelled",
                 sequence: 9
               }
    end
  end

  describe "decode!/2 paused run events" do
    test "builds typed paused events and preserves defaults" do
      assert EventCodec.decode!("RunPaused", %{
               run_id: "r1",
               sequence: 10,
               reason: "operator_intervention"
             }) ==
               %RunPaused{
                 run_id: "r1",
                 sequence: 10,
                 reason: "operator_intervention",
                 metadata: %{}
               }
    end

    test "rejects paused events that omit run_id" do
      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("RunPaused", %{reason: "operator_intervention"})
      end
    end
  end

  describe "decode!/2 project run reservation events" do
    test "builds typed reservation events and preserves retry payloads" do
      assert EventCodec.decode!("ProjectRunReserved", %{
               project_id: "p1",
               run_id: "r1",
               sequence: 1,
               command_id: "cmd-1",
               run_start_payload: %{task_id: "t1", workflow_snapshot: %{phases: []}}
             }) ==
               %ProjectRunReserved{
                 project_id: "p1",
                 run_id: "r1",
                 sequence: 1,
                 command_id: "cmd-1",
                 run_start_payload: %{task_id: "t1", workflow_snapshot: %{phases: []}}
               }

      assert EventCodec.decode!("ProjectRunReservationReleased", %{
               "project_id" => "p1",
               "run_id" => "r1",
               "sequence" => 2,
               "reason" => "terminal_event"
             }) ==
               %ProjectRunReservationReleased{
                 project_id: "p1",
                 run_id: "r1",
                 sequence: 2,
                 reason: "terminal_event"
               }
    end

    test "rejects reservation events that omit enforced keys" do
      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("ProjectRunReserved", %{
          project_id: "p1",
          run_id: "r1",
          sequence: 1,
          command_id: "cmd-1"
        })
      end

      assert_raise ArgumentError, ~r/missing enforced keys/, fn ->
        EventCodec.decode!("ProjectRunReservationReleased", %{project_id: "p1", run_id: "r1"})
      end
    end
  end

  describe "decode!/2 unregistered event_type" do
    test "raises ArgumentError when event_type is not registered" do
      assert_raise ArgumentError, ~r/unregistered event_type/, fn ->
        EventCodec.decode!("NotAType", %{worker_id: "w1", run_id: "r1"})
      end
    end
  end

  describe "decode!/2 argument validation" do
    test "raises when event_type is not a binary" do
      assert_raise ArgumentError, ~r/expects \(binary, map\)/, fn ->
        EventCodec.decode!(:not_a_string, %{worker_id: "w1"})
      end
    end
  end

  describe "decode_recorded!/1" do
    test "decodes a RecordedEvent-shaped map" do
      recorded = %{event_type: "WorkerUnresponsive", data: %{worker_id: "w1", run_id: "r1"}}

      assert EventCodec.decode_recorded!(recorded) ==
               %WorkerUnresponsive{worker_id: "w1", run_id: "r1"}
    end
  end

  describe "registered/0" do
    test "lists every registered event type" do
      assert "WorkerStarted" in EventCodec.registered()
      assert "WorkerHeartbeat" in EventCodec.registered()
      assert "WorkerUnresponsive" in EventCodec.registered()
      assert "WorkerExited" in EventCodec.registered()
      assert "ProjectRunReserved" in EventCodec.registered()
      assert "ProjectRunReservationReleased" in EventCodec.registered()
      assert "RunCompleted" in EventCodec.registered()
      assert "RunFailed" in EventCodec.registered()
      assert "RunCancelled" in EventCodec.registered()
      assert "RunBlocked" in EventCodec.registered()
      assert "RunFlaggedStuck" in EventCodec.registered()
      assert "RunPaused" in EventCodec.registered()
      assert "WorktreeCreated" in EventCodec.registered()
      assert "WorktreeCleaned" in EventCodec.registered()
    end
  end

  describe "WorktreeCreated/WorktreeCleaned round-trip" do
    test "decodes WorktreeCreated from an atom-keyed map" do
      data = %{
        operation_id: "wt-1",
        project_id: "proj-1",
        run_id: "run-1",
        phase_id: "phase-1",
        worktree_path: "/tmp/wt",
        branch: "foreman/run-1/phase-1",
        base_ref: "deadbeef",
        cleanup: "always"
      }

      assert %WorktreeCreated{} = decoded = EventCodec.decode!("WorktreeCreated", data)
      assert decoded.operation_id == "wt-1"
      assert decoded.project_id == "proj-1"
      assert decoded.run_id == "run-1"
      assert decoded.phase_id == "phase-1"
      assert decoded.worktree_path == "/tmp/wt"
      assert decoded.branch == "foreman/run-1/phase-1"
      assert decoded.base_ref == "deadbeef"
      assert decoded.cleanup == "always"
    end

    test "decodes WorktreeCleaned from an atom-keyed map" do
      data = %{
        operation_id: "wt-1",
        project_id: "proj-1",
        run_id: "run-1",
        phase_id: "phase-1",
        worktree_path: "/tmp/wt",
        cleanup_observed: "removed"
      }

      assert %WorktreeCleaned{} = decoded = EventCodec.decode!("WorktreeCleaned", data)
      assert decoded.operation_id == "wt-1"
      assert decoded.project_id == "proj-1"
      assert decoded.run_id == "run-1"
      assert decoded.phase_id == "phase-1"
      assert decoded.worktree_path == "/tmp/wt"
      assert decoded.cleanup_observed == "removed"
    end

    test "WorktreeCreated enforces correlation tuple on decode" do
      assert_raise ArgumentError, ~r/missing enforced keys.*:operation_id/, fn ->
        EventCodec.decode!("WorktreeCreated", %{project_id: "p", run_id: "r", phase_id: "ph"})
      end
    end

    test "WorktreeCleaned enforces correlation tuple on decode" do
      assert_raise ArgumentError, ~r/missing enforced keys.*:operation_id/, fn ->
        EventCodec.decode!("WorktreeCleaned", %{project_id: "p", run_id: "r", phase_id: "ph"})
      end
    end

    test "decode_recorded!/1 rebuilds WorktreeCreated from a RecordedEvent-shaped map" do
      recorded = %{
        event_type: "WorktreeCreated",
        data: %{
          operation_id: "wt-1",
          project_id: "proj-1",
          run_id: "run-1",
          phase_id: "phase-1",
          worktree_path: "/tmp/wt"
        }
      }

      assert %WorktreeCreated{} = decoded = EventCodec.decode_recorded!(recorded)
      assert decoded.operation_id == "wt-1"
      assert decoded.worktree_path == "/tmp/wt"
    end
  end

  describe "registry derivation" do
    # The registry and the enforced-key lookup are derived from
    # lib/foreman_server/events/ at compile time. These tests pin that
    # contract: two hand-maintained maps previously drifted, leaving 15 of 66
    # event structs unregistered and undecodable.

    @events_dir Path.expand("../../lib/foreman_server/events", __DIR__)

    test "every event struct on disk is registered" do
      on_disk =
        @events_dir
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.map(&File.read!/1)
        |> Enum.filter(&String.contains?(&1, "defstruct"))
        |> Enum.flat_map(fn body ->
          ~r/defmodule\s+ForemanServer\.Events\.([A-Za-z0-9_]+)\s+do/
          |> Regex.scan(body)
          |> Enum.map(fn [_, short] -> short end)
        end)
        |> MapSet.new()

      registered = MapSet.new(EventCodec.registered())

      assert MapSet.difference(on_disk, registered) |> MapSet.to_list() == [],
             "event structs exist on disk but are not registered"

      assert MapSet.difference(registered, on_disk) |> MapSet.to_list() == [],
             "registered event types have no struct on disk"
    end

    test "every registered event type resolves to a loadable struct module" do
      broken =
        EventCodec.registered()
        |> Enum.reject(fn type ->
          module = Module.concat(ForemanServer.Events, type)
          Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0)
        end)

      assert broken == [], "registered types with no loadable struct: #{inspect(broken)}"
    end

    test "enforced keys are derived per module, not shared or empty" do
      # RunCompleted enforces :project_id; a derivation bug that returned []
      # for every module would silently accept an incomplete event.
      assert_raise ArgumentError,
                   ~r/missing enforced keys: \[:project_id\]/,
                   fn -> EventCodec.decode!("RunCompleted", %{"run_id" => "r", "sequence" => 1}) end
    end

    test "previously-unregistered event types now decode" do
      # These 15 had structs but no registry entry.
      assert %ForemanServer.Events.ProjectArchived{project_id: "p1"} =
               EventCodec.decode!("ProjectArchived", %{"project_id" => "p1"})

      for type <- ~w(ProjectRegistered ProjectUpdated PrAssociated MergeGatePending
                     MergeGateApproved RunAlreadyCompleted RunRecoveryEvent
                     ScheduledFireRecorded ScheduledFireConfirmed ScheduledFireSkipped
                     SchedulerIntentStale VcsOperationStarted VcsOperationCompleted
                     VcsOperationFailed) do
        assert type in EventCodec.registered(), "#{type} must be registered"
      end
    end
  end
end
