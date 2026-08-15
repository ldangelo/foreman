defmodule ForemanServer.ProjectionStoreWorkTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore

  setup do
    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      %{
        state
        | projects: %{},
          tasks: %{},
          runs: %{},
          phases: %{},
          project_active_runs: %{},
          worktrees: %{},
          worktree_create_orphans: %{},
          scheduler_intents: %{},
          run_slots: %{capacity: 0, holders: %{}, waiters: []}
      }
      |> Map.put(:works, %{})
    end)

    on_exit(fn ->
      :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
        %{
          state
          | projects: %{},
            tasks: %{},
            runs: %{},
            phases: %{},
            project_active_runs: %{},
            worktrees: %{},
            worktree_create_orphans: %{},
            scheduler_intents: %{},
            run_slots: %{capacity: 0, holders: %{}, waiters: []}
        }
        |> Map.put(:works, %{})
      end)
    end)

    :ok
  end

  describe "WorkSubmitted" do
    test "populates all fields on work projection" do
      work_id = "work-1"
      project_id = "proj-1"
      run_id = "run-1"
      submission_id = "sub-1"

      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "WorkSubmitted",
                   payload: %{
                     work_id: work_id,
                     project_id: project_id,
                     run_id: run_id,
                     submission_id: submission_id,
                     workflow_snapshot: %{"phases" => []}
                   }
                 }
               ])

      assert %{
               work_id: ^work_id,
               status: :submitted,
               project_id: ^project_id,
               run_id: ^run_id,
               submission_id: ^submission_id,
               queue_position: nil
             } = ProjectionStore.work_projection(work_id)
    end
  end

  describe "WorkCancelled" do
    test "sets status to :cancelled" do
      work_id = "work-1"

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "WorkSubmitted",
            payload: %{
              work_id: work_id,
              project_id: "proj-1",
              run_id: "run-1",
              submission_id: "sub-1",
              workflow_snapshot: %{}
            }
          },
          %{
            event_type: "WorkCancelled",
            payload: %{work_id: work_id}
          }
        ])

      assert %{status: :cancelled} = ProjectionStore.work_projection(work_id)
    end
  end

  describe "WorkExecutionCompleted" do
    test "sets status to :succeeded" do
      work_id = "work-1"

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "WorkSubmitted",
            payload: %{
              work_id: work_id,
              project_id: "proj-1",
              run_id: "run-1",
              submission_id: "sub-1",
              workflow_snapshot: %{}
            }
          },
          %{
            event_type: "WorkExecutionCompleted",
            payload: %{work_id: work_id, run_id: "run-1"}
          }
        ])

      assert %{status: :succeeded} = ProjectionStore.work_projection(work_id)
    end
  end

  describe "WorkExecutionFailed" do
    test "sets status to :failed" do
      work_id = "work-1"

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "WorkSubmitted",
            payload: %{
              work_id: work_id,
              project_id: "proj-1",
              run_id: "run-1",
              submission_id: "sub-1",
              workflow_snapshot: %{}
            }
          },
          %{
            event_type: "WorkExecutionFailed",
            payload: %{work_id: work_id, run_id: "run-1"}
          }
        ])

      assert %{status: :failed} = ProjectionStore.work_projection(work_id)
    end
  end

  describe "work_projection/1" do
    test "returns nil when work not found" do
      assert nil == ProjectionStore.work_projection("nonexistent")
    end

    test "returns correct projection for known work_id" do
      work_id = "work-1"

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "WorkSubmitted",
            payload: %{
              work_id: work_id,
              project_id: "proj-1",
              run_id: "run-1",
              submission_id: "sub-1",
              workflow_snapshot: %{}
            }
          }
        ])

      assert %{work_id: "work-1", status: :submitted} = ProjectionStore.work_projection(work_id)
    end
  end

  describe "list_work/0" do
    test "returns all work projections" do
      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "WorkSubmitted",
            payload: %{
              work_id: "work-1",
              project_id: "proj-1",
              run_id: "run-1",
              submission_id: "sub-1",
              workflow_snapshot: %{}
            }
          },
          %{
            event_type: "WorkSubmitted",
            payload: %{
              work_id: "work-2",
              project_id: "proj-1",
              run_id: "run-2",
              submission_id: "sub-2",
              workflow_snapshot: %{}
            }
          }
        ])

      works = ProjectionStore.list_work()
      assert length(works) == 2
      assert Enum.map(works, & &1.work_id) |> Enum.sort() == ["work-1", "work-2"]
    end

    test "returns empty list when no works" do
      assert [] == ProjectionStore.list_work()
    end
  end

  describe "queue_position/1" do
    test "returns position when work is in queue (run_id in waiters)" do
      work_id = "work-1"
      run_id = "run-1"

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "WorkSubmitted",
            payload: %{
              work_id: work_id,
              project_id: "proj-1",
              run_id: run_id,
              submission_id: "sub-1",
              workflow_snapshot: %{}
            }
          },
          %{
            event_type: "RunSlotQueued",
            payload: %{
              run_id: run_id,
              position: 1,
              enqueued_at_ms: 1_000_000
            }
          }
        ])

      assert {:ok, 1} = ProjectionStore.queue_position(work_id)
    end

    test "returns correct position when work is second in queue" do
      work_id_1 = "work-1"
      work_id_2 = "work-2"
      run_id_1 = "run-1"
      run_id_2 = "run-2"

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "WorkSubmitted",
            payload: %{
              work_id: work_id_1,
              project_id: "proj-1",
              run_id: run_id_1,
              submission_id: "sub-1",
              workflow_snapshot: %{}
            }
          },
          %{
            event_type: "WorkSubmitted",
            payload: %{
              work_id: work_id_2,
              project_id: "proj-1",
              run_id: run_id_2,
              submission_id: "sub-2",
              workflow_snapshot: %{}
            }
          },
          %{
            event_type: "RunSlotQueued",
            payload: %{run_id: run_id_1, position: 1, enqueued_at_ms: 1_000_000}
          },
          %{
            event_type: "RunSlotQueued",
            payload: %{run_id: run_id_2, position: 2, enqueued_at_ms: 1_000_001}
          }
        ])

      assert {:ok, 1} = ProjectionStore.queue_position(work_id_1)
      assert {:ok, 2} = ProjectionStore.queue_position(work_id_2)
    end

    test "returns error when work is not in queue (not in waiters)" do
      work_id = "work-1"

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "WorkSubmitted",
            payload: %{
              work_id: work_id,
              project_id: "proj-1",
              run_id: "run-1",
              submission_id: "sub-1",
              workflow_snapshot: %{}
            }
          },
          %{
            event_type: "RunSlotAcquired",
            payload: %{run_id: "run-1", capacity: 2, acquired_at_ms: 1_000_000}
          }
        ])

      assert {:error, :not_in_queue} = ProjectionStore.queue_position(work_id)
    end

    test "returns error when work does not exist" do
      assert {:error, :not_in_queue} = ProjectionStore.queue_position("nonexistent")
    end
  end
end
