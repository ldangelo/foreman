defmodule ForemanServer.CommandAllowlistParityTest do
  @moduledoc """
  `ForemanServer.CommandGateway` and `ForemanServerWeb.CommandController` each keep
  an operator command allowlist. They drifted apart before (a type reachable over
  HTTP but refused by the gateway, or the reverse). Module attributes are not
  readable at runtime, so the sets are read back from each module's source (the
  attribute definitions are `~w` lists, `++` and one `PrWatch.operator_types()`
  call) and then cross-checked against how each module actually behaves, so the
  extraction itself cannot silently drift from the code.

  The one documented difference: `inbox.send` is a gateway command with its own
  HTTP endpoint, so it is deliberately not in the controller's list.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint ForemanServerWeb.Endpoint

  alias ForemanServer.Aggregates.Run.PrWatch
  alias ForemanServer.CommandGateway
  alias ForemanServerWeb.CommandController

  @gateway_only ["inbox.send"]
  @list_attributes [:allowed_operator_types, :allowed_types, :pr_operator_types]

  @main_types ~w(project.register project.update project.environment.set project.archive
                 project.reactivate project.pause project.resume project.adopt task.create
                 task.approve task.retry task.update run.cancel run.pause run.resume run.remove
                 run.reset run.steer merge_approve run.pr.merge thread.resolve thread.reopen
                 coordinator.message coordinator.restart schedule.create schedule.update
                 schedule.pause schedule.resume schedule.delete)

  # -- reading an allowlist out of a module's source ----------------------------

  defp allowlist(module, attribute) do
    source = module.module_info(:compile)[:source] |> to_string()
    {:ok, ast} = source |> File.read!() |> Code.string_to_quoted()
    {:defmodule, _, [_name, [do: {:__block__, _, body}]]} = ast

    env =
      Enum.reduce(body, %{}, fn
        {:@, _, [{name, _, [value]}]}, env when name in @list_attributes ->
          Map.put(env, name, eval(value, env))

        _other, env ->
          env
      end)

    Map.fetch!(env, attribute)
  end

  defp eval({:sigil_w, _, [{:<<>>, _, [words]}, _modifiers]}, _env), do: String.split(words)
  defp eval({:++, _, [left, right]}, env), do: eval(left, env) ++ eval(right, env)
  defp eval({:@, _, [{name, _, nil}]}, env), do: Map.fetch!(env, name)

  defp eval({{:., _, [{:__aliases__, _, parts}, function]}, _, []}, _env),
    do: apply(Module.concat(parts), function, [])

  defp gateway_types, do: allowlist(CommandGateway, :allowed_operator_types)
  defp controller_types, do: allowlist(CommandController, :allowed_types)

  # -- the parity check ----------------------------------------------------------

  @doc false
  def drift(gateway, controller, gateway_only) do
    %{
      missing_in_controller: (gateway -- controller) -- gateway_only,
      missing_in_gateway: controller -- gateway,
      exempt_but_present_in_controller: Enum.filter(gateway_only, &(&1 in controller))
    }
  end

  @no_drift %{
    missing_in_controller: [],
    missing_in_gateway: [],
    exempt_but_present_in_controller: []
  }

  test "the two allowlists carry the same operator commands" do
    assert drift(gateway_types(), controller_types(), @gateway_only) == @no_drift
  end

  test "both carry every command main had plus the E9 operator PR commands" do
    pr = PrWatch.operator_types()
    refute Enum.empty?(pr)

    assert (@main_types ++ pr) -- gateway_types() == []
    assert (@main_types ++ pr) -- controller_types() == []
  end

  test "the parity check fails for a type in one list only, and for a drifted PR command" do
    gateway = gateway_types()
    controller = controller_types()

    assert %{missing_in_controller: ["run.pr.fake"]} =
             drift(["run.pr.fake" | gateway], controller, @gateway_only)

    assert %{missing_in_gateway: ["run.pr.fake"]} =
             drift(gateway, ["run.pr.fake" | controller], @gateway_only)

    dropped = hd(PrWatch.operator_types())

    assert %{missing_in_controller: [^dropped]} =
             drift(gateway, List.delete(controller, dropped), @gateway_only)

    # the exemption covers exactly the named type, and goes stale if the controller grows it
    assert %{exempt_but_present_in_controller: ["inbox.send"]} =
             drift(gateway, ["inbox.send" | controller], @gateway_only)
  end

  # -- the extracted sets match the modules' behaviour ---------------------------

  defmodule RecordingGateway do
    @moduledoc false
    def dispatch_operator(command) do
      send(Application.fetch_env!(:foreman_server, :allowlist_probe_pid), {:dispatched, command})
      {:ok, nil}
    end
  end

  # Types addressed by `run:<run_id>`, so one payload shape probes every one of them
  # without touching a store: merge gate, run commands and the E9 PR commands.
  defp probe_types do
    run_types = Enum.filter(@main_types, &String.starts_with?(&1, "run.")) ++ ["merge_approve"]
    Enum.uniq(run_types ++ PrWatch.operator_types() ++ ["run.pr.fake"])
  end

  test "CommandGateway accepts exactly the types its extracted allowlist names" do
    allowed = gateway_types()

    for type <- probe_types() do
      result =
        CommandGateway.dispatch_operator(%{
          command_id: "probe-#{type}",
          type: type,
          aggregate_id: "run:probe",
          payload: %{}
        })

      if type in allowed do
        # past the allowlist, rejected for the missing run id before any dispatch
        assert {:error, {:invalid_envelope, :missing_run_id}} = result, type
      else
        assert {:error, {:command_not_allowed, ^type}} = result
      end
    end
  end

  test "CommandController accepts exactly the types its extracted allowlist names" do
    allowed = controller_types()
    Application.put_env(:foreman_server, :command_gateway_module, RecordingGateway)
    Application.put_env(:foreman_server, :allowlist_probe_pid, self())

    on_exit(fn ->
      Application.delete_env(:foreman_server, :command_gateway_module)
      Application.delete_env(:foreman_server, :allowlist_probe_pid)
    end)

    for type <- probe_types() do
      conn =
        post(build_conn(), "/api/commands", %{"type" => type, "payload" => %{"run_id" => "r1"}})

      if type in allowed do
        assert json_response(conn, 201), type
        assert_received {:dispatched, %{type: ^type, aggregate_id: "run:r1"}}
      else
        assert %{"error" => "invalid_envelope"} = json_response(conn, 400)
        refute_received {:dispatched, _}
      end
    end
  end
end
