defmodule ForemanServer.TaskProviders.BeadsAdapterCodeMapFactoryTest do
  use ExUnit.Case, async: true

  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap
  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap.ProviderErrorInput
  alias ForemanServer.TaskProviders.ProviderError

  @lib_root Path.expand("../../../lib/foreman_server", __DIR__)
  @allowed_factory_file Path.join(@lib_root, "task_providers/beads_adapter_code_map.ex")

  test "build_provider_error/3 is the only ProviderError construction site" do
    offenders = provider_error_construction_sites()

    assert offenders == [],
           "Unexpected %ProviderError{} constructions:\n" <> format_offenders(offenders)
  end

  test "factory itself constructs ProviderError correctly" do
    assert %ProviderError{code: "NOT_CLAIMABLE", retryable?: false} =
             CodeMap.build_provider_error(
               ProviderErrorInput.from_local(
                 :NOT_CLAIMABLE,
                 "Issue cannot be claimed.",
                 "Ask the current assignee to release it before retrying.",
                 false
               ),
               nil,
               0
             )
  end

  test "factory is reachable from CodeMap module" do
    assert Code.ensure_loaded?(CodeMap)
    assert function_exported?(CodeMap, :build_provider_error, 3)
  end

  defp provider_error_construction_sites do
    files = Path.wildcard(Path.join([@lib_root, "**", "*.ex"]))
    assert files != [], "No lib files found under #{@lib_root}"

    files
    |> Enum.reject(&(Path.expand(&1) == Path.expand(@allowed_factory_file)))
    |> Enum.flat_map(&find_provider_error_literals/1)
  end

  defp find_provider_error_literals(file) do
    source = File.read!(file)

    {_ast, hits} =
      source
      |> Code.string_to_quoted!(lines: true, columns: true)
      |> Macro.prewalk([], &collect_provider_error_literals/2)

    Enum.map(Enum.reverse(hits), fn line ->
      {Path.relative_to_cwd(file), line}
    end)
  end

  defp collect_provider_error_literals(node, acc) do
    if provider_error_struct_literal?(node) do
      {node, [line_of(node) | acc]}
    else
      {node, acc}
    end
  end

  defp provider_error_struct_literal?({:%, _, [target, {:%{}, _, _}]}) do
    target == :ProviderError or last_alias(target) == :ProviderError
  end

  defp provider_error_struct_literal?(_node), do: false

  defp last_alias({:__aliases__, _, parts}) when is_list(parts), do: List.last(parts)
  defp last_alias(_), do: nil

  defp line_of({_, meta, _}) when is_list(meta), do: meta[:line] || 0
  defp line_of(_), do: 0

  defp format_offenders(offenders) do
    offenders
    |> Enum.map_join("\n", fn {file, line} -> "- #{file}:#{line}" end)
  end
end
