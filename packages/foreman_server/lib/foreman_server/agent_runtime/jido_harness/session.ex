defmodule ForemanServer.AgentRuntime.JidoHarness.Session do
  @moduledoc """
  Foreman-side wrapper around `Jido.Harness.Session` for multi-turn sessions.

  TRD-2026-8a1f3c2e / TRD-009 — multi-turn session wrapper.

  The vendored upstream exposes caller-independent sessions via
  `start/3`, `send_message/3`, and `follow_up/3`. This wrapper gives
  Foreman callers one canonical module for multi-turn work and
  normalizes upstream `{:error, :not_found}` into
  `{:error, :invalid_session}`.

  ## Upstream API surface used here

      Jido.Harness.Session.start(provider, request \\ %{}, options \\ []) :: result(String.t())
      Jido.Harness.Session.send_message(session_id, input, options \\ []) :: result(String.t())

  ## Deviation from the TRD-009 wording

  The TRD describes an upstream `continue/2`, but the vendored upstream
  does not export that function. For an already-started, idle session,
  the upstream resume operation is `Jido.Harness.Session.send_message/3`.
  Upstream `follow_up/3` is a queued-turn API for busy sessions, not the
  general idle-session resume path Foreman needs. This wrapper therefore
  exposes `continue/3` and delegates to `send_message/3`.

  The opaque upstream session ID is preserved verbatim so Foreman
  callers can store it in adapter context and resume the same
  conversation from a later CLI process in the same worktree.
  """

  alias Jido.Harness.Session, as: UpstreamSession

  @type session_id :: String.t()
  @type turn_id :: String.t()
  @type provider :: atom()
  @type turn_input :: String.t() | map() | keyword()
  @type result(value) :: {:ok, value} | {:error, term()}

  @doc """
  Starts a new interactive provider session.

  Upstream exposes `start/3` (`provider, request, options`). Foreman
  callers only need the ergonomic `start/2` form, so this wrapper
  supplies an empty request map and forwards `opts` as upstream options.
  """
  @spec start(provider(), keyword()) :: result(session_id())
  def start(provider, opts \\ []) when is_atom(provider) and is_list(opts) do
    UpstreamSession.start(provider, %{}, opts)
  end

  @doc """
  Sends a turn through an existing session and returns the upstream turn
  ID.

  Returns `{:error, :invalid_session}` for an unknown session ID. All
  other upstream success and error values pass through unchanged.
  """
  @spec send_message(session_id(), turn_input(), keyword()) :: result(turn_id())
  def send_message(session_id, prompt, opts \\ []) when is_list(opts) do
    with :ok <- validate_session_id(session_id),
         {:ok, turn_id} <- UpstreamSession.send_message(session_id, prompt, opts) do
      {:ok, turn_id}
    else
      {:error, :not_found} -> {:error, :invalid_session}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Resumes an existing session and returns the upstream turn ID.

  The vendored upstream has no `continue` function. For Foreman's idle
  session-resume behavior, `send_message/3` is the correct upstream
  operation, so `continue/3` delegates there.
  """
  @spec continue(session_id(), turn_input(), keyword()) :: result(turn_id())
  def continue(session_id, prompt, opts \\ []) when is_list(opts) do
    send_message(session_id, prompt, opts)
  end

  defp validate_session_id(session_id) when is_binary(session_id) and session_id != "", do: :ok
  defp validate_session_id(_), do: {:error, :invalid_session}
end
