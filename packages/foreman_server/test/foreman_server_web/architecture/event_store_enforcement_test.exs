defmodule ForemanServerWeb.Architecture.EventStoreEnforcementTest do
  use ExUnit.Case, async: true

  @controllers_glob Path.expand("../../../lib/foreman_server_web/**/*controller*.ex", __DIR__)

  test "controllers do not call EventStore.append_to_stream directly" do
    files = controller_files()
    assert files != [], "No controller files found matching #{@controllers_glob}"

    offenders = Enum.flat_map(files, &direct_append_calls/1)

    assert offenders == [], format_offenders(offenders)
  end

  test "AST walker detects a direct EventStore.append_to_stream call" do
    source = """
    defmodule ForemanServerWeb.SampleController do
      def create(stream_uuid) do
        EventStore.append_to_stream(stream_uuid, 0, [])
      end
    end
    """

    assert direct_append_hits(source) == [3]
  end

  defp controller_files do
    Path.wildcard(@controllers_glob)
  end

  defp direct_append_calls(file) do
    source = File.read!(file)
    ast = Code.string_to_quoted!(source, columns: true)

    ensure_modules_loaded!(file, ast)

    {_ast, hits} =
      Macro.prewalk(ast, [], &collect_direct_append_calls/2)

    relative = Path.relative_to_cwd(file)
    Enum.map(Enum.reverse(hits), fn line -> {relative, line} end)
  end

  defp direct_append_hits(source) do
    ast = Code.string_to_quoted!(source, columns: true)

    {_ast, hits} =
      Macro.prewalk(ast, [], &collect_direct_append_calls/2)

    Enum.reverse(hits)
  end

  defp ensure_modules_loaded!(file, ast) do
    ast
    |> defined_modules()
    |> Enum.each(fn module ->
      case Code.ensure_loaded(module) do
        true -> :ok
        {:module, ^module} -> :ok
        other -> flunk("expected #{inspect(module)} from #{file} to load, got: #{inspect(other)}")
      end
    end)
  end

  defp defined_modules(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [module_ast | _]} = node, acc ->
          case expand_module_name(module_ast) do
            nil -> {node, acc}
            module -> {node, [module | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    modules
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp expand_module_name({:__aliases__, _, parts}) when is_list(parts), do: Module.concat(parts)
  defp expand_module_name(_module_ast), do: nil

  defp collect_direct_append_calls(
         {{:., meta, [target, :append_to_stream]}, _call_meta, _args} = node,
         acc
       ) do
    if target == :EventStore or last_alias(target) == :EventStore do
      {node, [meta[:line] || 0 | acc]}
    else
      {node, acc}
    end
  end

  defp collect_direct_append_calls(node, acc), do: {node, acc}

  defp last_alias({:__aliases__, _, parts}) when is_list(parts), do: List.last(parts)
  defp last_alias(_target), do: nil

  defp format_offenders(offenders) do
    offenders
    |> Enum.map(fn {file, line} ->
      "controller must not call EventStore.append_to_stream directly: #{file}:#{line}"
    end)
    |> Enum.join("\n")
  end
end
