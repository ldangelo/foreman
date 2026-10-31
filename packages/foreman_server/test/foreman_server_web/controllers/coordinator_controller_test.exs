defmodule ForemanServerWeb.CoordinatorControllerTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @endpoint ForemanServerWeb.Endpoint

  import Plug.Conn
  import Phoenix.ConnTest
  import ExUnit.CaptureLog

  alias ForemanServer.{CommandGateway, CommandRouter, EventStore, ProjectionStore, SecretStore}
  alias ForemanServer.Observability.SecretValueLogFilter
  alias ForemanServer.Observability.SecretValueLogFilter.Refresher
  alias ForemanServer.TestSupport.SecretStoreDir

  @token "coordinator-controller-test-token"

  @message_keys ~w(at kind message_id report_key role seq source suppressed text thread_ref turn_id)
  @page_keys ~w(has_more messages next_cursor pending_messages status truncated_before_seq)
  @status_keys ~w(consecutive_failures last_activity_at last_error open_turn pending_messages status)

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    project_id = "http-co-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        aggregate_id: "project:#{project_id}",
        payload: %{project_id: project_id, path: dir}
      })

    {:ok, project_id: project_id}
  end

  defp authed, do: build_conn() |> put_req_header("authorization", "Bearer #{@token}")
  defp base(p), do: "/api/projects/#{p}/coordinator"

  defp post_message(p, body) do
    authed()
    |> put_req_header("content-type", "application/json")
    |> post(base(p) <> "/messages", body)
  end

  defp get_messages(p, query \\ "") do
    authed() |> get(base(p) <> "/messages" <> query)
  end

  defp stream_events(p) do
    case EventStore.read_stream_forward("coordinator:#{p}", 0, 100) do
      {:ok, events} -> events
      {:error, :stream_not_found} -> []
    end
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  defp gateway_message(p, id, text) do
    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        command_id: "gw-#{id}",
        aggregate_id: "coordinator:#{p}",
        type: "coordinator.message",
        payload: %{project_id: p, message_id: id, text: text, source: "cli"}
      })
  end

  test "the posted message text is not written to the server log (foreman-mw5rz)", %{
    project_id: p
  } do
    canary = "LOGCANARY-#{System.unique_integer([:positive])}"

    log =
      capture_log([level: :debug], fn ->
        post_message(p, %{"text" => canary}) |> json_response(202)
      end)

    # Control: the router dispatch line is emitted (so the refute below can fail).
    assert log =~ "Parameters:"
    refute log =~ canary
  end

  test "a stored secret under a param key nobody listed is redacted from the request log by value (foreman-25sqf.1.1)",
       %{project_id: p, tmp_dir: dir} do
    SecretStoreDir.use_tmp_dir!(dir)
    # The application does not run the filter in the test environment (config/test.exs).
    :ok = SecretValueLogFilter.install()
    start_supervised!({Refresher, interval_ms: 3_600_000})
    on_exit(fn -> SecretValueLogFilter.uninstall() end)
    value = "LOGSECRET-#{System.unique_integer([:positive])}-zzzz"
    {:ok, :stored} = SecretStore.put(p, "DEPLOY_TARGET", value)
    :ok = Refresher.refresh_sync()

    log =
      capture_log([level: :debug], fn ->
        post_message(p, %{"text" => "hello", "unlisted_note" => value}) |> json_response(202)
      end)

    # Controls: the dispatch line is emitted and the key was NOT hidden by name, so it is the
    # value-based filter alone that removed the secret.
    assert log =~ "Parameters:"
    assert log =~ "unlisted_note"
    assert log =~ "[REDACTED]"
    refute log =~ value
  end

  test "POST accepts a message: 202, generated id, source defaults to http", %{project_id: p} do
    body = post_message(p, %{"text" => "fix login"}) |> json_response(202)

    assert keys(body) == ["message_id", "seq"]
    assert body["seq"] == 1
    assert is_binary(body["message_id"]) and body["message_id"] != ""

    assert {:ok, %{messages: [m]}} = ProjectionStore.coordinator_conversation(p)
    assert m.source == "http"
    assert m.role == "operator"
    assert m.message_id == body["message_id"]
  end

  test "the same message_id twice returns the original seq and appends nothing", %{project_id: p} do
    first = post_message(p, %{"text" => "a", "message_id" => "m-1", "source" => "cli"})
    assert %{"seq" => seq, "message_id" => "m-1"} = json_response(first, 202)

    {:ok, before} = EventStore.read_stream_forward("coordinator:#{p}", 0, 100)

    again = post_message(p, %{"text" => "a", "message_id" => "m-1", "source" => "cli"})
    assert %{"seq" => ^seq, "message_id" => "m-1"} = json_response(again, 202)

    {:ok, after_events} = EventStore.read_stream_forward("coordinator:#{p}", 0, 100)
    assert length(after_events) == length(before)
    assert {:ok, %{messages: [%{source: "cli"}]}} = ProjectionStore.coordinator_conversation(p)
  end

  test "source mcp (or anything else) is refused over HTTP and nothing is stored", %{
    project_id: p
  } do
    for source <- ["mcp", "bogus", 5] do
      body = post_message(p, %{"text" => "x", "source" => source}) |> json_response(422)
      assert body == %{"error" => "invalid_source", "message" => "invalid source"}
    end

    for source <- ["cli", "http", "dashboard"] do
      assert post_message(p, %{"text" => "x-#{source}", "source" => source}) |> json_response(202)
    end

    assert {:ok, %{messages: messages}} = ProjectionStore.coordinator_conversation(p)
    assert Enum.map(messages, & &1.source) == ["cli", "http", "dashboard"]
  end

  test "invalid text and message_id are 422", %{project_id: p} do
    for body <- [%{}, %{"text" => ""}, %{"text" => "  "}, %{"text" => 5}] do
      assert %{"error" => "invalid_text"} = post_message(p, body) |> json_response(422)
    end

    assert %{"error" => "invalid_message_id"} =
             post_message(p, %{"text" => "x", "message_id" => ""}) |> json_response(422)
  end

  test "unknown project is 404, archived is 409, oversize text is 413", %{project_id: p} do
    assert %{"error" => "project_not_found"} =
             post_message("ghost", %{"text" => "x"}) |> json_response(404)

    assert %{"error" => "project_not_found"} = get_messages("ghost") |> json_response(404)

    assert %{"error" => "project_not_found"} =
             authed() |> get(base("ghost")) |> json_response(404)

    assert %{"error" => "project_not_found"} =
             authed() |> post(base("ghost") <> "/restart") |> json_response(404)

    assert %{"error" => "message_too_large", "message" => message} =
             post_message(p, %{"text" => String.duplicate("a", 16_001)}) |> json_response(413)

    assert message =~ "16000"
    assert {:ok, %{messages: []}} = ProjectionStore.coordinator_conversation(p)

    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        command_id: "arch-#{p}",
        aggregate_id: "project:#{p}",
        type: "project.archive",
        payload: %{project_id: p}
      })

    assert %{"error" => "project_archived"} =
             post_message(p, %{"text" => "x"}) |> json_response(409)

    assert %{"error" => "project_archived"} =
             authed() |> post(base(p) <> "/restart") |> json_response(409)
  end

  test "GET pages by cursor and limit with exact whitelisted keys", %{project_id: p} do
    for i <- 1..5, do: gateway_message(p, "m#{i}", "text #{i}")

    page = get_messages(p, "?limit=2") |> json_response(200)
    assert keys(page) == @page_keys
    assert Enum.map(page["messages"], & &1["text"]) == ["text 1", "text 2"]
    assert Enum.all?(page["messages"], &(keys(&1) == @message_keys))
    assert page["next_cursor"] == 2
    assert page["has_more"] == true
    assert page["truncated_before_seq"] == nil
    assert page["status"] == "idle"

    page2 = get_messages(p, "?after=#{page["next_cursor"]}&limit=10") |> json_response(200)
    assert Enum.map(page2["messages"], & &1["seq"]) == [3, 4, 5]
    assert page2["has_more"] == false
    assert page2["next_cursor"] == 5

    empty = get_messages(p, "?after=5") |> json_response(200)
    assert empty["messages"] == []
    assert empty["next_cursor"] == 5
  end

  test "GET rejects an invalid cursor, limit or wait_ms and never mutates", %{project_id: p} do
    before = stream_events(p)

    for {query, code} <- [
          {"?after=-1", "invalid_after"},
          {"?after=x", "invalid_after"},
          {"?limit=0", "invalid_limit"},
          {"?limit=201", "invalid_limit"},
          {"?wait_ms=25001", "invalid_wait_ms"},
          {"?wait_ms=-5", "invalid_wait_ms"}
        ] do
      assert %{"error" => ^code} = get_messages(p, query) |> json_response(422)
    end

    _ = get_messages(p) |> json_response(200)
    _ = authed() |> get(base(p)) |> json_response(200)

    assert stream_events(p) == before
    assert before == []
  end

  test "long-poll returns early when a message arrives", %{project_id: p} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :polling)
        get_messages(p, "?wait_ms=20000") |> json_response(200)
      end)

    assert_receive :polling
    # The poll may or may not have subscribed yet: either way the message is
    # delivered (read-after-subscribe covers the race), so no sleep is needed.
    gateway_message(p, "late", "wake up")

    page = Task.await(task, 10_000)
    assert Enum.map(page["messages"], & &1["text"]) == ["wake up"]
    assert keys(page) == @page_keys
  end

  test "long-poll returns an empty page on timeout", %{project_id: p} do
    page = get_messages(p, "?wait_ms=50") |> json_response(200)
    assert page["messages"] == []
    assert page["next_cursor"] == 0
    assert page["has_more"] == false
    assert page["status"] == "idle"
  end

  test "long-poll ignores messages of another project", %{project_id: p, tmp_dir: dir} do
    other = "http-co-other-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        aggregate_id: "project:#{other}",
        payload: %{project_id: other, path: dir}
      })

    task = Task.async(fn -> get_messages(p, "?wait_ms=300") |> json_response(200) end)
    gateway_message(other, "o1", "not yours")

    assert Task.await(task, 10_000)["messages"] == []
  end

  test "GET status and restart return the exact status shape", %{project_id: p} do
    status = authed() |> get(base(p)) |> json_response(200)
    assert keys(status) == @status_keys

    assert %{
             "status" => "idle",
             "open_turn" => nil,
             "consecutive_failures" => 0,
             "last_error" => nil,
             "pending_messages" => 0
           } = status

    gateway_message(p, "pending", "do something")
    assert (authed() |> get(base(p)) |> json_response(200))["pending_messages"] == 1

    restarted = authed() |> post(base(p) <> "/restart") |> json_response(200)
    assert keys(restarted) == @status_keys

    {:ok, events} = EventStore.read_stream_forward("coordinator:#{p}", 0, 100)
    assert Enum.any?(events, &(&1.event_type == "CoordinatorRestarted"))
  end

  test "routes require the bearer token", %{project_id: p} do
    assert build_conn() |> get(base(p)) |> response(401)
    assert build_conn() |> post(base(p) <> "/messages", %{"text" => "x"}) |> response(401)
  end
end
