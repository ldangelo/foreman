defmodule ForemanServer.Architecture.AliasBoundaryTest do
  use ExUnit.Case, async: true

  @lib_root Path.expand("../../../lib/foreman_server", __DIR__)
  @allowed_root Path.join(@lib_root, "task_providers")
  @positive_control_file Path.join(@allowed_root, "beads_adapter.ex")

  test "TaskProviders adapter aliases remain inside lib/foreman_server/task_providers" do
    files = elixir_files(@lib_root)
    assert files != [], "No lib files found under #{@lib_root}"

    offenders = forbidden_alias_sites(files)

    assert offenders == [],
           "Unexpected TaskProviders adapter aliases outside lib/foreman_server/task_providers:\n" <>
             format_hits(offenders)
  end

  test "scanner finds in-directory adapter aliases and excludes them from violations" do
    assert File.regular?(@positive_control_file),
           "Expected positive control file #{@positive_control_file} to exist"

    allowed_hits = find_adapter_aliases(@positive_control_file)

    positive_control =
      {Path.relative_to_cwd(@positive_control_file), 6,
       "ForemanServer.TaskProviders.BeadsAdapter.CodeMap"}

    assert allowed_hits != [],
           "Expected at least one allowed adapter alias in #{Path.relative_to_cwd(@positive_control_file)}"

    assert positive_control in allowed_hits,
           "Expected scanner to find #{elem(positive_control, 2)} at #{elem(positive_control, 0)}:#{elem(positive_control, 1)}"

    assert forbidden_alias_sites([@positive_control_file]) == []
  end

  defp forbidden_alias_sites(files) do
    files
    |> Enum.reject(&allowed_task_providers_file?/1)
    |> Enum.flat_map(&find_adapter_aliases/1)
  end

  defp find_adapter_aliases(file) do
    source = File.read!(file)

    {_ast, hits} =
      source
      |> Code.string_to_quoted!(lines: true, columns: true)
      |> Macro.prewalk([], &collect_adapter_aliases/2)

    Enum.map(Enum.reverse(hits), fn {line, module_name} ->
      {Path.relative_to_cwd(file), line, module_name}
    end)
  end

  defp collect_adapter_aliases({:alias, meta, [target | _]} = node, acc) do
    line = meta[:line] || 0

    new_hits =
      target
      |> expand_alias_target()
      |> Enum.reduce([], fn parts, hits ->
        if adapter_alias_parts?(parts) do
          [{line, parts |> Module.concat() |> inspect()} | hits]
        else
          hits
        end
      end)

    {node, Enum.reverse(new_hits, acc)}
  end

  defp collect_adapter_aliases(node, acc), do: {node, acc}

  defp expand_alias_target({:__aliases__, _, parts}) when is_list(parts), do: [parts]

  defp expand_alias_target({{:., _, [prefix, :{}]}, _, nested_aliases})
       when is_list(nested_aliases) do
    prefix_parts = alias_parts(prefix)

    Enum.flat_map(nested_aliases, fn nested_alias ->
      case alias_parts(nested_alias) do
        [] -> []
        nested_parts -> [prefix_parts ++ nested_parts]
      end
    end)
  end

  defp expand_alias_target(_target), do: []

  defp alias_parts({:__aliases__, _, parts}) when is_list(parts), do: parts
  defp alias_parts(_target), do: []

  defp adapter_alias_parts?([:ForemanServer, :TaskProviders | segments]) do
    Enum.any?(segments, &adapter_segment?/1)
  end

  defp adapter_alias_parts?(_parts), do: false

  defp adapter_segment?(segment) when is_atom(segment) do
    segment
    |> Atom.to_string()
    |> String.ends_with?("Adapter")
  end

  defp adapter_segment?(_segment), do: false

  defp allowed_task_providers_file?(file) do
    expanded_file = Path.expand(file)
    expanded_allowed_root = Path.expand(@allowed_root)

    String.starts_with?(expanded_file, expanded_allowed_root <> "/")
  end

  defp elixir_files(root) do
    root
    |> descend_files()
    |> Enum.filter(&(Path.extname(&1) == ".ex"))
  end

  defp descend_files(path) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(fn entry ->
          child = Path.join(path, entry)

          cond do
            File.dir?(child) -> descend_files(child)
            File.regular?(child) -> [child]
            true -> []
          end
        end)

      {:error, reason} ->
        raise "Unable to list #{path}: #{inspect(reason)}"
    end
  end

  defp format_hits(hits) do
    hits
    |> Enum.map_join("\n", fn {file, line, module_name} ->
      "- #{file}:#{line} (#{module_name})"
    end)
  end
end
