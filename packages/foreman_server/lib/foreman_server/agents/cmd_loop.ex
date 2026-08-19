defmodule ForemanServer.Agents.CmdLoop do
  @moduledoc """
  Foreman-side cmd/2 loop implementation that delegates to Jido.Agent.cmd/3.
  Returns updated agent struct + directives as `{:ok, updated, directives}`.

  TRD-2026-4212be7e / JCR-T003 / TRD-005.
  """
  alias Jido.Agent

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
          {:ok, Jido.Agent.t(), [Jido.Agent.Directive.t()]}
          | {:error, term()}
  def call(agent, action_module, params) when is_map(params) do
    normalized = normalize_action(action_module, params)
    opts = params_to_opts(params)

    {updated, directives} = Agent.cmd(agent, normalized, opts)
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

      {:error, reason} ->
        {:error, reason}
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

  # Convert a params map to a keyword list for Agent.cmd/3's `opts` argument.
  # An empty map becomes [] so Agent.cmd/3 uses its bare-module → default-params
  # codepath. A non-empty map becomes [] here because the params are already
  # embedded in the action tuple via normalize_action/2.
  defp params_to_opts(%{}), do: []
  defp params_to_opts(params) when is_list(params), do: params

  # Placeholder dispatcher — Jido.Directive handlers will be wired in a
  # follow-on task (TRD-014 / JSI-T011).  No-op keeps the contract clean.
  defp dispatch_directive(_directive), do: :ok
end
