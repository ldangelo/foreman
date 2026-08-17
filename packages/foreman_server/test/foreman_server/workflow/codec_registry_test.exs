defmodule ForemanServer.Workflow.CodecRegistryTest do
  use ExUnit.Case, async: false

  alias ForemanServer.EventCodec
  alias ForemanServer.Events.ProjectRunReserved

  @server_glob Path.expand("../../../lib/foreman_server/**/*.ex", __DIR__)
  @web_glob Path.expand("../../../lib/foreman_server_web/**/*.ex", __DIR__)
  @allowed_dispatch_run_start_callers ["run_admission.ex"]

  describe "EventCodec registry" do
    test "reconstructs ProjectRunReserved from a JSON-shaped map" do
      payload = %{
        "project_id" => "project-1",
        "run_id" => "run-1",
        "sequence" => 7,
        "command_id" => "workflow:run-1:start",
        "run_start_payload" => %{
          "project_id" => "project-1",
          "run_id" => "run-1",
          "task_id" => "task-1"
        },
        "implementation_key" => "impl-1"
      }

      assert %ProjectRunReserved{} = decoded = EventCodec.decode!("ProjectRunReserved", payload)
      assert decoded.project_id == "project-1"
      assert decoded.run_id == "run-1"
      assert decoded.sequence == 7
      assert decoded.command_id == "workflow:run-1:start"
      assert decoded.run_start_payload == %{
               "project_id" => "project-1",
               "run_id" => "run-1",
               "task_id" => "task-1"
             }
      assert decoded.implementation_key == "impl-1"
    end

    test "rejects RunCompleted events missing project_id" do
      assert_raise ArgumentError,
                   ~r/EventCodec: event_type=\"RunCompleted\" missing enforced keys: \[:project_id\]/,
                   fn ->
                     EventCodec.decode!("RunCompleted", %{"run_id" => "run-1", "sequence" => 3})
                   end
    end

    test "registers the run completion codec contract used by booted workflow services" do
      assert "ProjectRunReserved" in EventCodec.registered()
      assert "ProjectRunReservationReleased" in EventCodec.registered()
      assert "RunCompleted" in EventCodec.registered()
      assert "RunFailed" in EventCodec.registered()
      assert "RunBlocked" in EventCodec.registered()
      assert "RunFlaggedStuck" in EventCodec.registered()
    end
  end

  describe "application boot wiring" do
    test "supervision tree includes RunLifecycleReconciler on boot" do
      assert is_pid(Process.whereis(ForemanServer.RunLifecycleReconciler))

      child_ids =
        ForemanServer.Application
        |> Supervisor.which_children()
        |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

      assert ForemanServer.RunLifecycleReconciler in child_ids
    end
  end

  describe "run-start facade boundary" do
    test "server code only dispatches run.start through RunAdmission" do
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

    test "web layer does not call RunAdmission.start/2 or /3 directly" do
      offenders =
        source_files(@web_glob)
        |> Enum.flat_map(&find_matches(&1, fn node -> call_to?(node, :RunAdmission, :start) end))

      assert offenders == [],
             format_offenders(offenders, "forbidden web-layer RunAdmission.start/2 call")
    end

    test "workflow dispatcher enters run admission through the public facade only" do
      dispatcher = Path.expand("../../../lib/foreman_server/workflow/dispatcher.ex", __DIR__)

      run_admission_hits =
        find_matches(dispatcher, fn node ->
          call_to?(node, :RunAdmission, :start)
        end)

      direct_dispatch_hits =
        find_matches(dispatcher, fn node ->
          call_to?(node, :CommandRouter, :dispatch_run_start)
        end)

      assert run_admission_hits != []
      assert direct_dispatch_hits == []
    end

    test "allowlists RunAdmission as the single dispatch_run_start seam" do
      run_admission = Path.expand("../../../lib/foreman_server/run_admission.ex", __DIR__)

      hits =
        find_matches(run_admission, fn node ->
          call_to?(node, :CommandRouter, :dispatch_run_start)
        end)

      assert Path.basename(run_admission) in @allowed_dispatch_run_start_callers
      assert hits != []
    end

    test "AST walker flags a direct CommandRouter.dispatch_run_start/3 bypass" do
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

    test "AST walker flags a web-facing RunAdmission.start/2 bypass" do
      source = """
      defmodule ForemanServerWeb.FooController do
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

  defp source_files(glob), do: Path.wildcard(glob)

  defp find_matches(file, predicate) do
    basename = Path.basename(file)

    case File.read(file) do
      {:ok, source} ->
        {_ast, hits} =
          source
          |> Code.string_to_quoted!(lines: true, columns: true)
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

  defp format_offenders(offenders, prefix) do
    offenders
    |> Enum.map(fn {basename, file, line} -> "#{prefix} in #{file}:#{line} (#{basename})" end)
    |> Enum.join("\n")
  end
end
