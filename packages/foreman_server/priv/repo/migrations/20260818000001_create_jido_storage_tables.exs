defmodule ForemanServer.Repo.Migrations.CreateJidoStorageTables do
  @moduledoc """
  Creates the Postgres tables required by `Jido.Ecto.Storage`:
  `jido_checkpoints`, `jido_threads`, `jido_thread_entries`.

  Generated from the upstream `Jido.Ecto.Migrations.create_storage_tables/1`
  macro so the schema stays in sync with the Jido version pinned in
  `mix.exs` (TRD-2026-4212be7e, JCR-T004).

  See `Jido.Ecto.Migrations` for the macro semantics.
  """

  use Ecto.Migration

  def change do
    require Jido.Ecto.Migrations
    Jido.Ecto.Migrations.create_storage_tables(version: 1)
  end
end
