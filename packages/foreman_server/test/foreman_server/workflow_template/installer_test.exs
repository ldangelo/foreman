defmodule ForemanServer.WorkflowTemplate.InstallerTest do
  use ExUnit.Case, async: false

  @template_names ~w(discover assess plan implement implement-trd implement-trd-beads verify release)
  @template_files Enum.map(@template_names, &"#{&1}.yaml")
  @prompt_names ~w(create-pr discover assess implement verify release)
  @prompt_files Enum.map(@prompt_names, &"#{&1}.md")

  test "install/1 copies bundled templates into the workflows directory" do
    home_dir = make_temp_dir!("workflow-installer-home")

    assert {:ok, installed_paths} = WorkflowTemplate.Installer.install(home_dir: home_dir)

    expected_dir = Path.join([home_dir, ".foreman", "workflows"])
    expected_manifest_paths = Enum.map(@template_files, &Path.join(expected_dir, &1))
    expected_prompt_paths = Enum.map(@prompt_files, &Path.join([expected_dir, "prompts", &1]))
    expected_paths = expected_manifest_paths ++ expected_prompt_paths

    assert Enum.sort(installed_paths) == Enum.sort(expected_paths)

    Enum.each(expected_manifest_paths, fn path ->
      assert File.regular?(path)
      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
    end)
  end

  test "fetch_remote/1 downloads templates from the configured remote URL" do
    home_dir = make_temp_dir!("workflow-installer-remote")
    {remote_url, server_pid, listen_socket} = start_template_server()

    Application.put_env(:foreman_server, :workflow_remote_url, remote_url)

    on_exit(fn ->
      Application.delete_env(:foreman_server, :workflow_remote_url)
      close_server(server_pid, listen_socket)
    end)

    assert {:ok, installed_paths} =
             WorkflowTemplate.Installer.fetch_remote(
               home_dir: home_dir,
               retry_attempts: 2,
               retry_delay_ms: 10
             )

    assert Enum.count(installed_paths) == length(@template_files)

    Enum.each(installed_paths, fn path ->
      assert File.regular?(path)
      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
    end)
  end

  test "install/1 falls back to fetch_remote/1 when bundled templates are unavailable" do
    home_dir = make_temp_dir!("workflow-installer-fallback")
    {remote_url, server_pid, listen_socket} = start_template_server()

    Application.put_env(:foreman_server, :workflow_remote_url, remote_url)

    on_exit(fn ->
      Application.delete_env(:foreman_server, :workflow_remote_url)
      close_server(server_pid, listen_socket)
    end)

    missing_source_dir = Path.join(home_dir, "missing-source")

    assert {:ok, installed_paths} =
             WorkflowTemplate.Installer.install(
               home_dir: home_dir,
               source_dir: missing_source_dir,
               retry_attempts: 2,
               retry_delay_ms: 10
             )

    assert Enum.count(installed_paths) == length(@template_files)

    Enum.each(installed_paths, fn path ->
      assert File.regular?(path)
      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
    end)
  end

  defp make_temp_dir!(prefix) do
    directory = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    directory
  end

  defp start_template_server do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)

    responses =
      Map.new(@template_names, fn template_name ->
        filename = "#{template_name}.yaml"
        path = "/templates/#{filename}"
        {path, remote_template_body(template_name)}
      end)

    server_pid = spawn_link(fn -> accept_loop(listen_socket, responses) end)
    {"http://127.0.0.1:#{port}/templates/", server_pid, listen_socket}
  end

  defp accept_loop(listen_socket, responses) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        handle_request(socket, responses)
        accept_loop(listen_socket, responses)

      {:error, :closed} ->
        :ok
    end
  end

  defp handle_request(socket, responses) do
    response =
      case :gen_tcp.recv(socket, 0, 1_000) do
        {:ok, request} ->
          request
          |> request_path()
          |> response_for(responses)

        {:error, _reason} ->
          not_found_response()
      end

    :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
  end

  defp request_path(request) do
    case String.split(request, "\r\n", parts: 2) do
      [request_line | _rest] ->
        case String.split(request_line, " ") do
          ["GET", path, _version] -> path
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp response_for(path, responses) do
    case Map.get(responses, path) do
      nil -> not_found_response()
      body -> ok_response(body)
    end
  end

  defp ok_response(body) do
    "HTTP/1.1 200 OK\r\ncontent-type: text/yaml\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
  end

  defp not_found_response do
    "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
  end

  defp close_server(server_pid, listen_socket) do
    if Port.info(listen_socket) != nil do
      :gen_tcp.close(listen_socket)
    end

    if Process.alive?(server_pid) do
      Process.exit(server_pid, :shutdown)
    end
  end

  defp remote_template_body(template_name) do
    phase_name =
      case template_name do
        "discover" -> "scope-and-explore"
        "assess" -> "impact-analysis"
        "plan" -> "design-and-decompose"
        "implement" -> "code-generation"
        "implement-trd" -> "implement-trd"
        "implement-trd-beads" -> "implement-trd-beads"
        "verify" -> "test-and-validate"
        "release" -> "finalize-and-release"
      end

    report_name = String.upcase(template_name)

    """
    name: #{template_name}
    description: Remote #{template_name} workflow template
    phases:
      - name: #{phase_name}
        prompt: #{template_name}.md
        models:
          default: MiniMax
        maxTurns: 25
        artifact: "{task.projectReportsDir}/#{report_name}_REPORT.md"
        mail:
          onStart: true
          onComplete: true
    """
  end
end
