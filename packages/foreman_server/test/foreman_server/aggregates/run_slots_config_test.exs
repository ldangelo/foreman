defmodule ForemanServer.RunSlots.ConfigTest do
  # Mutates application env: not async.
  use ExUnit.Case, async: false

  alias ForemanServer.RunSlots.Config

  setup do
    previous = Application.get_env(:foreman_server, :max_concurrent_runs_per_project)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:foreman_server, :max_concurrent_runs_per_project),
        else: Application.put_env(:foreman_server, :max_concurrent_runs_per_project, previous)
    end)

    :ok
  end

  describe "max_concurrent_runs_per_project/0" do
    test "default is three when nothing is configured (AC-002-1)" do
      Application.delete_env(:foreman_server, :max_concurrent_runs_per_project)
      assert Config.max_concurrent_runs_per_project() == 3
    end

    test "the shipped config.exs sets the per-project default to three (AC-002-1)" do
      config =
        Elixir.Config.Reader.read!(Path.expand("../../../config/config.exs", __DIR__), env: :test)

      assert get_in(config, [:foreman_server, :max_concurrent_runs_per_project]) == 3
    end

    test "returns configured value when set" do
      Application.put_env(:foreman_server, :max_concurrent_runs_per_project, 5)
      assert Config.max_concurrent_runs_per_project() == 5
    end
  end

  describe "the retired global cap (AC-008-2)" do
    test "RunSlots.Config no longer exposes max_concurrent_runs/0" do
      Code.ensure_loaded!(Config)
      refute function_exported?(Config, :max_concurrent_runs, 0)
    end

    test "no shipped config sets the retired :max_concurrent_runs key" do
      for file <- ["config.exs", "test.exs"] do
        config =
          Elixir.Config.Reader.read!(Path.expand("../../../config/#{file}", __DIR__), env: :test)

        refute Keyword.has_key?(config[:foreman_server] || [], :max_concurrent_runs), file
      end
    end
  end
end
