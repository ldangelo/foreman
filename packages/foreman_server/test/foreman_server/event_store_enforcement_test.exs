defmodule ForemanServer.EventStore.EnforcementTest do
  use ExUnit.Case, async: true

  @lib_root "lib/foreman_server"

  # Per-needle allow list. Each call type may ONLY originate from the
  # module listed below — everything else routes through CommandGateway.
  @allowed_for_append ["command_router.ex"]
  @allowed_for_dispatch ["command_gateway.ex"]

  @moduledoc """
  Architecture enforcement.

  The sole writer to `EventStore.append_to_stream/4` is
  `ForemanServer.CommandRouter.append_events/3`. The sole caller of
  `CommandRouter.dispatch/2` outside `CommandRouter` itself is
  `ForemanServer.CommandGateway`. Every mutation that touches the event
  log MUST go through CommandGateway → CommandRouter.

  These tests parse each `.ex` source file under `lib/foreman_server/`
  with `Code.string_to_quoted!/2` (which discards comments) and walk
  the AST looking for the relevant call nodes. Files in the per-needle
  allow list are skipped.
  """

  test "no module outside CommandRouter calls EventStore.append_to_stream" do
    offenders = call_sites(:EventStore, :append_to_stream, @allowed_for_append)

    Enum.each(offenders, fn {basename, file, line} ->
      flunk(
        "Direct EventStore.append_to_stream call in #{file}:#{line} " <>
          "(#{basename}). Route through ForemanServer.CommandRouter."
      )
    end)
  end

  test "no module outside CommandGateway calls CommandRouter.dispatch" do
    offenders = call_sites(:CommandRouter, :dispatch, @allowed_for_dispatch)

    Enum.each(offenders, fn {basename, file, line} ->
      flunk(
        "Direct CommandRouter.dispatch in #{file}:#{line} " <>
          "(#{basename}). Route through ForemanServer.CommandGateway.dispatch_system/2."
      )
    end)
  end

  describe "AST walker self-test" do
    test "detects forbidden EventStore.append_to_stream call" do
      source = """
      defmodule Foo do
        def go(stream) do
          EventStore.append_to_stream(stream, 0, [])
        end
      end
      """

      assert {_ast, hits} =
               source
               |> Code.string_to_quoted!(lines: true, columns: true)
               |> Macro.prewalk([], &collect_calls(&1, &2, :EventStore, :append_to_stream))

      assert hits != [],
             "Walker should have detected the EventStore.append_to_stream call"

      assert Enum.all?(hits, &is_integer/1),
             "Walker hits should be line numbers, got #{inspect(hits)}"
    end

    test "detects forbidden CommandRouter.dispatch call" do
      source = """
      defmodule Foo do
        alias ForemanServer.CommandRouter

        def go do
          CommandRouter.dispatch(%{aggregate_id: "task:abc", type: "x"})
        end
      end
      """

      {_ast, hits} =
        Code.string_to_quoted!(source, lines: true, columns: true)
        |> Macro.prewalk([], &collect_calls(&1, &2, :CommandRouter, :dispatch))

      assert hits != [],
             "Walker should have detected the CommandRouter.dispatch call"
    end

    test "detects fully-qualified ForemanServer.CommandRouter.dispatch" do
      source = """
      defmodule Foo do
        def go do
          ForemanServer.CommandRouter.dispatch(%{type: "x"})
        end
      end
      """

      {_ast, hits} =
        Code.string_to_quoted!(source, lines: true, columns: true)
        |> Macro.prewalk([], &collect_calls(&1, &2, :CommandRouter, :dispatch))

      assert hits != [],
             "Walker should detect the fully-qualified ForemanServer.CommandRouter.dispatch call"
    end

    test "ignores call that only mentions the module name in a comment" do
      source = """
      defmodule Foo do
        # ForemanServer.CommandRouter.dispatch should be ignored here
        def go, do: :ok
      end
      """

      {_ast, hits} =
        Code.string_to_quoted!(source, lines: true, columns: true)
        |> Macro.prewalk([], &collect_calls(&1, &2, :CommandRouter, :dispatch))

      assert hits == [],
             "Comments should not be flagged (got #{inspect(hits)})"
    end
  end

  # ------------------------------------------------------------------
  # AST walker
  # ------------------------------------------------------------------

  # Walks every .ex file under `lib/foreman_server/`, parses each, and
  # returns a list of `{basename, file, line}` for every AST node that
  # is a real call to `Module.function(...)` matching the needle. Files
  # in `allowed` are skipped. Comments are stripped by
  # `Code.string_to_quoted!/2` so doc-comments are not flagged.
  defp call_sites(module_atom, function_atom, allowed) do
    Path.wildcard(Path.join([@lib_root, "**", "*.ex"]))
    |> Enum.flat_map(fn file ->
      basename = Path.basename(file)

      if basename in allowed do
        []
      else
        find_calls(file, module_atom, function_atom, basename)
      end
    end)
  end

  defp find_calls(file, module_atom, function_atom, basename) do
    case File.read(file) do
      {:ok, source} ->
        {_ast, hits} =
          source
          |> Code.string_to_quoted!(lines: true, columns: true)
          |> Macro.prewalk([], &collect_calls(&1, &2, module_atom, function_atom))

        Enum.map(hits, fn meta -> {basename, file, meta} end)

      {:error, _} ->
        []
    end
  end

  # Must return `{node, new_acc}` so Macro.prewalk can keep traversing
  # the AST with the (possibly rewritten) node. Acc: list of line numbers
  # (or `0` if unknown) for every match.
  defp collect_calls(node, acc, module_atom, function_atom) do
    if call_to?(node, module_atom, function_atom) do
      {node, [line_of(node) | acc]}
    else
      {node, acc}
    end
  end

  # Match `Module.function(...)` where the module may appear as a bare
  # atom (alias) or as an alias chain
  # `{:__aliases__, _, [:ForemanServer, :CommandRouter]}` whose last
  # atom is the needle. No `is_atom` guard — the `__aliases__` shape is
  # what normal `alias`-style calls produce.
  defp call_to?({{:., _, [target, fn_atom]}, _, _args}, module_atom, function_atom) do
    fn_atom == function_atom and (target == module_atom or last_alias(target) == module_atom)
  end

  defp call_to?(_node, _module_atom, _function_atom), do: false

  defp last_alias({:__aliases__, _, parts}) when is_list(parts), do: List.last(parts)
  defp last_alias(_), do: nil

  defp line_of(node) do
    case node do
      {_, meta, _} when is_list(meta) -> meta[:line] || 0
      _ -> 0
    end
  end
end
