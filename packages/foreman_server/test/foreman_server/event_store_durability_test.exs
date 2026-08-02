defmodule ForemanServer.EventStoreDurabilityTest do
  @moduledoc """
  TRD-041 / AC-021-1: codifies the compose + init.sql wiring that turns on
  `data_checksums = on` and `wal_level = replica` on a fresh Postgres cluster.

  This is a STATIC test — no DB connection. The companion behavioral
  verification is documented in `docs/user-guide.md` under "Postgres
  durability settings". AGENTS.md permits local checkouts to point
  `DATABASE_URL` at alternate Postgres instances and CI uses plain
  `postgres:15` without checksum init, so this test never reaches a DB.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @compose_path Path.join(@repo_root, "compose.yaml")
  @init_sql_path Path.join(@repo_root, "packages/foreman_server/priv/repo/init.sql")

  # Compose.yaml: line-anchored so comments cannot satisfy the assertion.
  test "compose.yaml enables data_checksums via POSTGRES_INITDB_ARGS" do
    compose = File.read!(@compose_path)
    assert compose =~ ~r/^\s*POSTGRES_INITDB_ARGS:\s*--data-checksums\s*$/m,
           "compose.yaml must set `POSTGRES_INITDB_ARGS: --data-checksums` " <>
             "so `initdb` enables page-level checksums at cluster init."
  end

  test "compose.yaml mounts packages/foreman_server/priv/repo/init.sql into docker-entrypoint-initdb.d" do
    compose = File.read!(@compose_path)

    assert compose =~
             ~r|^\s*-\s*\./packages/foreman_server/priv/repo/init\.sql:/docker-entrypoint-initdb\.d/.+\.sql:ro\s*$|m,
           "compose.yaml must mount packages/foreman_server/priv/repo/init.sql " <>
             "(single source of truth) into the postgres init dir."
  end

  # init.sql: strip SQL `--` comment lines so the comment body cannot satisfy
  # the assertion (init.sql currently explains the very statements it must run).
  defp executable_lines(sql) do
    sql
    |> String.split(["\r\n", "\n"], trim: false)
    |> Enum.reject(fn line -> String.trim(line) |> String.starts_with?("--") end)
    |> Enum.join("\n")
  end

  test "init.sql sets wal_level via ALTER SYSTEM (executable statement, not a comment)" do
    sql = executable_lines(File.read!(@init_sql_path))

    assert sql =~ ~r/^\s*ALTER\s+SYSTEM\s+SET\s+wal_level\s*=\s*replica\s*;\s*$/im,
           "init.sql must run `ALTER SYSTEM SET wal_level = replica;` " <>
             "(replica is required for streaming replication / future replicas)."
  end

  test "init.sql does not attempt to set data_checksums via ALTER SYSTEM" do
    sql = executable_lines(File.read!(@init_sql_path))

    refute sql =~ ~r/^\s*ALTER\s+SYSTEM\s+SET\s+data_checksums/im,
           "data_checksums is NOT a PostgreSQL GUC and `ALTER SYSTEM SET " <>
             "data_checksums` is rejected at runtime. Use `POSTGRES_INITDB_ARGS: " <>
             "--data-checksums` instead (see compose.yaml)."
  end
end