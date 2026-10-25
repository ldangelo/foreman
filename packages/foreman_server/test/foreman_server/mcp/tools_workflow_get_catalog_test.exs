defmodule ForemanServer.MCP.ToolsWorkflowGetCatalogTest do
  @moduledoc """
  `foreman_workflow_get` is read against a REAL `Workflow.Catalog` on real manifest files
  (foreman-qimsa). `Catalog.load/1` returns the resolved, atom-keyed workflow; the tool used to
  read string keys from it, so `description`, `digest` and `phases` were empty and
  `phase_count` was 0 for every real workflow. The hand-built string-keyed mock in
  `ToolsWorkflowTest` could not see that, which is why this file builds no mock.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Tools
  alias ForemanServer.Workflow.{AssetCatalog, Catalog}

  @moduletag :tmp_dir

  @described """
  name: described
  description: Builds the thing, then reviews it.
  worktree:
    enabled: true
    cleanup: never
  phases:
    - name: build
      command: "/skill:build {{input.prompt}}"
    - name: review
      prompt: review.md
      provider: pi
  """

  @bare "name: bare\nphases:\n  - name: only\n    command: /skill:x\n"

  setup %{tmp_dir: tmp} do
    prev_poll = Application.get_env(:foreman_server, :workflow_catalog_poll_ms)
    Application.put_env(:foreman_server, :workflow_catalog_poll_ms, 600_000)

    server_name = :"tools_workflow_get_catalog_test_#{System.unique_integer([:positive])}"
    prev_server = Application.get_env(:foreman_server, :workflow_catalog)
    Application.put_env(:foreman_server, :workflow_catalog, server_name)

    on_exit(fn ->
      if prev_server,
        do: Application.put_env(:foreman_server, :workflow_catalog, prev_server),
        else: Application.delete_env(:foreman_server, :workflow_catalog)

      if prev_poll,
        do: Application.put_env(:foreman_server, :workflow_catalog_poll_ms, prev_poll),
        else: Application.delete_env(:foreman_server, :workflow_catalog_poll_ms)
    end)

    File.mkdir_p!(Path.join(tmp, "prompts"))
    File.write!(Path.join([tmp, "prompts", "review.md"]), "Review the change.\n")
    File.write!(Path.join(tmp, "described.yaml"), @described)
    File.write!(Path.join(tmp, "bare.yaml"), @bare)

    start_supervised!({Catalog, name: server_name, catalog: AssetCatalog.new(tmp)},
      id: server_name
    )

    :ok
  end

  test "answers the loaded workflow's description, digest, phase count and phases" do
    assert {:ok, %{} = loaded} = Catalog.load("described.yaml")
    assert {:ok, result} = Tools.call_tool("foreman_workflow_get", %{name: "described"})

    assert result.name == "described"
    assert result.description == "Builds the thing, then reviews it."
    assert result.manifest_path == "workflows/described.yaml"

    # What the catalog resolved, not a string-keyed look-alike of it.
    assert result.description == loaded.description
    assert result.digest == loaded.digest
    assert is_binary(result.digest) and result.digest != ""
    assert result.phase_count == length(loaded.phases)
    assert result.phase_count == 2

    # The phases the manifest DECLARES: no catalog-derived atom keys (`:prompt_path`,
    # `:action`, nil-padded copies of undeclared fields).
    assert result.phases == [
             %{"name" => "build", "command" => "/skill:build {{input.prompt}}"},
             %{"name" => "review", "prompt" => "review.md", "provider" => "pi"}
           ]
  end

  test "the tool output is what an MCP client receives: JSON, one key per field" do
    assert {:ok, result} = Tools.call_tool("foreman_workflow_get", %{name: "described"})
    json = Jason.encode!(result)

    assert %{
             "name" => "described",
             "description" => "Builds the thing, then reviews it.",
             "phase_count" => 2,
             "digest" => digest,
             "phases" => [%{"name" => "build"}, %{"name" => "review"}]
           } = Jason.decode!(json)

    assert digest != ""
    # The catalog's resolved phase also carries `:command` beside the manifest's `"command"`:
    # encoding both would put the key in the payload twice.
    assert length(String.split(json, ~s("command":))) == 2
    refute json =~ "prompt_path"
  end

  test "a workflow that declares no description answers empty strings, not nil" do
    assert {:ok, %{description: nil, digest: nil}} = Catalog.load("bare.yaml")
    assert {:ok, result} = Tools.call_tool("foreman_workflow_get", %{name: "bare"})

    assert result.description == ""
    assert result.digest == ""
    assert result.phase_count == 1
    assert [%{"name" => "only"}] = result.phases
  end
end
