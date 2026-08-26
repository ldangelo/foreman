defmodule ForemanServer.RunSlots.ConfigTest do
  use ExUnit.Case, async: true

  alias ForemanServer.RunSlots.Config

  describe "max_concurrent_runs/0" do
    test "returns default value when config not set" do
      Application.delete_env(:foreman_server, :max_concurrent_runs)
      assert Config.max_concurrent_runs() == 3
    end

    test "returns configured value when set" do
      Application.put_env(:foreman_server, :max_concurrent_runs, 10)
      on_exit(fn -> Application.delete_env(:foreman_server, :max_concurrent_runs) end)
      assert Config.max_concurrent_runs() == 10
    end
  end

  describe "max_concurrent_runs_per_project/0" do
    test "returns default value when config not set" do
      Application.delete_env(:foreman_server, :max_concurrent_runs_per_project)
      assert Config.max_concurrent_runs_per_project() == 100
    end

    test "returns configured value when set" do
      Application.put_env(:foreman_server, :max_concurrent_runs_per_project, 5)
      on_exit(fn -> Application.delete_env(:foreman_server, :max_concurrent_runs_per_project) end)
      assert Config.max_concurrent_runs_per_project() == 5
    end
  end
end
