defmodule ForemanServerWeb.RouterAuthPipelineTest do
  use ExUnit.Case, async: true

  @router_file Path.expand("../../lib/foreman_server_web/router.ex", __DIR__)

  test "project read routes stay under the BearerAuth-backed :api pipeline" do
    source = File.read!(@router_file)
    ast = Code.string_to_quoted!(source, lines: true, columns: true)

    assert api_pipeline_includes_bearer_auth?(ast)

    assert api_scope_route?(ast, "/projects", :index),
           "expected GET /api/projects to remain inside the /api scope with pipe_through(:api)"

    assert api_scope_route?(ast, "/projects/:id", :show),
           "expected GET /api/projects/:id to remain inside the /api scope with pipe_through(:api)"
  end

  defp api_pipeline_includes_bearer_auth?(ast) do
    ast
    |> pipeline_bodies(:api)
    |> Enum.any?(fn body ->
      contains_call?(body, fn
        {:plug, _, [target]} -> last_alias(target) == :BearerAuth
        _ -> false
      end)
    end)
  end

  defp api_scope_route?(ast, route_path, action) do
    ast
    |> api_scope_bodies()
    |> Enum.any?(fn body ->
      has_api_pipe_through?(body) and contains_project_route?(body, route_path, action)
    end)
  end

  defp pipeline_bodies(ast, name) do
    {_ast, bodies} =
      Macro.prewalk(ast, [], fn
        {:pipeline, _, [^name, [do: body]]} = node, acc -> {node, [body | acc]}
        node, acc -> {node, acc}
      end)

    bodies
  end

  defp api_scope_bodies(ast) do
    {_ast, bodies} =
      Macro.prewalk(ast, [], fn
        {:scope, _, ["/api", _alias, [do: body]]} = node, acc -> {node, [body | acc]}
        {:scope, _, ["/api", [do: body]]} = node, acc -> {node, [body | acc]}
        node, acc -> {node, acc}
      end)

    bodies
  end

  defp has_api_pipe_through?(ast) do
    contains_call?(ast, fn
      {:pipe_through, _, [:api]} -> true
      {:pipe_through, _, [pipelines]} when is_list(pipelines) -> :api in pipelines
      _ -> false
    end)
  end

  defp contains_project_route?(ast, route_path, action) do
    contains_call?(ast, fn
      {:get, _, [^route_path, target, ^action]} -> last_alias(target) == :ProjectController
      _ -> false
    end)
  end

  defp contains_call?(ast, predicate) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? ->
        {node, found? or predicate.(node)}
      end)

    found?
  end

  defp last_alias({:__aliases__, _, parts}) when is_list(parts), do: List.last(parts)
  defp last_alias(_), do: nil
end
