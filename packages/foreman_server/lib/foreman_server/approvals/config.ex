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
    * `:inflight` - route a claude phase's permission prompts to Foreman while the
      call is blocked (default `true`; off in the test config) and
      `:inflight_base_url` - the URL claude reaches the permission endpoint at
      (default: loopback on the endpoint's HTTP port); `:inflight_progress_ms` - keep-alive
      period of a blocked prompt's reply (default 15 s).
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
      policy when policy in [:surface, :deny] ->
        policy

      other ->
        raise ArgumentError,
              "config :foreman_server, :approvals, on_timeout must be :surface or :deny, got: #{inspect(other)}"
    end
  end

  @doc "Whether a permission-denied phase pauses the run for an operator decision."
  @spec pause_on_permission_denied?() :: boolean()
  def pause_on_permission_denied? do
    case get(:pause_on_permission_denied, true) do
      flag when is_boolean(flag) ->
        flag

      other ->
        raise ArgumentError,
              "config :foreman_server, :approvals, pause_on_permission_denied must be a boolean, got: #{inspect(other)}"
    end
  end

  @doc """
  Whether a claude phase with `approval_mode: prompt` routes permission prompts to
  Foreman while the call is blocked (default `true`). `false` keeps every provider on the phase-pause
  path.
  """
  @spec inflight?() :: boolean()
  def inflight?, do: get(:inflight, true) == true

  @default_progress_ms 15_000

  @doc """
  How often a blocked in-flight permission reply emits a progress event so claude does not
  abandon it (it times out a silent HTTP reply after ~60 s). Default 15 s.
  """
  @spec inflight_progress_ms() :: pos_integer()
  def inflight_progress_ms, do: get(:inflight_progress_ms, @default_progress_ms)

  @doc """
  Base URL the claude CLI uses to reach the permission endpoint: `:inflight_base_url`
  if set, else loopback on the endpoint's HTTP port. `nil` when neither is known (the
  endpoint is not listening), so the caller falls back to the phase-pause path.
  """
  @spec inflight_base_url() :: String.t() | nil
  def inflight_base_url do
    case get(:inflight_base_url, nil) do
      url when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/")

      _ ->
        case ForemanServerWeb.Endpoint.config(:http) do
          opts when is_list(opts) ->
            case Keyword.get(opts, :port) do
              port when is_integer(port) and port > 0 -> "http://127.0.0.1:#{port}"
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  @doc "Whether the application supervisor starts the approvals processes."
  @spec start_children?() :: boolean()
  def start_children?, do: get(:start_children, true) == true

  defp get(key, default) do
    :foreman_server |> Application.get_env(:approvals, []) |> Keyword.get(key, default)
  end
end
