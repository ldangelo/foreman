defmodule ForemanServer.Agents.JidoCheckpointStore.Repo do
  @moduledoc """
  Ecto.Repo used by `ForemanServer.Agents.JidoCheckpointStore` for
  Jido agent checkpoint and thread persistence
  (TRD-2026-4212be7e, JCR-T004).

  This is a separate Repo from Foreman's analytics repo so the Jido
  tables (jido_checkpoints, jido_threads, jido_thread_entries) live
  in their own namespace. Operators may point this Repo at a
  different database or a different schema in the same Postgres
  cluster via `:foreman_server, ForemanServer.Agents.JidoCheckpointStore.Repo, :url`.

  The Repo is intentionally separate from the EventStore's underlying
  Postgres pool — foreman's event log and jido's checkpoints have
  different access patterns (event log is append-heavy, Jido is
  read-after-write) and we want them isolated.
  """

  use Ecto.Repo,
    otp_app: :foreman_server,
    adapter: Ecto.Adapters.Postgres
end
