defmodule ForemanServer.Agents.JidoCheckpointStore do
  @moduledoc """
  Foreman-side wrapper around `Jido.Ecto.Storage` for Jido agent
  checkpoint + thread persistence (TRD-2026-4212be7e, JCR-T004).

  ## Why this module exists

  `Jido.Ecto.Storage` is a Postgres-backed implementation of the
  `Jido.Storage` behaviour. It requires an Ecto repo passed via the
  `:repo` option on every call. Foreman wraps it so that:

    1. The Foreman-side call sites use a single `ForemanServer.Agents.*`
       module — no need to depend directly on the `Jido.Ecto` package
       in business code (RunExecutor, CommandRouter, etc.).
    2. The repo can be configured once at application boot via
       `config :foreman_server, JidoCheckpointStore, repo: MyRepo`
       rather than threaded through every call site.
    3. Foreman's idempotency-key contract (TRD-2026-014 §4.4) can be
       extended with `{started, completed, ambiguous}` records by
       layering on top of this store — that is tracked separately as
       RTE-T001.

  ## Configuration

  Set the Ecto repo in runtime config:

      config :foreman_server, ForemanServer.Agents.JidoCheckpointStore,
        repo: ForemanServer.Agents.JidoCheckpointStore.Repo

  The repo must be supervised by Foreman's application tree
  (e.g. via `maybe_jido_checkpoint_repo_child/0`). When the config
  key is missing, every call returns `{:error, :repo_not_configured}`
  rather than crashing — that lets the wrapper start safely in
  environments without Postgres (e.g. dev machines that haven't set
  up the DB) without making the wrapper itself unsafe to load.

  ## Idempotency

  `put_checkpoint/3` uses Ecto's `insert_all` with
  `on_conflict: [set: ...]` against `key_hash`, so writing the same
  key twice updates the row in place rather than raising. This matches
  Foreman's idempotency-key contract; RTE-T001 will layer
  `{started, completed, ambiguous}` records on top.
  """

  alias Jido.Ecto.Storage

  @doc """
  Persist a checkpoint under the given key. Returns `:ok` on success
  (matches `Jido.Ecto.Storage.put_checkpoint/3`).
  """
  @spec put(term(), term(), keyword()) :: :ok | {:error, term()}
  def put(key, data, opts \\ []) do
    with {:ok, repo_opts} <- with_repo(opts) do
      Storage.put_checkpoint(key, data, repo_opts)
    end
  end

  @doc """
  Load a checkpoint by key. Returns `{:ok, data}` on hit,
  `:not_found` on miss, `{:error, term()}` on transport or decode
  failure (matches `Jido.Ecto.Storage.get_checkpoint/2`).
  """
  @spec get(term(), keyword()) :: {:ok, term()} | :not_found | {:error, term()}
  def get(key, opts \\ []) do
    with {:ok, repo_opts} <- with_repo(opts) do
      Storage.get_checkpoint(key, repo_opts)
    end
  end

  @doc """
  Delete a checkpoint by key. Returns `:ok` on success.
  """
  @spec delete(term(), keyword()) :: :ok | {:error, term()}
  def delete(key, opts \\ []) do
    with {:ok, repo_opts} <- with_repo(opts) do
      Storage.delete_checkpoint(key, repo_opts)
    end
  end

  @doc """
  Load a thread (Jido's ordered journal of agent work) by id.
  Returns `{:ok, %Jido.Thread{}}` on hit, `:not_found` on miss.
  """
  @spec load_thread(String.t(), keyword()) :: {:ok, term()} | :not_found | {:error, term()}
  def load_thread(thread_id, opts \\ []) do
    with {:ok, repo_opts} <- with_repo(opts) do
      Storage.load_thread(thread_id, repo_opts)
    end
  end

  @doc """
  Append entries to a thread's journal. Returns `{:ok, %Jido.Thread{}}`
  on success, `{:error, :conflict}` on optimistic-concurrency conflict,
  `{:error, term()}` on other failures.
  """
  @spec append_thread(String.t(), [map()], keyword()) :: {:ok, term()} | {:error, term()}
  def append_thread(thread_id, entries, opts \\ []) do
    with {:ok, repo_opts} <- with_repo(opts) do
      Storage.append_thread(thread_id, entries, repo_opts)
    end
  end

  @doc """
  Delete a thread and all of its journal entries.
  """
  @spec delete_thread(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_thread(thread_id, opts \\ []) do
    with {:ok, repo_opts} <- with_repo(opts) do
      Storage.delete_thread(thread_id, repo_opts)
    end
  end

  @doc """
  Return the underlying Jido capability list. Used by the supervisor
  tree to decide whether to start the store (capability-aware
  routing) — currently always `[:storage, :persist]`.
  """
  @spec capabilities() :: [:storage | :persist, ...]
  def capabilities, do: Jido.Ecto.capabilities()

  @doc """
  Read the configured Ecto repo module. Returns `nil` if not set
  (the wrapper will then return `{:error, :repo_not_configured}` on
  every call). Foreman's application boot is expected to populate
  this via `Application.put_env/3` when starting the Jido bridge.
  """
  @spec configured_repo() :: module() | nil
  def configured_repo do
    :foreman_server
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:repo)
  end

  # --- internal helpers --------------------------------------------------

  # Merge the configured repo (if any) into the call opts. Callers
  # that pass an explicit `repo:` override win. If neither is set,
  # return `{:error, :repo_not_configured}` so the failure is visible
  # at the call site rather than a stack trace from upstream.
  defp with_repo(opts) do
    case Keyword.get(opts, :repo) || configured_repo() do
      nil ->
        {:error, :repo_not_configured}

      repo when is_atom(repo) and not is_nil(repo) ->
        {:ok, Keyword.put(opts, :repo, repo)}
    end
  end
end
