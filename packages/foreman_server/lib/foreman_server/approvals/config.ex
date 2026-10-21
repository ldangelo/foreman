defmodule ForemanServer.Approvals.Config do
  @moduledoc """
  Runtime settings for approvals, questions and their timeouts
  (`config :foreman_server, :approvals, ...`):

    * `:tool_call_timeout_ms` - how long a tool-call request may stay undecided
      before the sweeper expires it (default 30 minutes).
    * `:approval_timeout_ms` - the finite per-request timeout handed to a live
      provider session (`Session.start/2`), default `:tool_call_timeout_ms`.
      Never `:infinity`: a headless ACP session waits forever otherwise (spike S2).
    * `:sweep_interval_ms` - sweeper period (default 60 seconds, `:manual` disables).
    * `:on_timeout` - `:surface` (default: expire and show it on the Overview) or
      `:deny` (deny with reason `"timeout"` and tell the agent).
    * `:pause_on_permission_denied` - when a phase's agent reports permission
      denials, pause the run awaiting an operator decision instead of failing it
      (default `true`).
    * `:start_children` - start the Deliverer, Live registry and Sweeper (default
      `true`; off in the test config).
  """

  @default_tool_call_timeout_ms 30 * 60 * 1000
  @default_sweep_interval_ms 60_000

  @doc "Tool-call request timeout in milliseconds."
  @spec tool_call_timeout_ms() :: pos_integer()
  def tool_call_timeout_ms, do: get(:tool_call_timeout_ms, @default_tool_call_timeout_ms)

  @doc "Finite provider-session approval timeout in milliseconds."
  @spec approval_timeout_ms() :: pos_integer()
  def approval_timeout_ms, do: get(:approval_timeout_ms, tool_call_timeout_ms())

  @doc "Sweeper period in milliseconds, or `:manual`."
  @spec sweep_interval_ms() :: pos_integer() | :manual
  def sweep_interval_ms, do: get(:sweep_interval_ms, @default_sweep_interval_ms)

  @doc "Timeout policy: `:surface` or `:deny`."
  @spec on_timeout() :: :surface | :deny
  def on_timeout do
    case get(:on_timeout, :surface) do
      :deny -> :deny
      _ -> :surface
    end
  end

  @doc "Whether a permission-denied phase pauses the run for an operator decision."
  @spec pause_on_permission_denied?() :: boolean()
  def pause_on_permission_denied?, do: get(:pause_on_permission_denied, true) == true

  @doc "Whether the application supervisor starts the approvals processes."
  @spec start_children?() :: boolean()
  def start_children?, do: get(:start_children, true) == true

  defp get(key, default) do
    :foreman_server |> Application.get_env(:approvals, []) |> Keyword.get(key, default)
  end
end
