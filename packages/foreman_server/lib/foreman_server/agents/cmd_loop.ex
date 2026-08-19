defmodule ForemanServer.Agents.CmdLoop do
  @moduledoc """
  Foreman-side cmd/2 loop implementation that delegates to Jido.Agent.cmd/3.
  Returns updated agent struct + directives as `{:ok, updated, directives}`.

  TRD-2026-4212be7e / JCR-T003 / TRD-005.
  """
  require Logger

  alias Jido.Agent
  alias Jido.Agent.Directive
  alias Jido.Signal.Bus
  alias Jido.Signal.Dispatch

  # ─────────────────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────────────────

  @doc """
  Applies an action to the agent and returns the updated agent with any
  generated directives.

  ## Arguments
    - `agent` — a `Jido.Agent.t()` struct (or any `use Jido.Agent` generated module)
    - `action` — either a bare action module or `{{module, params}}`
    - `params` — a map of parameters for the action (converted internally)

  ## Returns
    `{:ok, updated_agent, directives :: [directive()]}`
  """
  @spec call(Jido.Agent.t(), module(), map()) ::
          {:ok, Jido.Agent.t(), [Directive.t()]}
          | {:error, term()}
  def call(agent, action_module, params) when is_map(params) do
    # Agent.new/1 returns {:ok, %Agent{}}; Agent.cmd/3 requires bare %Agent{}.
    agent_struct = unwrap_agent(agent)
    normalized = normalize_action(action_module, params)
    opts = params_to_opts(params)

    {updated, directives} = agent_struct.agent_module.cmd(agent_struct, normalized, opts)
    {:ok, updated, directives}
  end

  @doc """
  Applies an action, dispatches all directives, and returns the directive count.

  ## Returns
    `{:ok, updated_agent, directive_count :: non_neg_integer()}` on success
    `{:error, reason}` on failure
  """
  @spec apply_and_dispatch(Jido.Agent.t(), module(), map() | nil) ::
          {:ok, Jido.Agent.t(), non_neg_integer()}
          | {:error, term()}
  def apply_and_dispatch(agent, action_module, params \\ %{})

  def apply_and_dispatch(agent, action_module, params) when is_map(params) do
    case call(agent, action_module, params) do
      {:ok, updated, directives} ->
        _ = Enum.each(directives, &dispatch_directive/1)
        {:ok, updated, length(directives)}

      {:error, _reason} = error ->
        error
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Private helpers
  # ─────────────────────────────────────────────────────────────────────────

  # Normalise the action into the form Agent.cmd/3 expects:
  #   bare atom + empty params  → bare atom (Agent.cmd/3 uses schema defaults)
  #   bare atom + non-empty map  → {module, params}
  #   already a tuple            → pass through (params already embedded)
  defp normalize_action(action_module, params) when is_atom(action_module) do
    if map_size(params) == 0 do
      action_module
    else
      {action_module, params}
    end
  end

  defp normalize_action({_module, _embedded_params} = action_tuple, _extra_params) do
    action_tuple
  end

  # Unwrap {:ok, %Agent{}} from Agent.new/1 so Agent.cmd/3 receives bare struct.
  defp unwrap_agent({:ok, %Agent{} = agent}), do: agent
  defp unwrap_agent(%Agent{} = agent), do: agent
  # An empty map becomes [] so Agent.cmd/3 uses bare-module → default-params.
  defp params_to_opts(%{}), do: []
  
  # Directive dispatch
  # AgentServer executes directives via the DirectiveExec protocol; CmdLoop
  # handles the same directives outside the AgentServer GenServer context.
  # We delegate to Jido.Signal.Dispatch for Emit and handle the rest directly.

  defp dispatch_directive(%Directive.Emit{signal: signal, dispatch: dispatch}) do
    cfg = dispatch || default_dispatch_config()
    _ = Dispatch.dispatch(signal, cfg)
    :ok
  end

  defp dispatch_directive(%Directive.Error{error: error, context: context}) do
    msg = Exception.message(error)
    ctx = if context, do: " [#{context}]", else: ""
    Logger.warning(fn -> "Jido directive error#{ctx}: #{msg}" end)
    :ok
  end

  defp dispatch_directive(%Directive.Schedule{delay_ms: delay, message: message})
       when is_integer(delay) and delay > 0 do
    _ = Process.send_after(self(), message, delay)
    :ok
  end

  defp dispatch_directive(%Directive.Spawn{child_spec: child_spec, tag: tag}) do
    case start_child(child_spec) do
      {:ok, pid} ->
        Logger.debug(fn -> "CmdLoop spawned child #{inspect(pid)} (tag: #{inspect(tag)})" end)
        :ok

      {:ok, pid, _info} ->
        Logger.debug(fn -> "CmdLoop spawned child #{inspect(pid)} (tag: #{inspect(tag)})" end)
        :ok

      {:error, reason} ->
        Logger.error(fn -> "CmdLoop failed to spawn child: #{inspect(reason)}" end)
        :ok

      :ignored ->
        :ok
    end
  end

  defp dispatch_directive(%Directive.Stop{reason: reason}) do
    # Exit with a tagged reason so callers can distinguish directive-driven
    # stops from crashes. Matches AgentServer's Directive.Stop semantics.
    exit({:directive_stop, reason})
  end

  defp dispatch_directive(nil), do: :ok

  # Fallback for any directive type we don't yet handle explicitly.
  # Logs at debug level to avoid flooding logs during exploration.
  defp dispatch_directive(directive) do
    Logger.debug(fn -> "CmdLoop: unhandled directive #{inspect(directive)}" end)
    :ok
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Internal helpers
  # ─────────────────────────────────────────────────────────────────────────

  # Default dispatch config for Emit directives without an explicit dispatch.
  # Routes to the supervised `:foreman_jido_signal_bus` bus.
  defp default_dispatch_config do
    {:bus, target: :foreman_jido_signal_bus}
  end

  defp start_child(child_spec) when is_tuple(child_spec) do
    sup =
      case Process.whereis(Jido.TaskSupervisor) do
        nil ->
          case Process.whereis(Jido.AgentSupervisor) do
            nil -> nil
            sup -> sup
          end
        sup ->
          sup
      end

    if sup && is_pid(sup) do
      DynamicSupervisor.start_child(sup, child_spec)
    else
      {:error, :no_supervisor}
    end
  end

  defp start_child(_), do: :ignored
end
