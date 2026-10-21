defmodule ForemanServer.MCP.ToolsProjectLibraryTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.{CommandRouter, Library}
  alias ForemanServer.MCP.{Policy, ToolError, Tools}

  @tools ["foreman_project_library_list", "foreman_project_library_read"]

  setup %{tmp_dir: dir} do
    on_exit(fn -> System.cmd("chmod", ["-R", "u+w", dir]) end)
    original = Application.get_env(:foreman_server, :mcp, [])
    on_exit(fn -> Application.put_env(:foreman_server, :mcp, original) end)

    project_id = "mcp-lib-#{System.unique_integer([:positive])}"
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        aggregate_id: "project:#{project_id}",
        payload: %{project_id: project_id, path: repo}
      })

    src = Path.join(dir, "src")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "spec.md"), "# Spec")
    File.write!(Path.join(src, "blob.bin"), <<0, 255, 254, 1>>)

    {:ok, %{entry: entry}} =
      Library.add(project_id, {:folder, src}, %{name: "specs"}, %{kind: :operator, ref: "op"})

    {:ok, project_id: project_id, entry_id: entry.entry_id}
  end

  test "both tools are read tools: advertised even when workflow writes are disabled" do
    Application.put_env(:foreman_server, :mcp, allow_workflow_writes: false)
    names = Tools.list_tools() |> Policy.list_tools() |> Enum.map(& &1.name)
    assert @tools -- names == []
  end

  test "there is no MCP tool that adds, replaces or removes library files" do
    names = Enum.map(Tools.list_tools(), & &1.name)

    assert Enum.filter(names, &String.starts_with?(&1, "foreman_project_library")) |> Enum.sort() ==
             @tools
  end

  test "list returns entries with files and the index", %{project_id: p, entry_id: id} do
    assert {:ok, %{project_id: ^p, index: index, entries: [entry]}} =
             Tools.call_tool("foreman_project_library_list", %{project_id: p})

    assert entry.entry_id == id
    assert entry.name == "specs"
    assert entry.kind == "folder"
    assert Enum.map(entry.files, & &1.path) == ["blob.bin", "spec.md"]
    assert entry.read_path == "$FOREMAN_LIBRARY_PATH/#{id}/files/"
    assert index =~ "spec.md"
  end

  test "read returns utf8 text and base64 for binary files", %{project_id: p, entry_id: id} do
    assert {:ok, %{encoding: "utf8", content: "# Spec", bytes: 6}} =
             Tools.call_tool("foreman_project_library_read", %{
               project_id: p,
               entry_id: id,
               path: "spec.md"
             })

    assert {:ok, %{encoding: "base64", content: content, bytes: 4}} =
             Tools.call_tool("foreman_project_library_read", %{
               project_id: p,
               entry_id: id,
               path: "blob.bin"
             })

    assert Base.decode64!(content) == <<0, 255, 254, 1>>
  end

  test "typed errors map to tool errors", %{project_id: p, entry_id: id} do
    assert {:error, %ToolError{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_project_library_list", %{project_id: "nope"})

    assert {:error, %ToolError{code: "NOT_FOUND"}} =
             Tools.call_tool("foreman_project_library_read", %{
               project_id: p,
               entry_id: id,
               path: "missing.md"
             })

    assert {:error, %ToolError{code: "INVALID_PARAMS"}} =
             Tools.call_tool("foreman_project_library_read", %{
               project_id: p,
               entry_id: id,
               path: "../entry.json"
             })
  end
end
