defmodule ForemanServerWeb.EventStoreWebEnforcementTest do
  use ExUnit.Case, async: true

  @controllers_glob Path.expand("../../lib/foreman_server_web/controllers/*.ex", __DIR__)

  @moduledoc """
  Architecture enforcement for the Phoenix web layer.

  Controller modules may read projections and may send operator commands through
  `ForemanServer.CommandGateway.dispatch_operator/2`, but they must not reach
  into EventStore, CommandRouter append internals, or server-only recovery
  modules.
  """

  test "controller files do not bypass the web-layer CQRS boundary" do
    offenders =
      controller_files()
      |> Enum.flat_map(&forbidden_call_sites/1)

    assert offenders == [], format_offenders(offenders)
  end

  test "controller scan includes the new ProjectController file" do
    assert "project_controller.ex" in Enum.map(controller_files(), &Path.basename/1)
  end

  test "CommandGateway.dispatch_operator/2 remains the sole allowed write path from controllers" do
    hits =
      call_sites(fn node ->
        call_to?(node, :CommandGateway, :dispatch_operator)
      end)

    assert Enum.any?(hits, fn {basename, _file, _line} -> basename == "command_controller.ex" end),
           "expected controller scan to observe CommandGateway.dispatch_operator/2 in command_controller.ex"
  end

  test "controllers do not import or alias RunLifecycleReconciler" do
    offenders =
      reference_sites(fn node ->
        module_reference_to?(node, :RunLifecycleReconciler)
      end)

    assert offenders == [], format_offenders(offenders)
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

      {_ast, hits} =
        Code.string_to_quoted!(source, lines: true, columns: true)
        |> Macro.prewalk(
          [],
          &collect_matches(&1, &2, fn node -> call_to?(node, :EventStore, :append_to_stream) end)
        )

      assert hits != []
    end

    test "detects forbidden CommandRouter.append_* call" do
      source = """
      defmodule Foo do
        alias ForemanServer.CommandRouter

        def go(events) do
          CommandRouter.append_events("task:1", 0, events)
        end
      end
      """

      {_ast, hits} =
        Code.string_to_quoted!(source, lines: true, columns: true)
        |> Macro.prewalk(
          [],
          &collect_matches(&1, &2, fn node ->
            call_to_with_prefix?(node, :CommandRouter, "append")
          end)
        )

      assert hits != []
    end

    test "detects forbidden RunLifecycleReconciler import" do
      source = """
      defmodule Foo do
        alias ForemanServer.RunLifecycleReconciler
      end
      """

      {_ast, hits} =
        Code.string_to_quoted!(source, lines: true, columns: true)
        |> Macro.prewalk(
          [],
          &collect_matches(&1, &2, fn node ->
            module_reference_to?(node, :RunLifecycleReconciler)
          end)
        )

      assert hits != []
    end

    test "sees the allowed CommandGateway.dispatch_operator/2 path" do
      source = """
      defmodule Foo do
        alias ForemanServer.CommandGateway

        def go(command) do
          CommandGateway.dispatch_operator(command)
        end
      end
      """

      {_ast, hits} =
        Code.string_to_quoted!(source, lines: true, columns: true)
        |> Macro.prewalk(
          [],
          &collect_matches(&1, &2, fn node ->
            call_to?(node, :CommandGateway, :dispatch_operator)
          end)
        )

      assert hits != []
    end
  end

  defp controller_files do
    Path.wildcard(@controllers_glob)
  end

  defp forbidden_call_sites(file) do
    find_matches(file, fn node ->
      call_to?(node, :EventStore, :append_to_stream) or
        call_to_with_prefix?(node, :CommandRouter, "append") or
        call_to?(node, :RunLifecycleReconciler, :retry_run_start) or
        call_to_module?(node, [:EventStore, :Adapter])
    end)
  end

  defp call_sites(predicate) do
    controller_files()
    |> Enum.flat_map(&find_matches(&1, predicate))
  end

  defp reference_sites(predicate) do
    controller_files()
    |> Enum.flat_map(&find_matches(&1, predicate))
  end

  defp find_matches(file, predicate) do
    basename = Path.basename(file)

    case File.read(file) do
      {:ok, source} ->
        {_ast, hits} =
          Code.string_to_quoted!(source, lines: true, columns: true)
          |> Macro.prewalk([], &collect_matches(&1, &2, predicate))

        Enum.map(hits, fn line -> {basename, file, line} end)

      {:error, _} ->
        []
    end
  end

  defp collect_matches(node, acc, predicate) do
    if predicate.(node) do
      {node, [line_of(node) | acc]}
    else
      {node, acc}
    end
  end

  defp call_to?({{:., _, [target, called_function]}, _, _args}, module_atom, function_atom) do
    called_function == function_atom and
      (target == module_atom or last_alias(target) == module_atom)
  end

  defp call_to?(_node, _module_atom, _function_atom), do: false

  defp call_to_with_prefix?({{:., _, [target, function_atom]}, _, _args}, module_atom, prefix)
       when is_atom(function_atom) do
    String.starts_with?(Atom.to_string(function_atom), prefix) and
      (target == module_atom or last_alias(target) == module_atom)
  end

  defp call_to_with_prefix?(_node, _module_atom, _prefix), do: false

  defp call_to_module?({{:., _, [target, _function_atom]}, _, _args}, parts) do
    alias_parts(target) == parts
  end

  defp call_to_module?(_node, _parts), do: false

  defp module_reference_to?({kind, _, [target | _rest]}, module_atom)
       when kind in [:alias, :import, :require, :use] do
    last_alias(target) == module_atom
  end

  defp module_reference_to?(_node, _module_atom), do: false

  defp alias_parts({:__aliases__, _, parts}) when is_list(parts), do: parts
  defp alias_parts(_), do: []

  defp last_alias({:__aliases__, _, parts}) when is_list(parts), do: List.last(parts)
  defp last_alias(_), do: nil

  defp line_of(node) do
    case node do
      {_, meta, _} when is_list(meta) -> meta[:line] || 0
      _ -> 0
    end
  end

  defp format_offenders(offenders) do
    offenders
    |> Enum.map(fn {basename, file, line} ->
      "forbidden web-layer CQRS bypass in #{file}:#{line} (#{basename})"
    end)
    |> Enum.join("\n")
  end
end
