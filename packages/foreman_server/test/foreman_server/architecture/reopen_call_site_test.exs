defmodule ForemanServer.Architecture.ReopenCallSiteTest do
  use ExUnit.Case, async: true

  @lib_root Path.expand("../../../lib/foreman_server", __DIR__)
  @positive_control_file Path.join(@lib_root, "workflow/boot_reconciliation.ex")

  test "BeadsAdapter.reopen/3 call sites remain inside BootReconciliation" do
    files = elixir_files(@lib_root)
    assert files != [], "No lib files found under #{@lib_root}"

    expected_hit = positive_control_signature()

    assert Enum.map(reopen_call_sites(files), &signature/1) == [expected_hit],
           "Unexpected reopen/3 call sites outside BootReconciliation:\n" <>
             format_hits(reopen_call_sites(files))
  end

  test "scanner finds the BootReconciliation reopen/3 positive control" do
    assert File.regular?(@positive_control_file),
           "Expected positive control file #{@positive_control_file} to exist"

    hits = find_reopen_calls(@positive_control_file)

    assert hits != [],
           "Expected at least one reopen/3 call in #{Path.relative_to_cwd(@positive_control_file)}"

    assert signature({Path.relative_to_cwd(@positive_control_file), 0, expected_call_label()})
             in Enum.map(hits, &signature/1),
           "Expected scanner to find a reopen/3 call in #{Path.relative_to_cwd(@positive_control_file)}"
  end

  defp reopen_call_sites(files) do
    files
    |> Enum.flat_map(&find_reopen_calls/1)
  end

  defp find_reopen_calls(file) do
    source = File.read!(file)

    {_ast, hits} =
      source
      |> Code.string_to_quoted!(lines: true, columns: true)
      |> Macro.prewalk([], &collect_reopen_calls/2)

    Enum.map(Enum.reverse(hits), fn {line, receiver} ->
      {Path.relative_to_cwd(file), line, "#{receiver}.reopen/3"}
    end)
  end

  defp collect_reopen_calls({{:., meta, [receiver, :reopen]}, _call_meta, args} = node, acc)
       when is_list(args) and length(args) == 3 do
    line = meta[:line] || 0
    {node, [{line, Macro.to_string(receiver)} | acc]}
  end

  defp collect_reopen_calls(node, acc), do: {node, acc}

  defp positive_control_signature do
    signature(
      {Path.relative_to_cwd(@positive_control_file), 0, expected_call_label()}
    )
  end

  defp signature({file, _line, callsite}), do: {file, callsite}
  defp expected_call_label, do: "provider_module.reopen/3"

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
    |> Enum.map_join("\n", fn {file, line, callsite} ->
      "- #{file}:#{line} (#{callsite})"
    end)
  end
end
