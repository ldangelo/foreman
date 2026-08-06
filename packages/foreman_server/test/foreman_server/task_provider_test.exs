defmodule ForemanServer.TaskProviderTest do
  use ExUnit.Case, async: true

  test "declares 11 callbacks via @behaviour" do
    assert function_exported?(ForemanServer.TaskProvider, :behaviour_info, 1) == true
  end

  test "behaviour_info(:callbacks) returns 11 expected callbacks" do
    callbacks = ForemanServer.TaskProvider.behaviour_info(:callbacks)

    assert Keyword.keyword?(callbacks)
    assert length(callbacks) == 11
    assert {:name, 0} in callbacks
    assert {:capabilities, 0} in callbacks
    assert {:available?, 0} in callbacks
    assert {:list_ready, 2} in callbacks
    assert {:get, 2} in callbacks
    assert {:claim, 3} in callbacks
    assert {:complete, 3} in callbacks
    assert {:fail, 3} in callbacks
    assert {:reopen, 3} in callbacks
    assert {:set_priority, 3} in callbacks
    assert {:add_dependency, 3} in callbacks
    assert length(callbacks) == 11
  end
end

defmodule ForemanServer.TaskProvider.TelemetryTest do
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProvider.Telemetry

  @doctor_probe_event [:foreman_server, :task_provider, :beads_adapter, :doctor, :probe]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    :ok
  end

  test "taxonomy enumerates documented and implementation task-provider events" do
    taxonomy = Telemetry.taxonomy()

    assert taxonomy[[:foreman_server, :task_provider, :registry, :restarted]] == %{
             metadata_keys: [:restart_count, :providers, :registry],
             scrub_required?: false,
             description: "Registry restarted and rebuilt its routing snapshot."
           }

    assert taxonomy[[:foreman_server, :task_provider, :beads, :capabilities, :refreshed]] == %{
             metadata_keys: [:schema_count, :contract_version, :refreshed_at],
             scrub_required?: false,
             description: "Schema cache refreshed and observed the active contract version."
           }

    assert taxonomy[[:foreman_server, :task_provider, :beads, :temp_file, :leaked]] == %{
             metadata_keys: [:kind],
             scrub_required?: false,
             description: "SystemBrRunner detected and cleaned a leaked temporary file."
           }

    assert taxonomy[[:foreman_server, :task_provider, :registry, :route, :ok]].metadata_keys ==
             [:transition, :routing_key, :provider]

    assert taxonomy[[:foreman_server, :task_provider, :registry, :route, :error]].metadata_keys ==
             [:transition, :routing_key, :reason]

    assert taxonomy[[:foreman_server, :task_provider, :beads_adapter, :preflight, :start]].scrub_required? ==
             true

    assert taxonomy[[:foreman_server, :task_provider, :beads_adapter, :preflight, :ok]].metadata_keys ==
             [:argv]

    assert taxonomy[[:foreman_server, :task_provider, :beads_adapter, :preflight, :error]].metadata_keys ==
             [:argv, :error]

    assert taxonomy[[:foreman_server, :task_provider, :beads, :contract, :version_changed]].metadata_keys ==
             [:previous_version, :current_version]

    assert taxonomy[[:foreman_server, :task_provider, :concurrency_limiter, :acquire]].metadata_keys ==
             [:project_id, :source, :in_flight]

    assert taxonomy[[:foreman_server, :task_provider, :concurrency_limiter, :release]].metadata_keys ==
             [:project_id, :granted_waiter?, :in_flight]

    assert taxonomy[[:foreman_server, :task_provider, :concurrency_limiter, :timeout]].metadata_keys ==
             [:project_id]
  end

  test "scrub_argv redacts sentinels while preserving order and caller argv" do
    original_argv = [
      "claim",
      "ISS-1",
      {:database_path, "/tmp/secret.db"},
      {:claim_token, "claimtok"},
      {:completion_token, "complete1"},
      {:failure_token, "failure1"},
      "--transition-comment",
      String.duplicate("x", 65),
      "--db",
      "/abs/path",
      "--json"
    ]

    assert Telemetry.scrub_argv(original_argv) == [
             "claim",
             "ISS-1",
             {:database_path, "/abs/<redacted:14>"},
             {:claim_token, "<redacted:8>"},
             {:completion_token, "<redacted:8>"},
             {:failure_token, "<redacted:8>"},
             "--transition-comment",
             "<redacted:64>",
             "--db",
             "/abs/<redacted:9>",
             "--json"
           ]

    assert original_argv == [
             "claim",
             "ISS-1",
             {:database_path, "/tmp/secret.db"},
             {:claim_token, "claimtok"},
             {:completion_token, "complete1"},
             {:failure_token, "failure1"},
             "--transition-comment",
             String.duplicate("x", 65),
             "--db",
             "/abs/path",
             "--json"
           ]
  end

  test "emit scrubs argv metadata before telemetry delivery" do
    handler_id = "task-provider-telemetry-test-#{System.unique_integer([:positive, :monotonic])}"
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        @doctor_probe_event,
        &__MODULE__.handle_telemetry/4,
        self()
      )

    :ok =
      Telemetry.emit(
        @doctor_probe_event,
        %{system_time: System.system_time()},
        %{argv: ["doctor", "--db", "/tmp/db.sqlite", "--json"], probe: :ok}
      )

    assert_receive {:telemetry, @doctor_probe_event, %{system_time: system_time}, metadata}, 1_000
    assert is_integer(system_time)
    assert metadata == %{argv: ["doctor", "--db", "/abs/<redacted:14>", "--json"], probe: :ok}
  end

  def handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end
end
