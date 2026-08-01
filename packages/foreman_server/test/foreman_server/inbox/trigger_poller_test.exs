defmodule ForemanServer.Inbox.TriggerPollerTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{EventStore, Inbox.TriggerPoller}
  alias ForemanServer.ProjectionStore

  @project_id "poller-test-proj"
  @project_path "/tmp/poller-test-proj"
  @run_id "run-poller-001"

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-poller-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    :ok = Application.start(:foreman_server)

    # Register a minimal test project so CommandRouter.resolve_project/1 succeeds.
    {:ok, project} = ForemanServer.Project.new(%{id: @project_id, path: @project_path, config: %{}})
    {:ok, _} = ForemanServer.ProjectStore.save(project)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      Application.delete_env(:foreman_server, :external_trigger_poll_enabled)
      Application.delete_env(:foreman_server, :external_trigger_poll_interval_seconds)
      Application.delete_env(:foreman_server, :external_trigger_endpoint_url)
      :ok = Application.start(:foreman_server)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  # ─── gen_tcp mock endpoint helpers ─────────────────────────────────────────
  # Uses raw packet mode so we receive raw binaries we can pattern-match on.

  defp start_tcp_server(loop_type \\ :empty) do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, reuseaddr: true, active: false])
    {:ok, {_, port}} = :inet.sockname(listen_socket)
    loop_fn = loop_fn(loop_type, listen_socket)
    pid = spawn(fn -> loop_fn.(listen_socket) end)
    {:ok, pid, port, listen_socket}
  end

  defp loop_fn(:empty, _listen_socket), do: fn socket -> accept_loop(socket, &respond_ok/0) end
  defp loop_fn(:triggers, _listen_socket), do: fn socket -> accept_loop_with_triggers(socket, @run_id) end
  defp loop_fn(:status_500, _listen_socket), do: fn socket -> accept_loop_500(socket) end

  defp accept_loop(listen_socket, responder) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        _ = recv_until_double_crlf(socket, <<>>)
        :gen_tcp.send(socket, responder.())
        :gen_tcp.close(socket)
        accept_loop(listen_socket, responder)

      {:error, _} ->
        :ok
    end
  end

  defp accept_loop_with_triggers(listen_socket, run_id) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        _ = recv_until_double_crlf(socket, <<>>)
        :gen_tcp.send(socket, respond_with_trigger(run_id))
        :gen_tcp.close(socket)
        accept_loop_with_triggers(listen_socket, run_id)

      {:error, _} ->
        :ok
    end
  end

  defp accept_loop_500(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        _ = recv_until_double_crlf(socket, <<>>)
        :gen_tcp.send(socket, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n")
        :gen_tcp.close(socket)
        accept_loop_500(listen_socket)

      {:error, _} ->
        :ok
    end
  end

  # Read from socket until we see the double-CRLF that terminates HTTP headers.
  defp recv_until_double_crlf(socket, acc) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, chunk} ->
        acc = acc <> chunk
        if String.contains?(acc, "\r\n\r\n"), do: acc, else: recv_until_double_crlf(socket, acc)

      {:error, _} ->
        acc
    end
  end

  defp respond_ok do
    body = Jason.encode!(%{triggers: []})
    """
    HTTP/1.1 200 OK\r
    Content-Type: application/json\r
    Content-Length: #{byte_size(body)}\r
    \r
    #{body}
    """
  end

  defp respond_with_trigger(run_id) do
    trigger = %{
      "trigger_id" => "trigger-#{run_id}",
      "source" => "test-poller",
      "run_id" => run_id,
      "event_type" => "push"
    }

    body = Jason.encode!(%{triggers: [trigger]})
    """
    HTTP/1.1 200 OK\r
    Content-Type: application/json\r
    Content-Length: #{byte_size(body)}\r
    \r
    #{body}
    """
  end

  # ─── Inert when not configured ───────────────────────────────────────────

  test "inert when enabled is false (endpoint never called)" do
    Application.put_env(:foreman_server, :external_trigger_poll_enabled, false)
    Application.put_env(:foreman_server, :external_trigger_poll_interval_seconds, 60)
    Application.put_env(:foreman_server, :external_trigger_endpoint_url, "http://127.0.0.1:9999/none")

    # Stop app, restart so poller picks up new config.
    Application.stop(:foreman_server)
    :ok = Application.start(:foreman_server)

    pid = Process.whereis(TriggerPoller)
    assert is_pid(pid)
    state = :sys.get_state(pid)
    # Inert: endpoint_url is nil, interval_ms is 0
    assert state.endpointurl == nil
    assert state.interval_ms == 0
  end

  test "inert when endpoint URL is nil" do
    Application.put_env(:foreman_server, :external_trigger_poll_enabled, true)
    Application.put_env(:foreman_server, :external_trigger_poll_interval_seconds, 60)
    Application.put_env(:foreman_server, :external_trigger_endpoint_url, nil)

    Application.stop(:foreman_server)
    :ok = Application.start(:foreman_server)

    pid = Process.whereis(TriggerPoller)
    state = :sys.get_state(pid)
    assert state.endpointurl == nil
    assert state.interval_ms == 0
  end

  # ─── Polling: fetch + submit ─────────────────────────────────────────────

  test "fetches endpoint and sends trigger through SharedInbox on :poll" do
    {:ok, _server, port, listen_socket} = start_tcp_server(:triggers)

    Application.put_env(:foreman_server, :external_trigger_poll_enabled, true)
    Application.put_env(:foreman_server, :external_trigger_poll_interval_seconds, 3600)
    Application.put_env(:foreman_server, :external_trigger_endpoint_url, "http://127.0.0.1:#{port}/triggers")

    Application.stop(:foreman_server)
    :ok = Application.start(:foreman_server)

    pid = Process.whereis(TriggerPoller)
    state = :sys.get_state(pid)
    assert state.endpointurl != nil

    # Manually trigger the poll.
    send(pid, :poll)
    Process.sleep(200)

    # Inbox stream should have an InboxItemStarted for the trigger's correlation_id.
    # The trigger has trigger_id="trigger-run-poller-001", so correlation_id is "trigger-run-poller-001".
    stream_key = "inbox:#{@run_id}"
    events = EventStore.stream(stream_key)
    started = Enum.filter(events, &(&1.event_type == "InboxItemStarted"))
    assert length(started) >= 1

    first = hd(started)
    assert first.payload.correlation_id == "trigger-#{@run_id}"

    # Sub-item 3: delivery_status tracked in projection store
    assert ProjectionStore.snapshot().inbox_messages["trigger-#{@run_id}"].delivery_status == "started"

    :gen_tcp.close(listen_socket)
  end

  test "periodic timer fires and fetches endpoint" do
    {:ok, _server, port, listen_socket} = start_tcp_server(:triggers)

    Application.put_env(:foreman_server, :external_trigger_poll_enabled, true)
    Application.put_env(:foreman_server, :external_trigger_poll_interval_seconds, 1)
    Application.put_env(:foreman_server, :external_trigger_endpoint_url, "http://127.0.0.1:#{port}/triggers")

    Application.stop(:foreman_server)
    :ok = Application.start(:foreman_server)

    pid = Process.whereis(TriggerPoller)
    state = :sys.get_state(pid)
    assert state.endpointurl != nil

    # No manual :poll — wait for the timer to fire naturally (~1 second).
    Process.sleep(1500)

    stream_key = "inbox:#{@run_id}"
    events = EventStore.stream(stream_key)
    started = Enum.filter(events, &(&1.event_type == "InboxItemStarted"))
    assert length(started) >= 1

    first = hd(started)
    assert first.payload.correlation_id == "trigger-#{@run_id}"

    :gen_tcp.close(listen_socket)
  end

  test "non-200 response does not crash and poller stays alive" do
    {:ok, _server, port, listen_socket} = start_tcp_server(:status_500)

    Application.put_env(:foreman_server, :external_trigger_poll_enabled, true)
    Application.put_env(:foreman_server, :external_trigger_poll_interval_seconds, 3600)
    Application.put_env(:foreman_server, :external_trigger_endpoint_url, "http://127.0.0.1:#{port}/triggers")

    Application.stop(:foreman_server)
    :ok = Application.start(:foreman_server)

    pid = Process.whereis(TriggerPoller)
    send(pid, :poll)
    Process.sleep(200)

    # Poller still alive.
    assert Process.alive?(pid)

    :gen_tcp.close(listen_socket)
  end

end
