defmodule ForemanServer.WorkflowTemplate.InstallerTest do
  use ExUnit.Case, async: false

  # Discovered from the real bundled directory rather than hand-maintained —
  # a hardcoded list here would silently drift from `priv/defaults/workflows`
  # exactly like the production defect this file's sibling module fixed
  # (`ForemanServer.WorkflowTemplate.Installer` §5.5).
  @bundled_source_dir Path.join([__DIR__, "..", "..", "..", "priv", "defaults", "workflows"])
  @template_files @bundled_source_dir
                  |> File.ls!()
                  |> Enum.filter(&String.ends_with?(&1, ".yaml"))
                  |> Enum.sort()
  @template_names Enum.map(@template_files, &Path.basename(&1, ".yaml"))
  @prompt_files @bundled_source_dir
                |> Path.join("prompts")
                |> File.ls!()
                |> Enum.sort()

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

  test "fetch_remote/1 downloads templates and prompts from the configured remote URL" do
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

    assert Enum.count(installed_paths) == length(@template_files) + length(@prompt_files)

    manifest_paths = Enum.filter(installed_paths, &String.ends_with?(&1, ".yaml"))
    prompt_paths = Enum.filter(installed_paths, &String.ends_with?(&1, ".md"))

    assert length(manifest_paths) == length(@template_files)
    assert length(prompt_paths) == length(@prompt_files)

    Enum.each(manifest_paths, fn path ->
      assert File.regular?(path)
      assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
    end)

    Enum.each(prompt_paths, fn path ->
      assert File.regular?(path)
      assert path =~ ~r{/prompts/[^/]+\.md$}
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

    assert Enum.count(installed_paths) == length(@template_files) + length(@prompt_files)

    Enum.each(installed_paths, fn path ->
      assert File.regular?(path)

      if String.ends_with?(path, ".yaml") do
        assert {:ok, _workflow} = Workflow.Interpreter.load!(path)
      end
    end)
  end

  describe "remove_all/1" do
    alias ForemanServer.WorkflowTemplate.Installer

    # Every manifest/prompt name Foreman shipped historically that is not
    # bundled now (git log --all over priv/defaults/workflows + src/defaults/workflows).
    @legacy_workflows ~w(bug chore default discover docs epic feature implement medium plan
      pr-review-workflow question quick release small smoke task tdd trd verify)
    @legacy_prompts ~w(create-pr plan)

    test "legacy sets are exactly shipped-before minus bundled-now" do
      assert Installer.legacy_workflow_names() == Enum.sort(@legacy_workflows)
      assert Installer.legacy_prompt_names() == Enum.sort(@legacy_prompts)

      bundled_prompts = Enum.map(@prompt_files, &Path.rootname/1)
      assert Installer.bundled_workflow_names() == Enum.sort(@template_names)
      assert Installer.bundled_prompt_names() == Enum.sort(bundled_prompts)

      assert Installer.legacy_workflow_names() -- @template_names ==
               Installer.legacy_workflow_names()

      assert Installer.legacy_prompt_names() -- bundled_prompts == Installer.legacy_prompt_names()
      assert "assess" in @template_names
      refute "assess" in Installer.legacy_workflow_names()
    end

    test "removes every legacy manifest and prompt, keeps bundled files and custom files" do
      {home_dir, dir} = seeded_workflows_dir!()
      before = snapshot(dir)

      legacy_paths =
        Enum.map(@legacy_workflows, &Path.join(dir, "#{&1}.yaml")) ++
          Enum.map(@legacy_prompts, &Path.join([dir, "prompts", "#{&1}.md"]))

      assert {:ok, %{removed: removed, absent: absent}} = Installer.remove_all(home_dir: home_dir)

      assert Enum.sort(removed) == Enum.sort(legacy_paths)
      assert absent == []
      refute Enum.any?(legacy_paths, &File.exists?/1)
      assert snapshot(dir) == Map.drop(before, legacy_paths)

      # bundled (assess included) and operator-authored files survive
      for file <- @template_files, do: assert(File.exists?(Path.join(dir, file)))
      for file <- @prompt_files, do: assert(File.exists?(Path.join([dir, "prompts", file])))
      assert File.read!(Path.join(dir, "custom.yaml")) == "name: custom\n"
      assert File.read!(Path.join([dir, "prompts", "custom.md"])) == "mine\n"
    end

    test "bundled workflows stay loadable after removal" do
      {home_dir, dir} = seeded_workflows_dir!()
      assert {:ok, _} = Installer.remove_all(home_dir: home_dir)

      for file <- @template_files do
        assert {:ok, _workflow} = ForemanServer.Workflow.Interpreter.load!(Path.join(dir, file))
      end
    end

    test "is idempotent and reports absent legacy paths" do
      {_home_dir, dir} = seeded_workflows_dir!()

      assert {:ok, %{removed: [_ | _]}} = Installer.remove_all(target_dir: dir)
      assert {:ok, %{removed: [], absent: absent}} = Installer.remove_all(target_dir: dir)

      assert length(absent) ==
               length(Installer.legacy_workflow_names()) +
                 length(Installer.legacy_prompt_names())
    end

    test "an empty or missing target is not an error" do
      home_dir = make_temp_dir!("workflow-installer-remove-empty")

      assert {:ok, %{removed: []}} = Installer.remove_all(home_dir: home_dir)

      dir = Path.join(home_dir, "bare")
      File.mkdir_p!(dir)
      assert {:ok, %{removed: []}} = Installer.remove_all(target_dir: dir)
    end
  end

  # An upgraded install: the bundled set, every legacy manifest/prompt, and
  # operator-authored files `remove_all/1` must never touch.
  defp seeded_workflows_dir! do
    home_dir = make_temp_dir!("workflow-installer-remove")
    {:ok, _} = ForemanServer.WorkflowTemplate.Installer.install(home_dir: home_dir)
    dir = Path.join([home_dir, ".foreman", "workflows"])
    File.mkdir_p!(Path.join(dir, "prompts"))

    for name <- ForemanServer.WorkflowTemplate.Installer.legacy_workflow_names() do
      File.write!(Path.join(dir, "#{name}.yaml"), "name: #{name}\n")
    end

    for name <- ForemanServer.WorkflowTemplate.Installer.legacy_prompt_names() do
      File.write!(Path.join([dir, "prompts", "#{name}.md"]), "prompt #{name}\n")
    end

    File.write!(Path.join(dir, "custom.yaml"), "name: custom\n")
    File.write!(Path.join([dir, "prompts", "custom.md"]), "mine\n")
    {home_dir, dir}
  end

  defp snapshot(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{&1, File.read!(&1)})
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

    manifest_responses =
      Map.new(@template_names, fn template_name ->
        filename = "#{template_name}.yaml"
        path = "/templates/#{filename}"
        {path, remote_template_body(template_name)}
      end)

    prompt_responses =
      Map.new(@prompt_files, fn filename ->
        path = "/templates/prompts/#{filename}"
        body = File.read!(Path.join([@bundled_source_dir, "prompts", filename]))
        {path, body}
      end)

    responses = Map.merge(manifest_responses, prompt_responses)

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
    report_name = template_name |> String.replace("-", "_") |> String.upcase()

    """
    name: #{template_name}
    description: Remote #{template_name} workflow template
    phases:
      - name: run-workflow
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
