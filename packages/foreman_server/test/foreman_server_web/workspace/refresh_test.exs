defmodule ForemanServerWeb.Workspace.RefreshTest do
  # CodeRabbit PR #591 [9] (bead foreman-27ayh): `Refresh` reads a broadcast event's shape ONCE
  # and its project id under ONE key. `ProjectionStore` broadcasts what it applied: `%EventData{}`
  # and `%RecordedEvent{}` (their `data` is a typed event struct or an atom-keyed map; the event
  # store serializer writes terms, so keys keep their type) and the `%{event_type:, payload:}`
  # maps `ProjectionStore.apply_events/1` also accepts. These tests are the shape contract:
  # a shape is either understood or it raises, and is never guessed at.
  use ExUnit.Case, async: false

  alias EventStore.{EventData, RecordedEvent}
  alias ForemanServer.Events.{ProjectPaused, RunStarted}
  alias ForemanServerWeb.Workspace.Refresh

  @project "p-this"
  @other "p-other"

  @shape_names [
    "EventData with an atom-keyed map",
    "EventData with a typed event struct",
    "RecordedEvent with an atom-keyed map",
    "RecordedEvent with a typed event struct",
    "applied map with a payload",
    "plain map with data"
  ]

  setup do
    previous = Application.get_env(:foreman_server, :workspace)
    # the coalescing timer must not fire inside a test that is not about it
    Application.put_env(:foreman_server, :workspace, coalesce_ms: 60_000)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:foreman_server, :workspace)
        value -> Application.put_env(:foreman_server, :workspace, value)
      end
    end)
  end

  # `init/1` on a bare (unconnected) socket only sets the assigns: no subscription.
  defp socket, do: Refresh.init(%Phoenix.LiveView.Socket{})

  defp pending?(socket), do: socket.assigns.refresh_pending?

  defp relevant?(event), do: socket() |> Refresh.note_event(event, @project) |> pending?()

  # The event of one shape the store broadcasts; `project_id` nil means the event names none.
  defp event(name, type, project_id) do
    data = if project_id, do: %{project_id: project_id}, else: %{}

    case name do
      "EventData with an atom-keyed map" ->
        %EventData{event_type: type, data: data}

      "EventData with a typed event struct" ->
        %EventData{event_type: type, data: %RunStarted{run_id: "r1", project_id: project_id}}

      "RecordedEvent with an atom-keyed map" ->
        %RecordedEvent{event_type: type, data: data}

      # what a project event is re-read as: `ProjectPaused` and its siblings carry a struct
      "RecordedEvent with a typed event struct" ->
        %RecordedEvent{event_type: type, data: %ProjectPaused{project_id: project_id}}

      "applied map with a payload" ->
        %{event_type: type, payload: data}

      "plain map with data" ->
        %{event_type: type, data: data}
    end
  end

  describe "an event of this project" do
    for name <- @shape_names do
      test "is relevant: #{name}" do
        assert relevant?(event(unquote(name), "RunStarted", @project))
      end
    end
  end

  describe "an event of another project" do
    for name <- @shape_names do
      test "is not relevant: #{name}" do
        refute relevant?(event(unquote(name), "RunStarted", @other))
      end
    end
  end

  describe "an event without a project id (a run event, say)" do
    for name <- @shape_names do
      test "concerns every workspace: #{name}" do
        assert relevant?(event(unquote(name), "RunStarted", nil))
      end
    end
  end

  describe "worker output" do
    for name <- @shape_names do
      test "never refreshes, even for this project: #{name}" do
        refute relevant?(event(unquote(name), "WorkerStdout", @project))
      end
    end
  end

  test "a string key is not a second spelling of the project id" do
    # Not read: the event is unscoped, exactly like one that names no project at all.
    assert relevant?(%{event_type: "RunStarted", data: %{"project_id" => @other}})
  end

  test "a project id that is neither absent nor a string is a defect, not a guess" do
    assert_raise CaseClauseError, fn ->
      relevant?(%{event_type: "RunStarted", data: %{project_id: 42}})
    end
  end

  describe "a shape the store never broadcasts" do
    for {name, event} <- [
          {"string-keyed envelope", %{"event_type" => "RunStarted", "data" => %{}}},
          {"no data or payload", %{event_type: "RunStarted"}},
          {"data that is not a map", %{event_type: "RunStarted", data: "p-other"}},
          {"event type that is not a string", %{event_type: :run_started, data: %{}}},
          {"not an event at all", %{some: :map}}
        ] do
      test "raises instead of being ignored or refreshing everyone: #{name}" do
        assert_raise FunctionClauseError, fn -> relevant?(unquote(Macro.escape(event))) end
      end
    end
  end

  test "the first relevant event arms the coalescing timer; later ones only keep the flag" do
    Application.put_env(:foreman_server, :workspace, coalesce_ms: 1)
    event = %{event_type: "RunStarted", data: %{project_id: @project}}

    armed = Refresh.note_event(socket(), event, @project)
    assert pending?(armed)
    assert_receive :workspace_refresh, 5_000

    # Already pending: a second event must arm no second timer. A timer armed now would
    # fire before this later one (earlier expiry), so once the barrier has arrived every
    # refresh message there will ever be for these events is already in the mailbox.
    assert pending?(Refresh.note_event(armed, event, @project))
    Process.send_after(self(), :barrier, 50)
    assert_receive :barrier, 5_000
    refute_received :workspace_refresh
  end

  describe "intent, the idempotency token of an action (CodeRabbit PR #591 [7])" do
    # The command id of every workspace action is built from it. A counter that restarts
    # with the VM would let a new action reuse an old, committed command id and be answered
    # "Done" with nothing appended, so each session carries a random nonce of its own.
    test "two sessions never share one, even at the same refresh count" do
      refute Refresh.intent(socket()) == Refresh.intent(socket())
    end

    test "stays put until the projection has been re-read, then changes" do
      session = socket()
      assert Refresh.intent(session) == Refresh.intent(session)
      refute Refresh.intent(Refresh.begin_refresh(session)) == Refresh.intent(session)
    end
  end
end
