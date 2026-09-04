defmodule ForemanServer.Actions.Registry do
  @moduledoc """
  Foreman-side tool-registration layer for `Jido.Action` modules
  (TRD-2026-4212be7e, JAF-T001).

  The Registry catalogs every Jido.Action module Foreman exposes to
  its agents, exposes each as an LLM-compatible tool descriptor, and
  provides a stable lookup path so other layers (RunExecutor, the
  agent runtime toolset sync, the prompt-template loader) can discover
  actions without hard-coding module names.

  ## Why a process-backed registry

  Jido actions are pure data + behaviour (each module is its own
  process-local definition); they don't have a global catalog. The
  Registry gives Foreman a single place to:

    1. Enumerate the available tools (for agent toolset sync, NFR-08).
    2. Look up a tool by its declared `name/0` (for the agent runtime
       to dispatch a tool call to the right action module).
    3. Expose a JSON-compatible tool descriptor (for LLM tool-calling
       APIs; `action.to_tool/0` returns the canonical shape).

  ## Configuration

  The list of registered actions is supplied at start time via
  `start_link/1`'s `:actions` option. The list is validated at init:
  every entry must be a module that implements the `Jido.Action`
  behaviour (verified via `Jido.Action` in `module_info(:attributes)`).
  If any entry fails the check, the Registry refuses to start with
  `{:stop, {:not_a_jido_action, module}}` — this prevents a typo in
  the production actions list from silently dropping tools.

  Production wiring in `ForemanServer.Application` starts the Registry
  with the full Foreman action set (e.g.
  `[ForemanServer.Actions.GitStatusAction, ...]`).
  """

  use GenServer

  @doc """
  Start the Registry as a GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    actions = Keyword.get(opts, :actions, [])
    bad = Enum.find(actions, fn module -> not jido_action?(module) end)

    if bad do
      {:stop, {:not_a_jido_action, bad}}
    else
      {:ok, %{actions: actions}}
    end
  end

  @doc """
  List the registered action modules.
  """
  @spec list_actions(GenServer.server()) :: [module()]
  def list_actions(server) do
    GenServer.call(server, :list_actions)
  end

  @doc """
  List LLM-compatible tool descriptors, one per registered action.
  Each descriptor is whatever `action.to_tool/0` returns.
  """
  @spec list_tools(GenServer.server()) :: [term()]
  def list_tools(server) do
    GenServer.call(server, :list_tools)
  end

  @doc """
  Look up an action module by its declared `name/0`. Returns `nil`
  if no action with that name is registered.
  """
  @spec lookup(GenServer.server(), String.t()) :: module() | nil
  def lookup(server, name) do
    GenServer.call(server, {:lookup, name})
  end

  @impl true
  def handle_call(:list_actions, _from, state) do
    {:reply, state.actions, state}
  end

  def handle_call(:list_tools, _from, state) do
    tools = Enum.map(state.actions, & &1.to_tool())
    {:reply, tools, state}
  end

  def handle_call({:lookup, name}, _from, state) do
    action =
      Enum.find(state.actions, fn module ->
        safe_name(module) == name
      end)

    {:reply, action, state}
  end

  # True when the module implements the Jido.Action behaviour.
  # Jido.Action registers itself as a behaviour in the module's
  # `:behaviour` attribute, so a `Code.ensure_loaded?/1` + attributes
  # check is the cheapest reliable test (no `apply/3` required).
  defp jido_action?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      Jido.Action in (module.module_info(:attributes)
                      |> Keyword.get_values(:behaviour)
                      |> List.flatten())
  end

  defp jido_action?(_), do: false

  # `Jido.Action` modules raise if `name/0` is called on a module
  # that doesn't implement the behaviour; we wrap in try/rescue so a
  # single misbehaving action doesn't crash the whole registry.
  defp safe_name(module) do
    module.name()
  rescue
    _ -> nil
  end
end
