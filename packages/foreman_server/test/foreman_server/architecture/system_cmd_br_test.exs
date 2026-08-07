defmodule ForemanServer.Architecture.SystemCmdBrTest do
  @moduledoc """
  TRD-031 architecture test: ensures no `System.cmd("br", ...)` calls exist in
  `lib/foreman_server/` source code. The moduledoc reference in
  `system_br_runner.ex` is a comment string, not a code call.

  Invariant: `SystemBrRunner` is the sole sheller for `br` invocations, and it
  uses `Port.open` for SIGTERM/SIGKILL escalation + temp-file cleanup. Any
  direct `System.cmd("br", ...)` call elsewhere would bypass timeout, temp-file
  cleanup, and shell-quoting invariants.
  """
  use ExUnit.Case, async: true

  @lib_root "lib/foreman_server"

  test "AST scan detects System.cmd(\"br\", ...) calls" do
    source = """
    defmodule Foo do
      def run do
        System.cmd("br", ["ready", "--json"])
      end
    end
    """

    {_ast, hits} =
      source
      |> Code.string_to_quoted!(lines: true, columns: true)
      |> Macro.prewalk([], &collect_system_cmd_br/2)

    assert hits == [3], "expected collector to detect fixture call at line 3, got #{inspect(hits)}"
  end

  test "no System.cmd(\"br\", ...) calls in lib/foreman_server/" do
    files =
      Path.wildcard(Path.join([@lib_root, "**", "*.ex"]))
      |> Enum.reject(&String.contains?(&1, "_build/"))

    offenders =
      Enum.flat_map(files, fn file ->
        source = File.read!(file)

        {_ast, hits} =
          source
          |> Code.string_to_quoted!(lines: true, columns: true)
          |> Macro.prewalk([], &collect_system_cmd_br/2)

        Enum.map(Enum.reverse(hits), fn line_no ->
          {Path.relative_to_cwd(file), line_no}
        end)
      end)

    assert offenders == [],
           "Unexpected System.cmd(\"br\", ...) calls:\n" <>
             Enum.map_join(offenders, "\n", fn {f, l} -> "  - #{f}:#{l}" end)
  end

  defp collect_system_cmd_br(node, acc) do
    if system_cmd_br_call?(node) do
      {node, [line_of(node) | acc]}
    else
      {node, acc}
    end
  end

  defp system_cmd_br_call?({{:., _, [{:__aliases__, _, [:System]}, :cmd]}, _, args}) do
    first_arg_is_br?(args)
  end

  defp system_cmd_br_call?(_), do: false

  defp first_arg_is_br?([first | _]) when is_binary(first) do
    String.starts_with?(first, "br")
  end

  defp first_arg_is_br?(_), do: false

  defp line_of({_, meta, _}) when is_list(meta), do: meta[:line] || 0
  defp line_of(_), do: 0
end
