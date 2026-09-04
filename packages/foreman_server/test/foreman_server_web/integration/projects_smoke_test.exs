defmodule ForemanServerWeb.Integration.ProjectsSmokeTest do
  @moduledoc """
  Live-server smoke test for the projects API.

  Must be run with the application started (`mix test`, not `--no-start`).
  """

  use ExUnit.Case, async: false

  alias ForemanServer.{ProjectStore, ProjectionStore}
  alias ForemanServerWeb.Endpoint

  @token "projects-smoke-test-token"
  @poll_timeout_ms 8_000

  setup_all do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
    :ok
  end

  setup do
    previous_token = Application.get_env(:foreman_server, :api_bearer_token)
    previous_endpoint_config = Application.get_env(:foreman_server, Endpoint, [])

    Application.put_env(:foreman_server, :api_bearer_token, @token)

    Application.put_env(
      :foreman_server,
      Endpoint,
      Keyword.put_new(previous_endpoint_config, :secret_key_base, String.duplicate("a", 64))
    )

    reset_projection_store()

    ref = String.to_atom("projects-smoke-#{System.unique_integer([:positive])}")

    start_supervised!({
      Plug.Cowboy,
      scheme: :http, plug: Endpoint, options: [ip: {127, 0, 0, 1}, port: 0, ref: ref]
    })

    base_url = "http://127.0.0.1:#{:ranch.get_port(ref)}"

    on_exit(fn ->
      reset_projection_store()

      if previous_token == nil do
        Application.delete_env(:foreman_server, :api_bearer_token)
      else
        Application.put_env(:foreman_server, :api_bearer_token, previous_token)
      end

      Application.put_env(:foreman_server, Endpoint, previous_endpoint_config)
    end)

    {:ok, base_url: base_url}
  end

  test "projects API smoke contract returns 200, 200-empty, 404, and 401 in sequence", %{
    base_url: base_url
  } do
    visible_project_id = unique_project_id("visible")

    assert {:ok, _} =
             ProjectStore.save(%{
               project_id: visible_project_id,
               path: "/tmp/#{visible_project_id}",
               name: "Visible Smoke Project",
               task_provider: %{provider: :beads, config: %{"database_path" => "/tmp/visible.db"}}
             })

    poll_until(
      fn ->
        case request(:get, base_url <> "/api/projects", authorized_headers()) do
          {:ok, 200, %{"projects" => projects, "meta" => %{"truncated" => false}}, headers} ->
            header(headers, "x-total-count") == "1" and
              Enum.any?(projects, fn project ->
                project["project_id"] == visible_project_id and
                  project["path"] == "/tmp/#{visible_project_id}" and
                  project["name"] == "Visible Smoke Project"
              end)

          _ ->
            false
        end
      end,
      "visible project to appear in GET /api/projects"
    )

    assert {:ok, 200, non_empty_body, non_empty_headers} =
             request(:get, base_url <> "/api/projects", authorized_headers())

    assert non_empty_body["meta"] == %{"truncated" => false}
    assert header(non_empty_headers, "x-total-count") == "1"

    assert Enum.any?(non_empty_body["projects"], fn project ->
             project["project_id"] == visible_project_id and
               project["path"] == "/tmp/#{visible_project_id}" and
               project["name"] == "Visible Smoke Project"
           end)

    reset_projection_store()

    archived_project_id = unique_project_id("archived")

    assert {:ok, _} =
             ProjectStore.save(%{
               project_id: archived_project_id,
               path: "/tmp/#{archived_project_id}",
               name: "Archived Smoke Project",
               task_provider: %{
                 provider: :beads,
                 config: %{"database_path" => "/tmp/archived.db"}
               }
             })

    assert {:ok, _} = ProjectStore.archive(archived_project_id)

    poll_until(
      fn ->
        case request(:get, base_url <> "/api/projects", authorized_headers()) do
          {:ok, 200, %{"projects" => [], "meta" => %{"truncated" => false}}, headers} ->
            header(headers, "x-total-count") == "0"

          _ ->
            false
        end
      end,
      "archived-only project list to be filtered from GET /api/projects"
    )

    assert {:ok, 200, empty_body, empty_headers} =
             request(:get, base_url <> "/api/projects", authorized_headers())

    assert empty_body == %{"projects" => [], "meta" => %{"truncated" => false}}
    assert header(empty_headers, "x-total-count") == "0"

    missing_project_id = unique_project_id("missing")

    assert {:ok, 404, not_found_body, _headers} =
             request(
               :get,
               base_url <> "/api/projects/#{missing_project_id}",
               authorized_headers()
             )

    assert not_found_body == %{"error" => "not_found", "reason" => ":project_not_found"}

    assert {:ok, 401, unauthorized_body, _headers} = request(:get, base_url <> "/api/projects")
    assert unauthorized_body == %{"error" => "unauthorized"}
  end

  defp request(method, url, headers \\ [])

  defp request(:get, url, headers) do
    request_raw("GET", url, headers, "")
  end

  defp request_raw(method, url, headers, body) when is_binary(body) do
    uri = URI.parse(url)
    host = uri.host || "127.0.0.1"
    port = uri.port || 80
    path = request_path(uri)

    {:ok, socket} =
      :gen_tcp.connect(
        String.to_charlist(host),
        port,
        [:binary, active: false, packet: :raw],
        5_000
      )

    :ok = :gen_tcp.send(socket, build_http_request(method, path, host, headers, body))
    response = recv_all(socket, "")
    :ok = :gen_tcp.close(socket)

    parse_http_response(response)
  end

  defp build_http_request(method, path, host, headers, body) do
    request_headers =
      [{"host", host}, {"connection", "close"}]
      |> Kernel.++(headers)
      |> maybe_put_content_length(body)
      |> Enum.map_join("", fn {key, value} -> "#{key}: #{value}\r\n" end)

    [method, " ", path, " HTTP/1.1\r\n", request_headers, "\r\n", body]
  end

  defp maybe_put_content_length(headers, ""), do: headers

  defp maybe_put_content_length(headers, body),
    do: headers ++ [{"content-length", byte_size(body)}]

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk)
      {:error, :closed} -> acc
    end
  end

  defp parse_http_response(response) do
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n", trim: true)
    [_http, status_code | _] = String.split(status_line, " ", parts: 3)

    {:ok, String.to_integer(status_code), Jason.decode!(body), decode_headers(header_lines)}
  end

  defp request_path(%URI{path: nil, query: nil}), do: "/"
  defp request_path(%URI{path: path, query: nil}) when is_binary(path) and path != "", do: path
  defp request_path(%URI{path: nil, query: query}), do: "/?" <> query
  defp request_path(%URI{path: "", query: nil}), do: "/"

  defp request_path(%URI{path: path, query: query}) when is_binary(query),
    do: path <> "?" <> query

  defp authorized_headers do
    [{"authorization", "Bearer #{@token}"}]
  end

  defp decode_headers(headers) do
    Map.new(headers, fn line ->
      [key, value] = String.split(line, ":", parts: 2)
      {String.downcase(key), String.trim(value)}
    end)
  end

  defp header(headers, name), do: Map.get(headers, String.downcase(name))

  defp poll_until(fun, label) do
    deadline = System.monotonic_time(:millisecond) + @poll_timeout_ms
    do_poll(fun, deadline, label)
  end

  defp do_poll(fun, deadline, label) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for #{label}")
      else
        Process.sleep(25)
        do_poll(fun, deadline, label)
      end
    end
  end

  defp reset_projection_store do
    ForemanServer.TestSupport.ProjectionStoreReset.reset!()
  end

  defp unique_project_id(label) do
    "project-#{label}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end
end
