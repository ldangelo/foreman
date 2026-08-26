defmodule ForemanServer.AdmissionFacadeEnforcementTest do
  use ExUnit.Case, async: true

  @server_glob Path.expand("../../lib/foreman_server/**/*.ex", __DIR__)
  @web_glob Path.expand("../../lib/foreman_server_web/**/*.ex", __DIR__)
  @allowed_dispatch_run_start_callers ["run_admission.ex"]
  @allowed_run_admission_start_callers ["run_lifecycle_reconciler.ex", "workflow/dispatcher.ex"]

  @moduledoc """
  Architecture enforcement for the run-admission boundary.

  Production code may enter `CommandRouter.dispatch_run_start/3` only through
  `ForemanServer.RunAdmission.start/2`. The Phoenix web layer must not call the
  internal admission facade directly.
  """

  test "only RunAdmission calls CommandRouter.dispatch_run_start/3" do
    offenders =
      source_files(@server_glob)
      |> Enum.flat_map(fn file ->
        basename = Path.basename(file)

        if basename in @allowed_dispatch_run_start_callers do
          []
        else
          find_matches(file, fn node ->
            call_to?(node, :CommandRouter, :dispatch_run_start)
          end)
        end
      end)

    assert offenders == [],
           format_offenders(offenders, "forbidden direct CommandRouter.dispatch_run_start/3")
  end

  test "only allowlisted non-web server files call RunAdmission.start/2 or /3" do
    offenders =
      source_files([@server_glob, @web_glob])
      |> Enum.flat_map(fn file ->
        relative_path = relative_source_path(file)

        if relative_path in @allowed_run_admission_start_callers do
          []
        else
          find_matches(file, fn node -> call_to?(node, :RunAdmission, :start) end)
        end
      end)

    assert offenders == [],
           format_offenders(offenders, "forbidden RunAdmission.start/2 call outside allowlist")
  end

  test "allowlists internal server seams for RunAdmission.start/2 or /3" do
    hits_by_file =
      Enum.map(@allowed_run_admission_start_callers, fn relative_path ->
        file = Path.expand("../../lib/foreman_server/#{relative_path}", __DIR__)

        hits =
          find_matches(file, fn node ->
            call_to?(node, :RunAdmission, :start)
          end)

        {relative_path, hits}
      end)

    assert Enum.all?(hits_by_file, fn {relative_path, hits} ->
             relative_path in @allowed_run_admission_start_callers and hits != []
           end)
  end

  test "allowlists RunAdmission as the single dispatch_run_start seam" do
    run_admission = Path.expand("../../lib/foreman_server/run_admission.ex", __DIR__)

    hits =
      find_matches(run_admission, fn node ->
        call_to?(node, :CommandRouter, :dispatch_run_start)
      end)

    offenders =
      [run_admission]
      |> Enum.flat_map(fn file ->
        basename = Path.basename(file)

        if basename in @allowed_dispatch_run_start_callers do
          []
        else
          find_matches(file, fn node ->
            call_to?(node, :CommandRouter, :dispatch_run_start)
          end)
        end
      end)

    assert Path.basename(run_admission) in @allowed_dispatch_run_start_callers
    assert hits != []
    assert offenders == []
  end

  describe "AST walker self-test" do
    test "detects forbidden CommandRouter.dispatch_run_start/3 call" do
      source = """
      defmodule Foo do
        alias ForemanServer.CommandRouter

        def go(project_id, payload) do
          CommandRouter.dispatch_run_start(project_id, payload, 5_000)
        end
      end
      """

      {_ast, hits} =
        Code.string_to_quoted!(source, lines: true, columns: true)
        |> Macro.prewalk(
          [],
          &collect_matches(&1, &2, fn node ->
            call_to?(node, :CommandRouter, :dispatch_run_start)
          end)
        )

      assert hits != []
    end

    test "detects forbidden RunAdmission.start/2 call" do
      source = """
      defmodule Foo do
        alias ForemanServer.RunAdmission

        def go(project_id, payload) do
          RunAdmission.start(project_id, payload)
        end
      end
      """

      {_ast, hits} =
        Code.string_to_quoted!(source, lines: true, columns: true)
        |> Macro.prewalk(
          [],
          &collect_matches(&1, &2, fn node -> call_to?(node, :RunAdmission, :start) end)
        )

      assert hits != []
    end
  end

  defp source_files(globs) when is_list(globs) do
    globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
  end

  defp source_files(glob) do
    Path.wildcard(glob)
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

  defp last_alias({:__aliases__, _, parts}) when is_list(parts), do: List.last(parts)
  defp last_alias(_), do: nil

  defp line_of(node) do
    case node do
      {_, meta, _} when is_list(meta) -> meta[:line] || 0
      _ -> 0
    end
  end

  defp relative_source_path(file) do
    file
    |> Path.relative_to(Path.expand("../../lib/foreman_server", __DIR__))
  end

  defp format_offenders(offenders, prefix) do
    offenders
    |> Enum.map(fn {basename, file, line} -> "#{prefix} in #{file}:#{line} (#{basename})" end)
    |> Enum.join("\n")
  end
end
