defmodule ForemanServer.CommandGatewayRequiredChecksGuardTest do
  # The durable-store guard on the commands that can enable `required_checks` (TRD-028),
  # pinned through the gateway: key spellings, a mis-set switch, and what is not refused.
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, EventStore, ProjectionStore, ProjectStore}
  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.TestSupport.{KeyStoreReset, ProjectionStoreReset}

  @switch :require_durable_store_for_gating

  setup do
    original = Application.fetch_env(:foreman_server, @switch)
    ProjectionStoreReset.reset!()
    KeyStoreReset.reset!()

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:foreman_server, @switch, value)
        :error -> Application.delete_env(:foreman_server, @switch)
      end

      ProjectionStoreReset.reset!()
    end)

    Application.put_env(:foreman_server, @switch, true)
    refute KeyStore.durable?()

    id = unique("project")
    assert {:ok, _} = ProjectStore.save(%{project_id: id, path: "/tmp/#{id}", config: %{}})
    %{id: id}
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp command(type, id, payload) do
    %{
      command_id: unique("command"),
      aggregate_id: "project:#{id}",
      type: type,
      payload: Map.put(payload, :project_id, id)
    }
  end

  defp send_via(:operator, command), do: CommandGateway.dispatch_operator(command)
  defp send_via(:system, command), do: CommandGateway.dispatch_system(command)

  defp events(id, type) do
    case EventStore.read_stream_forward("project:#{id}", 0, 1_000) do
      {:ok, events} -> Enum.filter(events, &(&1.event_type == type))
      {:error, :stream_not_found} -> []
    end
  end

  describe "every spelling that sets required_checks is refused on a non-durable store" do
    test "update: top-level string key, false, nested atom and string key", %{id: id} do
      for payload <- [
            %{"required_checks" => []},
            %{required_checks: false},
            %{config: %{required_checks: false}},
            %{config: %{"required_checks" => []}}
          ],
          via <- [:operator, :system] do
        assert {:error, {:store_not_durable, _}} =
                 send_via(via, command("project.update", id, payload))
      end

      assert events(id, "ProjectUpdated") == []
    end

    test "register: top-level string key, false, nested atom and string key" do
      for payload <- [
            %{"required_checks" => [], path: System.tmp_dir!()},
            %{path: System.tmp_dir!(), required_checks: false},
            %{path: System.tmp_dir!(), config: %{required_checks: []}},
            %{path: System.tmp_dir!(), config: %{"required_checks" => []}}
          ],
          via <- [:operator, :system] do
        new_id = unique("project")

        assert {:error, {:store_not_durable, _}} =
                 send_via(via, command("project.register", new_id, payload))

        assert events(new_id, "ProjectRegistered") == []
      end
    end
  end

  describe "a mis-set switch is read as on, never a raise" do
    test "a non-boolean switch with required_checks set is the typed refusal, nothing appended",
         %{id: id} do
      for bad <- ["false", :off, 0, nil] do
        Application.put_env(:foreman_server, @switch, bad)

        assert {:error, {:store_not_durable, note}} =
                 CommandGateway.dispatch_operator(
                   command("project.update", id, %{required_checks: []})
                 )

        assert note =~ "must be a boolean"
        assert note =~ inspect(bad)

        assert {:error, {:store_not_durable, _}} =
                 CommandGateway.dispatch_system(
                   command("project.update", id, %{required_checks: []})
                 )
      end

      assert events(id, "ProjectUpdated") == []
    end

    test "KeyStore.require_durable/0 itself does not raise on a non-boolean switch" do
      Application.put_env(:foreman_server, @switch, "yes")
      assert {:error, {:store_not_durable, note}} = KeyStore.require_durable()
      assert note =~ ~s("yes")
    end
  end

  describe "what the guard does not refuse" do
    test "an unrelated setting and a clear-only update are accepted", %{id: id} do
      for via <- [:operator, :system] do
        assert {:ok, _} = send_via(via, command("project.update", id, %{max_concurrent_runs: 3}))

        assert {:ok, _} =
                 send_via(
                   via,
                   command("project.update", id, %{cleared_settings: ["required_checks"]})
                 )

        assert {:ok, _} = send_via(via, command("project.update", id, %{required_checks: nil}))
      end

      assert %{max_concurrent_runs: 3} = ProjectionStore.project_settings(id)
    end

    test "register without required_checks is accepted" do
      new_id = unique("project")

      assert {:ok, _} =
               CommandGateway.dispatch_operator(
                 command("project.register", new_id, %{
                   path: System.tmp_dir!(),
                   max_concurrent_runs: 2
                 })
               )
    end
  end
end
