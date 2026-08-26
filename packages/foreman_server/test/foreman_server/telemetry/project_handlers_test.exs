defmodule ForemanServer.Telemetry.ProjectHandlersTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Telemetry

  @project_events [
    [:foreman_server, :project, :read],
    [:foreman_server, :project, :list],
    [:foreman_server, :project, :register],
    [:foreman_server, :project, :update],
    [:foreman_server, :project, :archive]
  ]

  test "project lifecycle handlers are registered in Telemetry.all_events/0" do
    all_events = Telemetry.all_events()

    Enum.each(@project_events, fn event ->
      assert event in all_events
    end)
  end

  test "project_read emits duration_ms and outcome metadata" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:foreman_server, :project, :read]])
    on_exit(fn -> :telemetry.detach(ref) end)

    assert :ok = Telemetry.project_read(12, %{project_id: "project-read", outcome: :ok})

    assert_receive {[:foreman_server, :project, :read], ^ref, %{duration_ms: 12},
                    %{project_id: "project-read", outcome: :ok}}
  end

  test "project_list emits duration_ms, count, and outcome metadata" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:foreman_server, :project, :list]])
    on_exit(fn -> :telemetry.detach(ref) end)

    assert :ok = Telemetry.project_list(7, 3, %{outcome: :ok})

    assert_receive {[:foreman_server, :project, :list], ^ref,
                    %{duration_ms: 7, count: 3}, %{outcome: :ok}}
  end

  test "project_register emits duration_ms and lifecycle metadata" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:foreman_server, :project, :register]])
    on_exit(fn -> :telemetry.detach(ref) end)

    metadata = %{project_id: "project-register", outcome: :ok}

    assert :ok = Telemetry.project_register(5, metadata)

    assert_receive {[:foreman_server, :project, :register], ^ref, %{duration_ms: 5}, ^metadata}
  end

  test "project_update emits duration_ms and lifecycle metadata" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:foreman_server, :project, :update]])
    on_exit(fn -> :telemetry.detach(ref) end)

    metadata = %{project_id: "project-update", outcome: :ok}

    assert :ok = Telemetry.project_update(8, metadata)

    assert_receive {[:foreman_server, :project, :update], ^ref, %{duration_ms: 8}, ^metadata}
  end

  test "project_archive error emits duration_ms plus code and retryable metadata" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:foreman_server, :project, :archive]])
    on_exit(fn -> :telemetry.detach(ref) end)

    metadata = %{
      project_id: "project-archive",
      outcome: :error,
      code: "project_has_active_runs",
      retryable: false
    }

    assert :ok = Telemetry.project_archive(11, metadata)

    assert_receive {[:foreman_server, :project, :archive], ^ref, %{duration_ms: 11}, ^metadata}
  end
end
