defmodule ForemanServer.Aggregates.ProjectTest do
  use ExUnit.Case, async: true

  alias ForemanServer.{Aggregate, TaskProviders.BeadsAdapter}
  alias ForemanServer.Aggregates.Project
  alias ForemanServer.Aggregates.Project.State
  alias ForemanServer.Events.{ProjectRegistered, ProjectUpdated}

  describe "initial_state/0" do
    test "returns a non-existent state with no task provider" do
      state = Project.initial_state()

      assert state.exists? == false
      assert state.project_id == nil
      assert state.task_provider == nil
      assert state.config == %{}
    end
  end

  describe "handle_command/2 — project.register" do
    test "emits ProjectRegistered with task_provider mirrored into config and normalized database path" do
      raw_database_path = "/tmp/./beads/../beads.db"

      task_provider = %{
        "provider" => BeadsAdapter,
        "config" => %{"database_path" => raw_database_path}
      }

      assert {:ok, event_spec} =
               Project.handle_command(Project.initial_state(), %{
                 type: "project.register",
                 payload: %{
                   project_id: "project-1",
                   path: "/tmp/project-1",
                   task_provider: task_provider
                 }
               })

      assert event_spec.event_type == "ProjectRegistered"
      assert event_spec.payload.project_id == "project-1"
      assert event_spec.payload.path == "/tmp/project-1"

      assert task_provider_database_path(event_spec.payload.task_provider) ==
               Path.expand(raw_database_path)

      assert task_provider_database_path(event_spec.payload.config.task_provider) ==
               Path.expand(raw_database_path)
    end

    test "rejects a relative task_provider database path before emitting an event" do
      assert {:error, :database_path_must_be_absolute} =
               Project.handle_command(Project.initial_state(), %{
                 type: "project.register",
                 payload: %{
                   project_id: "project-1",
                   path: "/tmp/project-1",
                   task_provider: %{
                     provider: BeadsAdapter,
                     config: %{"database_path" => "relative/path.db"}
                   }
                 }
               })
    end

    test "project.register accepts task_provider config block" do
      task_provider = %{provider: :beads, config: %{database_path: "/abs/path.db"}}

      assert {:ok, event_spec} =
               Project.handle_command(Project.initial_state(), %{
                 type: "project.register",
                 payload: %{
                   project_id: "x",
                   path: "/tmp/x",
                   task_provider: task_provider
                 }
               })

      assert event_spec.payload.task_provider == task_provider
      assert event_spec.payload.config.task_provider == task_provider
    end

    test "AC-009-5 command-time path validation in the aggregate" do
      raw_database_path = "/tmp/./providers/../beads.db"

      assert {:ok, event_spec} =
               Project.handle_command(Project.initial_state(), %{
                 type: "project.register",
                 payload: %{
                   project_id: "project-1",
                   path: "/tmp/project-1",
                   task_provider: %{
                     provider: :beads,
                     config: %{database_path: raw_database_path}
                   }
                 }
               })

      assert task_provider_database_path(event_spec.payload.task_provider) ==
               Path.expand(raw_database_path)

      assert task_provider_database_path(event_spec.payload.config.task_provider) ==
               Path.expand(raw_database_path)
    end
  end

  describe "handle_command/2 — project.update" do
    test "normalizes an accepted absolute database path in the emitted event payload" do
      raw_database_path = "/tmp/./next/../beads.db"
      task_provider = %{provider: BeadsAdapter, config: %{"database_path" => raw_database_path}}

      state = %State{
        Project.initial_state()
        | exists?: true,
          project_id: "project-1",
          path: "/tmp/project-1",
          status: "active",
          default_branch: "main",
          archived?: false
      }

      assert {:ok, event_spec} =
               Project.handle_command(state, %{
                 type: "project.update",
                 payload: %{
                   project_id: "project-1",
                   task_provider: task_provider
                 }
               })

      assert event_spec.event_type == "ProjectUpdated"

      assert task_provider_database_path(event_spec.payload.task_provider) ==
               Path.expand(raw_database_path)
    end

    test "rejects a non-absolute task_provider database path before emitting an event" do
      state = %State{
        Project.initial_state()
        | exists?: true,
          project_id: "project-1",
          path: "/tmp/project-1",
          status: "active",
          default_branch: "main",
          archived?: false
      }

      assert {:error, :database_path_must_be_absolute} =
               Project.handle_command(state, %{
                 type: "project.update",
                 payload: %{
                   project_id: "project-1",
                   task_provider: %{
                     provider: BeadsAdapter,
                     config: %{"database_path" => "~/beads.db"}
                   }
                 }
               })
    end

    test "project.update atomically replaces the task_provider block" do
      original_task_provider = %{
        provider: :beads,
        config: %{database_path: "/tmp/original.db", pool_size: 4}
      }

      assert {:ok, register_event} =
               Project.handle_command(Project.initial_state(), %{
                 type: "project.register",
                 payload: %{
                   project_id: "project-1",
                   path: "/tmp/project-1",
                   task_provider: original_task_provider
                 }
               })

      registered = Project.apply_event(Project.initial_state(), register_event)

      replacement_task_provider = %{
        provider: :beads,
        config: %{database_path: "/tmp/replacement.db"}
      }

      assert {:ok, update_event} =
               Project.handle_command(registered, %{
                 type: "project.update",
                 payload: %{
                   project_id: "project-1",
                   task_provider: replacement_task_provider
                 }
               })

      updated = Project.apply_event(registered, update_event)

      assert updated.task_provider == replacement_task_provider
      assert updated.config.task_provider == replacement_task_provider
      refute Map.has_key?(updated.task_provider.config, :pool_size)
    end

    test "project.update preserves other config when task_provider is absent" do
      task_provider = %{provider: :beads, config: %{database_path: "/tmp/current.db"}}

      assert {:ok, register_event} =
               Project.handle_command(Project.initial_state(), %{
                 type: "project.register",
                 payload: %{
                   project_id: "project-1",
                   path: "/tmp/project-1",
                   config: %{env: %{"ALPHA" => "1"}, retries: 3},
                   task_provider: task_provider
                 }
               })

      registered = Project.apply_event(Project.initial_state(), register_event)

      assert {:ok, update_event} =
               Project.handle_command(registered, %{
                 type: "project.update",
                 payload: %{
                   project_id: "project-1",
                   default_branch: "trunk"
                 }
               })

      updated = Project.apply_event(registered, update_event)

      assert updated.default_branch == "trunk"
      assert updated.task_provider == task_provider

      assert updated.config == %{
               env: %{"ALPHA" => "1"},
               retries: 3,
               task_provider: task_provider
             }
    end
  end

  describe "apply_event/2 — ProjectRegistered" do
    test "hydrates task_provider into state and config" do
      task_provider = %{provider: BeadsAdapter, config: %{"database_path" => "/tmp/beads.db"}}

      state =
        Project.apply_event(Project.initial_state(), %{
          event_type: "ProjectRegistered",
          payload: %{
            project_id: "project-1",
            path: "/tmp/project-1",
            task_provider: task_provider
          }
        })

      assert state.task_provider == task_provider
      assert state.config == %{task_provider: task_provider}
    end

    test "apply_event for ProjectRegistered sets state.config[:task_provider]" do
      task_provider = %{provider: :beads, config: %{database_path: "/tmp/beads.db"}}

      state =
        Project.apply_event(Project.initial_state(), %{
          event_type: "ProjectRegistered",
          payload: %ProjectRegistered{
            project_id: "project-1",
            path: "/tmp/project-1",
            task_provider: task_provider
          }
        })

      assert state.task_provider == task_provider
      assert state.config[:task_provider] == task_provider
    end
  end

  describe "apply_event/2 — ProjectUpdated" do
    test "atomically replaces task_provider while preserving sibling config" do
      original_task_provider = %{
        provider: BeadsAdapter,
        config: %{"database_path" => "/tmp/old.db"}
      }

      new_task_provider = %{provider: BeadsAdapter, config: %{"database_path" => "/tmp/new.db"}}

      state = %State{
        Project.initial_state()
        | exists?: true,
          project_id: "project-1",
          path: "/tmp/project-1",
          status: "active",
          default_branch: "main",
          archived?: false,
          task_provider: original_task_provider,
          config: %{env: %{"ALPHA" => "1"}, task_provider: original_task_provider},
          health: %{ok: true}
      }

      updated =
        Project.apply_event(state, %{
          event_type: "ProjectUpdated",
          payload: %{
            project_id: "project-1",
            config: %{env: %{"BETA" => "2"}},
            task_provider: new_task_provider
          }
        })

      assert updated.task_provider == new_task_provider

      assert updated.config == %{
               env: %{"BETA" => "2"},
               task_provider: new_task_provider
             }
    end

    test "preserves existing task_provider when update omits it" do
      task_provider = %{provider: BeadsAdapter, config: %{"database_path" => "/tmp/current.db"}}

      state = %State{
        Project.initial_state()
        | exists?: true,
          project_id: "project-1",
          path: "/tmp/project-1",
          status: "active",
          default_branch: "main",
          archived?: false,
          task_provider: task_provider,
          config: %{env: %{"ALPHA" => "1"}, task_provider: task_provider},
          health: %{ok: true}
      }

      updated =
        Project.apply_event(state, %{
          event_type: "ProjectUpdated",
          payload: %{
            project_id: "project-1",
            config: %{env: %{"BETA" => "2"}}
          }
        })

      assert updated.task_provider == task_provider

      assert updated.config == %{
               env: %{"BETA" => "2"},
               task_provider: task_provider
             }
    end

    test "apply_event for ProjectUpdated updates state.config[:task_provider]" do
      original_task_provider = %{provider: :beads, config: %{database_path: "/tmp/old.db"}}
      replacement_task_provider = %{provider: :beads, config: %{database_path: "/tmp/new.db"}}

      state = %State{
        Project.initial_state()
        | exists?: true,
          project_id: "project-1",
          path: "/tmp/project-1",
          status: "active",
          default_branch: "main",
          archived?: false,
          task_provider: original_task_provider,
          config: %{env: %{"ALPHA" => "1"}, task_provider: original_task_provider}
      }

      updated =
        Project.apply_event(state, %{
          event_type: "ProjectUpdated",
          payload: %ProjectUpdated{
            project_id: "project-1",
            task_provider: replacement_task_provider
          }
        })

      assert updated.task_provider == replacement_task_provider
      assert updated.config[:task_provider] == replacement_task_provider
      assert updated.config[:env] == %{"ALPHA" => "1"}
    end
  end

  describe "typed events" do
    test "Jason encodes task_provider on project event structs" do
      task_provider = %{provider: BeadsAdapter, config: %{"database_path" => "/tmp/beads.db"}}

      registered_json =
        Jason.encode!(%ProjectRegistered{
          project_id: "project-1",
          path: "/tmp/project-1",
          task_provider: task_provider
        })

      updated_json =
        Jason.encode!(%ProjectUpdated{project_id: "project-1", task_provider: task_provider})

      assert registered_json =~ "\"task_provider\""
      assert updated_json =~ "\"task_provider\""
    end
  end

  defp task_provider_database_path(task_provider) do
    task_provider
    |> Aggregate.get(:config, %{})
    |> Aggregate.get(:database_path)
  end
end
