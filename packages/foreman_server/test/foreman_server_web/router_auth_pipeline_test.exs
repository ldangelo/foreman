defmodule ForemanServerWeb.RouterAuthPipelineTest do
  use ExUnit.Case, async: true

  @router_file Path.expand("../../lib/foreman_server_web/router.ex", __DIR__)
  @project_routes [
    {"GET", "/api/projects"},
    {"GET", "/api/projects/:id"}
  ]

  test "project routes stay behind session or bearer auth plugs" do
    source = File.read!(@router_file)
    ast = Code.string_to_quoted!(source, lines: true, columns: true)
    pipelines = pipeline_plugs(ast)
    routes = collect_routes(ast, [], "")

    for route <- @project_routes do
      effective_pipelines = route_pipeline_names(routes, route)

      assert effective_pipelines != [],
             "expected #{elem(route, 0)} #{elem(route, 1)} to have at least one pipeline"

      effective_plugs =
        effective_pipelines
        |> Enum.flat_map(&Map.get(pipelines, &1, []))
        |> Enum.uniq()

      assert Enum.any?(effective_plugs, &auth_plug?/1),
             "expected #{elem(route, 0)} #{elem(route, 1)} pipelines #{inspect(effective_pipelines)} " <>
               "to include :fetch_session or BearerAuth, got plugs #{inspect(effective_plugs)}"
    end
  end

  defp pipeline_plugs(ast) do
    {_ast, pipelines} =
      Macro.prewalk(ast, %{}, fn
        {:pipeline, _, [name, [do: body]]} = node, acc ->
          {node, Map.put(acc, name, pipeline_body_plugs(body))}

        node, acc ->
          {node, acc}
      end)

    pipelines
  end

  defp pipeline_body_plugs(body) do
    {_body, plugs} =
      Macro.prewalk(body, [], fn
        {:plug, _, [plug]} = node, acc -> {node, [normalize_plug(plug) | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(plugs)
  end

  defp collect_routes({:defmodule, _, [_name, [do: body]]}, pipelines, prefix),
    do: collect_routes(body, pipelines, prefix)

  defp collect_routes({:scope, _, args}, pipelines, prefix) do
    {scope_path, body} = scope_parts(args)
    collect_scope_body(body, pipelines, prefix <> scope_path)
  end

  defp collect_routes({verb, _, [route_path, _controller, _action]}, pipelines, prefix)
       when verb in [:get, :post, :put, :patch, :delete] and is_binary(route_path) do
    [{String.upcase(to_string(verb)), prefix <> route_path, pipelines}]
  end

  defp collect_routes({:__block__, _, expressions}, pipelines, prefix) when is_list(expressions),
    do: collect_scope_body(expressions, pipelines, prefix)

  defp collect_routes(_ast, _pipelines, _prefix), do: []

  defp collect_scope_body({:__block__, _, expressions}, pipelines, prefix)
       when is_list(expressions),
       do: collect_scope_body(expressions, pipelines, prefix)

  defp collect_scope_body(expressions, pipelines, prefix) when is_list(expressions) do
    {routes, _pipelines} =
      Enum.map_reduce(expressions, pipelines, fn
        {:pipe_through, _, [names]}, current_pipelines when is_list(names) ->
          {[], merge_pipelines(current_pipelines, names)}

        {:pipe_through, _, [name]}, current_pipelines when is_atom(name) ->
          {[], merge_pipelines(current_pipelines, [name])}

        expression, current_pipelines ->
          {collect_routes(expression, current_pipelines, prefix), current_pipelines}
      end)

    List.flatten(routes)
  end

  defp collect_scope_body(expression, pipelines, prefix),
    do: collect_routes(expression, pipelines, prefix)

  defp merge_pipelines(left, right), do: Enum.uniq(left ++ right)

  defp route_pipeline_names(routes, {verb, path}) do
    Enum.find_value(routes, [], fn
      {^verb, ^path, pipelines} -> pipelines
      _ -> false
    end)
  end

  defp scope_parts([path, _alias, [do: body]]) when is_binary(path), do: {path, body}
  defp scope_parts([path, [do: body]]) when is_binary(path), do: {path, body}

  defp auth_plug?(:fetch_session), do: true
  defp auth_plug?(:BearerAuth), do: true
  defp auth_plug?({:alias, :BearerAuth}), do: true
  defp auth_plug?(_), do: false

  defp normalize_plug(atom) when is_atom(atom), do: atom

  defp normalize_plug({:__aliases__, _, parts}) when is_list(parts),
    do: {:alias, List.last(parts)}

  defp normalize_plug(other), do: other
end
