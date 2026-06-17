defmodule ForemanServer.MigrationImporterTest do
  use ExUnit.Case
  import Plug.Test

  alias ForemanServer.{CommandRouter, EventStore, MigrationImporter, ProjectionStore}

  @router_opts ForemanServer.Http.Router.init([])

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-migration-importer-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    previous_auth_token = Application.get_env(:foreman_server, :auth_token, :__unset__)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)

      if previous_auth_token == :__unset__ do
        Application.delete_env(:foreman_server, :auth_token)
      else
        Application.put_env(:foreman_server, :auth_token, previous_auth_token)
      end

      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "imports legacy projects tasks runs workflows inbox and config into projections" do
    assert {:ok, %{status: "completed", imported: imported}} =
             MigrationImporter.import(legacy_payload())

    assert imported == %{
             projects: 1,
             tasks: 1,
             runs: 1,
             workflows: 1,
             inbox_messages: 1,
             config: 1
           }

    event_types = EventStore.all() |> Enum.map(& &1.event_type)
    assert "MigrationImportStarted" in event_types
    assert "ProjectRegistered" in event_types
    assert "TaskCreated" in event_types
    assert "RunStarted" in event_types
    assert "RunCompleted" in event_types
    assert "InboxMessageAppended" in event_types
    assert "MigrationRecordImported" in event_types
    assert "MigrationImportCompleted" in event_types

    projection = ProjectionStore.snapshot()
    assert projection.projects["legacy-project"].path == "/repo/legacy"
    assert projection.tasks["legacy-task"].title == "Legacy task"
    assert projection.tasks["legacy-task"].source == "legacy-ts"
    assert projection.runs["legacy-run"].status == "completed"
    assert projection.runs["legacy-run"].task_id == "legacy-task"
    assert projection.inbox_messages["legacy-message"].body == "done"
    assert projection.migration_imports["migration-1"].status == "completed"
    assert projection.migration_records["migration-1:workflow:default"].data.name == "default"
    assert projection.migration_records["migration-1:config:config"].data["runtime"] == "ts"
  end

  test "migration imports rebuild from event store with historical runs still readable" do
    assert {:ok, _result} = MigrationImporter.import(legacy_payload())
    assert {:ok, rebuilt} = EventStore.rebuild_projections()

    assert rebuilt.runs["legacy-run"].status == "completed"
    assert rebuilt.tasks["legacy-task"].status == "closed"
    assert rebuilt.migration_imports["migration-1"].summary.runs == 1
    assert rebuilt.status_counts.completed == 1
  end

  test "invalid input fails before side effects" do
    before_count = EventStore.all() |> length()

    assert {:error, {:missing_or_invalid, :source}} =
             MigrationImporter.import(%{migration_id: "bad", projects: "not-list"})

    assert EventStore.all() |> length() == before_count
  end

  test "command router and HTTP command boundary route migration imports" do
    assert {:ok, %{migration: %{status: "completed"}}} =
             CommandRouter.handle(%{
               command_id: "migration-cmd-1",
               command_type: "migration.import",
               payload: legacy_payload("migration-cmd-1")
             })

    http_payload = legacy_payload("migration-http-1")

    conn =
      conn(:post, "/api/v1/commands", %{
        "command_id" => "migration-http-1",
        "command_type" => "MigrationImportCommand",
        "payload" => stringify(http_payload),
        "metadata" => %{"correlation_id" => "migration-http-1"}
      })
      |> ForemanServer.Http.Router.call(@router_opts)

    assert conn.status == 202
    assert %{"ok" => true, "events" => [_event_id]} = Jason.decode!(conn.resp_body)
    assert ProjectionStore.snapshot().migration_imports["migration-http-1"].status == "completed"
  end

  defp legacy_payload(migration_id \\ "migration-1") do
    %{
      migration_id: migration_id,
      source: "legacy-ts-store",
      projects: [
        %{
          project_id: "legacy-project",
          path: "/repo/legacy",
          default_branch: "main",
          config: %{"runtime" => "ts"}
        }
      ],
      tasks: [
        %{
          task_id: "legacy-task",
          project_id: "legacy-project",
          title: "Legacy task",
          status: "closed",
          dependencies: [],
          source: "legacy-ts"
        }
      ],
      runs: [
        %{
          run_id: "legacy-run",
          task_id: "legacy-task",
          status: "completed",
          phase_order: ["implement"],
          current_phase: "implement"
        }
      ],
      workflows: [%{name: "default", data: %{"phases" => ["implement"]}}],
      inbox_messages: [
        %{
          message_id: "legacy-message",
          run_id: "legacy-run",
          sender: "worker",
          recipient: "operator",
          body: "done"
        }
      ],
      config: %{"runtime" => "ts"}
    }
  end

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      string_key = if is_atom(key), do: Atom.to_string(key), else: key
      {string_key, stringify(item)}
    end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value
end
