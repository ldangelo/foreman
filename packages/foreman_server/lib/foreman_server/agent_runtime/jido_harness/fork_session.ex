defmodule ForemanServer.AgentRuntime.JidoHarness.ForkSession do
  @moduledoc """
  Forking a provider session into a NEW agent run: the one place that knows which providers can do
  it, which ids are safe to hand to their CLI, and how the harness is asked to start the run.

  A fork starts a NEW provider session whose history is a copy of the source's. The source is never
  written to: resuming it in place would put two writers on one provider session, and the source may
  still be running (`adopt --continue --fork`, `docs/user-guide.md`).

  Measured against the real CLIs (claude 2.1.308, pi, `docs/spikes/E9-SP2.md`): `claude --resume <id>
  --fork-session` and `pi --fork <id>` both find the session by id from ANY working directory, also
  when the directory it was created in has been removed (a finished run's worktree is), and neither
  asks a question. A plain pi `--session <id>` from another directory DOES prompt, so a RESUME stays
  bound to its original directory while a FORK is not. Other providers are not forkable here: the list
  is closed on purpose, a provider joins it only once its CLI has been measured the same way.
  """

  @providers ~w(claude pi)

  # A session id becomes an ARGUMENT of the provider CLI (`--resume <id>`): refuse anything that could
  # be read as another flag or carries a separator. Claude's are UUIDs, pi's are UUIDv7.
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

  @type harness_options :: {provider_session_id :: String.t() | nil, provider_options :: map()}

  @doc "Providers a session can be forked from."
  @spec providers() :: [String.t()]
  def providers, do: @providers

  @doc """
  Checks a `{provider, session id}` pair as recorded on a task (`TaskCreated.fork_provider`,
  `fork_session_id`): `:none` when neither is given, `:ok` when both are valid,
  `{:error, {:invalid_fork_session, field, value}}` otherwise (one given without the other is
  `:incomplete`).
  """
  @spec validate(term(), term()) ::
          :none | :ok | {:error, {:invalid_fork_session, atom(), term()}}
  def validate(nil, nil), do: :none

  def validate(provider, session_id) when is_nil(provider) or is_nil(session_id),
    do: {:error, {:invalid_fork_session, :incomplete, {provider, session_id}}}

  def validate(provider, session_id) do
    cond do
      provider not in @providers -> {:error, {:invalid_fork_session, :provider, provider}}
      not valid_id?(session_id) -> {:error, {:invalid_fork_session, :session_id, session_id}}
      true -> :ok
    end
  end

  @doc """
  The harness request fields that start a run from a fork of `session_id`: Claude is
  `--resume <id> --fork-session` (the id travels as `provider_session_id`), pi is `--fork <id>` (no
  `provider_session_id`: the harness refuses both together).

  Raises for a provider outside `providers/0` or an unsafe id: callers validate first with `validate/2`.
  """
  @spec harness_options(String.t() | atom(), String.t()) :: harness_options()
  def harness_options(provider, session_id) when is_atom(provider) and not is_nil(provider),
    do: harness_options(Atom.to_string(provider), session_id)

  def harness_options(provider, session_id) when provider in @providers do
    unless valid_id?(session_id),
      do: raise(ArgumentError, "unsafe provider session id #{inspect(session_id)}")

    case provider do
      "claude" -> {session_id, %{fork_session: true}}
      "pi" -> {nil, %{fork_session: session_id}}
    end
  end

  defp valid_id?(session_id), do: is_binary(session_id) and Regex.match?(@id_pattern, session_id)
end
