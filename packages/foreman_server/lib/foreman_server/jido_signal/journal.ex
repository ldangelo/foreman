defmodule ForemanServer.JidoSignal.Journal do
  @moduledoc """
  Foreman signal journal for replay on restart.

  This module wraps Jido.Signal.Journal to provide Foreman-specific signal
  journaling with persistence and replay capabilities.
  """

  alias Jido.Signal.Journal

  @doc """
  Creates a new Foreman signal journal.

  Uses ETS adapter for in-memory persistence.
  """
  @spec new() :: Journal.t()
  def new do
    Journal.new(Jido.Signal.Journal.Adapters.ETS)
  end

  @doc """
  Records a signal in the journal.

  ## Parameters
  - `journal`: The journal to record to
  - `signal`: A `%Jido.Signal{}` struct

  ## Returns
  - `{:ok, journal}` on success
  - `{:error, reason}` on failure
  """
  @spec record_signal(Journal.t(), %Jido.Signal{}) ::
          {:ok, Journal.t()} | {:error, atom()}
  def record_signal(journal, signal) do
    Journal.record(journal, signal)
  end

  @doc """
  Queries signals from the journal.

  ## Parameters
  - `journal`: The journal to query
  - `opts`: Query options (type, source, after, before)

  ## Returns
  - List of `%Jido.Signal{}` structs
  """
  @spec query_signals(Journal.t(), keyword()) :: [Jido.Signal.t()]
  def query_signals(journal, opts \\ []) do
    Journal.query(journal, opts)
  end
end
