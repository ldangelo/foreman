defmodule ForemanServer.Integration.ProjectReadRoutesTest do
  @moduledoc """
  Live-server smoke test for the project read routes.

  Must be run with the application started (`mix test`, not `--no-start`).
  """

  use ExUnit.Case, async: false

  alias ForemanServerWeb.Endpoint

  @token "project-read-routes-test-token"
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

    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      %{state | projects: %{}, runs: %{}, project_active_runs: %{}}
    end)

    ref = String.to_atom("project-read-routes-#{System.unique_integer([:positive])}")

    start_supervised!({
      Plug.Cowboy,
      scheme: :http, plug: Endpoint, options: [ip: {127, 0, 0, 1}, port: 0, ref: ref]
    })

    base_url = "http://127.0.0.1:#{:ranch.get_port(ref)}"

    on_exit(fn ->
      :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
        %{state | projects: %{}, runs: %{}, project_active_runs: %{}}
      end)

      if previous_token == nil do
        Application.delete_env(:foreman_server, :api_bearer_token)
      else
        Application.put_env(:foreman_server, :api_bearer_token, previous_token)
      end

      Application.put_env(:foreman_server, Endpoint, previous_endpoint_config)
    end)

    {:ok, base_url: base_url}
  end

  test "GET /api/projects and GET /api/projects/:id satisfy the live-server smoke contract", %{
    base_url: base_url
  } do
    project_id = unique_project_id()

    assert {:ok, 200, empty_list_body, empty_list_headers} =
             request(:get, base_url <> "/api/projects", authorized_headers())

    assert empty_list_body == %{"projects" => [], "meta" => %{"truncated" => false}}
    assert header(empty_list_headers, "x-total-count") == "0"

    register_payload = %{
      "type" => "project.register",
      "payload" => %{
        "project_id" => project_id,
        "path" => "/tmp/#{project_id}",
        "name" => "Smoke Project",
        "task_provider" => %{
          "provider" => "beads",
          "config" => %{"database_path" => "/tmp/demo.db"}
        }
      }
    }

    assert {:ok, 201, register_body, _register_headers} =
             request(:post, base_url <> "/api/commands", authorized_headers(), register_payload)

    assert register_body == %{
             "status" => "accepted",
             "result" => %{"project_id" => project_id}
           }

    poll_until(
      fn ->
        case request(:get, base_url <> "/api/projects/#{project_id}", authorized_headers()) do
          {:ok, 200, %{"project" => %{"project_id" => ^project_id} = project}, _headers} ->
            project["path"] == "/tmp/#{project_id}" and project["name"] == "Smoke Project"

          _ ->
            false
        end
      end,
      "registered project to appear on GET /api/projects/:id"
    )

    assert {:ok, 200, show_body, _show_headers} =
             request(:get, base_url <> "/api/projects/#{project_id}", authorized_headers())

    show_project = show_body["project"]

    assert show_project["project_id"] == project_id
    assert show_project["task_provider"]["provider"] == "beads"
    assert show_project["version"] == 1
    assert show_project["registered"] == show_project["registered_at"]
    assert {:ok, _, 0} = DateTime.from_iso8601(show_project["registered_at"])

    poll_until(
      fn ->
        case request(:get, base_url <> "/api/projects", authorized_headers()) do
          {:ok, 200, %{"projects" => projects}, headers} ->
            header(headers, "x-total-count") == "1" and
              Enum.any?(projects, fn project ->
                project["project_id"] == project_id and
                  project["version"] == 1 and
                  project["registered_at"] == show_project["registered_at"] and
                  project["registered"] == show_project["registered"]
              end)

          _ ->
            false
        end
      end,
      "registered project to appear on GET /api/projects"
    )

    assert {:ok, 404, not_found_body, _headers} =
             request(
               :get,
               base_url <> "/api/projects/#{unique_project_id()}",
               authorized_headers()
             )

    assert not_found_body == %{"error" => "not_found", "reason" => ":project_not_found"}

    assert {:ok, 401, unauthorized_body, _headers} = request(:get, base_url <> "/api/projects")
    assert unauthorized_body == %{"error" => "unauthorized"}
  end

  defp request(method, url, headers \\ [], json_body \\ nil)

  defp request(:get, url, headers, nil) do
    request_raw("GET", url, headers, "")
  end

  defp request(:post, url, headers, json_body) when is_map(json_body) do
    request_raw(
      "POST",
      url,
      [{"content-type", "application/json"} | headers],
      Jason.encode!(json_body)
    )
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

    {:ok, String.to_integer(status_code), decode_json(body), decode_headers(header_lines)}
  end

  defp request_path(%URI{path: nil, query: nil}), do: "/"
  defp request_path(%URI{path: path, query: nil}) when is_binary(path) and path != "", do: path
  defp request_path(%URI{path: nil, query: query}), do: "/?" <> query

  defp request_path(%URI{path: path, query: query}) when is_binary(query),
    do: path <> "?" <> query

  defp request_path(%URI{path: ""}), do: "/"

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

  defp decode_json(body) when is_binary(body), do: Jason.decode!(body)
  defp decode_json(body), do: body

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

  defp unique_project_id do
    "project-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end
end
