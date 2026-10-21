defmodule ForemanServerWeb.ProjectRepositoriesTest do
  @moduledoc """
  E12-S2: repository management surfaces. `project.repo.add|remove` are
  operator commands (HTTP `/api/commands`), `GET /api/projects/:id/repositories`
  and the project JSON expose the list, and the gateway runs the impure
  repository checks (realpath, git work tree, remote identity) before dispatch.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ForemanServer.{CommandGateway, ProjectStore}
  alias ForemanServer.MCP.{Policy, ToolError, Tools}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @endpoint ForemanServerWeb.Endpoint
  @token "project-repositories-token"

  setup do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)
    ProjectionStoreReset.reset!()

    root =
      Path.join(System.tmp_dir!(), "e12s2-#{System.unique_integer([:positive])}") |> realpath()

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)
      ProjectionStoreReset.reset!()

      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    primary = git_repo(root, "primary")
    id = "repos-#{System.unique_integer([:positive])}"
    assert {:ok, _} = ProjectStore.save(%{project_id: id, path: primary})

    {:ok, id: id, root: root, primary: primary}
  end

  defp realpath(path) do
    File.mkdir_p!(path)
    {out, 0} = System.cmd("sh", ["-c", "cd \"$1\" && pwd -P", "sh", path])
    File.rm_rf!(path)
    String.trim(out)
  end

  defp git_repo(root, name, remote \\ nil) do
    path = Path.join(root, name)
    File.mkdir_p!(path)
    {_, 0} = System.cmd("git", ["init", "-q", path])
    if remote, do: {_, 0} = System.cmd("git", ["-C", path, "remote", "add", "origin", remote])
    path
  end

  defp post_command(type, payload, status) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> post("/api/commands", %{
      "type" => type,
      "command_id" => "cmd-#{System.unique_integer([:positive])}",
      "payload" => payload
    })
    |> json_response(status)
  end

  defp get_json(path, status) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> get(path)
    |> json_response(status)
  end

  defp add_payload(id, repo_id, path),
    do: %{"project_id" => id, "repo_id" => repo_id, "path" => path, "added_by" => "test"}

  describe "project.repo.add / remove over HTTP" do
    test "add attaches a checkout; list and project JSON show primary first", ctx do
      secondary = git_repo(ctx.root, "api")
      post_command("project.repo.add", add_payload(ctx.id, "api", secondary), 201)

      assert %{"project_id" => id, "repositories" => [main, api]} =
               get_json("/api/projects/#{ctx.id}/repositories", 200)

      assert id == ctx.id
      assert %{"id" => "main", "primary" => true, "path" => primary} = main
      assert primary == ctx.primary
      assert %{"id" => "api", "path" => ^secondary, "added_by" => "test"} = api

      assert %{"project" => %{"repositories" => [%{"id" => "main"}, %{"id" => "api"}]}} =
               get_json("/api/projects/#{ctx.id}", 200)

      post_command(
        "project.repo.remove",
        %{"project_id" => ctx.id, "repo_id" => "api", "removed_by" => "test"},
        201
      )

      assert %{"repositories" => [%{"id" => "main"}]} =
               get_json("/api/projects/#{ctx.id}/repositories", 200)
    end

    test "unknown project is 404" do
      assert %{"error" => "not_found"} = get_json("/api/projects/nope/repositories", 404)
    end

    test "a path that is not a git work tree is rejected before dispatch", ctx do
      plain = Path.join(ctx.root, "plain")
      File.mkdir_p!(plain)

      assert %{"error" => error} =
               post_command("project.repo.add", add_payload(ctx.id, "plain", plain), 422)

      assert error =~ "repo_not_git_work_tree"

      assert %{"repositories" => [_main]} = get_json("/api/projects/#{ctx.id}/repositories", 200)
    end

    test "a symlink to the primary is rejected as a duplicate path (canonicalised)", ctx do
      link = Path.join(ctx.root, "alias")
      File.ln_s!(ctx.primary, link)

      assert %{"error" => error} =
               post_command("project.repo.add", add_payload(ctx.id, "alias", link), 422)

      assert error =~ "repo_path_duplicate"
    end

    test "the canonical path, not the symlink, is stored", ctx do
      target = git_repo(ctx.root, "real")
      link = Path.join(ctx.root, "link")
      File.ln_s!(target, link)

      post_command("project.repo.add", add_payload(ctx.id, "linked", link), 201)

      assert %{"repositories" => [_, %{"path" => ^target}]} =
               get_json("/api/projects/#{ctx.id}/repositories", 200)
    end

    test "a second checkout of the same origin is rejected as a remote duplicate", ctx do
      first = git_repo(ctx.root, "one", "git@github.com:Org/Repo.git")
      second = git_repo(ctx.root, "two", "https://github.com/org/repo")

      post_command("project.repo.add", add_payload(ctx.id, "one", first), 201)

      assert %{"error" => error} =
               post_command("project.repo.add", add_payload(ctx.id, "two", second), 422)

      assert error =~ "repo_remote_duplicate"
    end

    test "removing the primary is refused", ctx do
      assert %{"error" => error} =
               post_command(
                 "project.repo.remove",
                 %{"project_id" => ctx.id, "repo_id" => "main", "removed_by" => "t"},
                 422
               )

      assert error =~ "primary_repo_not_removable"
    end
  end

  describe "project.update carrying a changed path" do
    test "is validated like repo.add and dispatched canonical", ctx do
      moved = git_repo(ctx.root, "moved")
      link = Path.join(ctx.root, "moved-link")
      File.ln_s!(moved, link)

      post_command("project.update", %{"project_id" => ctx.id, "path" => link}, 201)

      assert %{"repositories" => [%{"id" => "main", "path" => ^moved}]} =
               get_json("/api/projects/#{ctx.id}/repositories", 200)
    end

    test "a non-git path is rejected", ctx do
      plain = Path.join(ctx.root, "plain")
      File.mkdir_p!(plain)

      assert %{"error" => error} =
               post_command("project.update", %{"project_id" => ctx.id, "path" => plain}, 422)

      assert error =~ "repo_not_git_work_tree"
    end

    test "a path equal to an attached extra is rejected as duplicate", ctx do
      secondary = git_repo(ctx.root, "api")
      post_command("project.repo.add", add_payload(ctx.id, "api", secondary), 201)

      assert %{"error" => error} =
               post_command("project.update", %{"project_id" => ctx.id, "path" => secondary}, 422)

      assert error =~ "repo_path_duplicate"
    end

    test "after a path change the aggregate compares against the NEW primary", ctx do
      moved = git_repo(ctx.root, "moved")
      post_command("project.update", %{"project_id" => ctx.id, "path" => moved}, 201)

      assert %{"error" => error} =
               post_command("project.repo.add", add_payload(ctx.id, "again", moved), 422)

      assert error =~ "repo_path_duplicate"

      # the OLD primary path is free again
      post_command("project.repo.add", add_payload(ctx.id, "old", ctx.primary), 201)
    end

    test "an unchanged path is not re-probed", ctx do
      post_command(
        "project.update",
        %{"project_id" => ctx.id, "path" => ctx.primary, "goal" => "g"},
        201
      )
    end
  end

  describe "repo_allowlist / max_repos_per_run normaliser" do
    defp update(id, payload) do
      CommandGateway.dispatch_operator(%{
        command_id: "u-#{System.unique_integer([:positive])}",
        aggregate_id: "project:#{id}",
        type: "project.update",
        payload: Map.put(payload, :project_id, id)
      })
    end

    test "stores a normalised allowlist and a cap", %{id: id} do
      assert {:ok, _} =
               update(id, %{repo_allowlist: ["/srv/repos/", "/work"], max_repos_per_run: 3})

      assert %{
               "settings" => %{
                 "repo_allowlist" => ["/srv/repos", "/work"],
                 "max_repos_per_run" => 3
               }
             } =
               get_json("/api/projects/#{id}/settings", 200)
    end

    test "rejects relative, dotdot and bare-root entries with distinct errors", %{id: id} do
      for bad <- ["relative/path", "/srv/../etc", "/"] do
        assert {:error, {:invalid_repo_allowlist, ^bad}} =
                 update(id, %{repo_allowlist: ["/ok", bad]})
      end

      assert {:error, {:invalid_repo_allowlist, "nope"}} = update(id, %{repo_allowlist: "nope"})
    end

    test "rejects a non-positive cap", %{id: id} do
      assert {:error, {:max_repos_per_run_invalid, 0, _}} = update(id, %{max_repos_per_run: 0})

      assert {:error, {:max_repos_per_run_invalid, "x", _}} =
               update(id, %{max_repos_per_run: "x"})
    end

    test "default cap is 4" do
      assert ForemanServer.Aggregates.Project.Settings.default_max_repos_per_run() == 4
    end
  end

  describe "authorization" do
    test "repo.add is not reachable by the agent/system-facing MCP surface", ctx do
      secondary = git_repo(ctx.root, "api")
      previous = Application.get_env(:foreman_server, :mcp, [])

      Application.put_env(
        :foreman_server,
        :mcp,
        Keyword.put(previous, :allow_workflow_writes, true)
      )

      on_exit(fn -> Application.put_env(:foreman_server, :mcp, previous) end)

      names = Policy.list_tools(Tools.list_tools()) |> Enum.map(& &1.name)
      refute Enum.any?(names, &(&1 =~ "repo_add" or &1 =~ "repo_remove"))

      assert {:error, %ToolError{code: "METHOD_NOT_FOUND"}} =
               Tools.call_tool("foreman_project_repo_add", %{project_id: ctx.id, path: secondary})

      # settings_update cannot smuggle policy or a path in
      assert {:ok, _} =
               Tools.call_tool("foreman_project_settings_update", %{
                 project_id: ctx.id,
                 goal: "x",
                 repo_allowlist: ["/"],
                 path: secondary
               })
               |> then(fn
                 {:error, %ToolError{code: "INVALID_PARAMS"}} -> {:ok, :rejected}
                 other -> other
               end)

      assert %{"settings" => %{"repo_allowlist" => nil}} =
               get_json("/api/projects/#{ctx.id}/settings", 200)
    end

    test "repo commands are refused for types outside the operator allowlist" do
      assert {:error, {:command_not_allowed, "project.repo.bogus"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "x",
                 aggregate_id: "project:p",
                 type: "project.repo.bogus",
                 payload: %{project_id: "p"}
               })
    end
  end

  describe "foreman_project_repo_list MCP tool" do
    test "lists repositories read-only, even with writes disabled", ctx do
      secondary = git_repo(ctx.root, "api")
      post_command("project.repo.add", add_payload(ctx.id, "api", secondary), 201)

      assert Enum.any?(
               Policy.list_tools(Tools.list_tools()),
               &(&1.name == "foreman_project_repo_list")
             )

      assert {:ok,
              %{
                "project_id" => id,
                "repositories" => [%{"id" => "main", "primary" => true}, %{"id" => "api"}]
              }} =
               Tools.call_tool("foreman_project_repo_list", %{project_id: ctx.id})

      assert id == ctx.id
    end

    test "unknown project is NOT_FOUND" do
      assert {:error, %ToolError{code: "NOT_FOUND"}} =
               Tools.call_tool("foreman_project_repo_list", %{project_id: "nope"})
    end
  end
end
