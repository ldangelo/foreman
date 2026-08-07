defmodule ForemanServer.TaskProviders.BeadsAdapterTest do
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProvider
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock

  @expected_capabilities %{
    provider_id: :beads,
    contract_version: "br.capabilities.v1",
    supports: [
      :claim,
      :close,
      :reopen,
      :annotate,
      :set_priority,
      :set_assignee,
      :list_dependencies,
      :add_dependency,
      :remove_dependency
    ]
  }

  @expected_callbacks TaskProvider.behaviour_info(:callbacks)

  test "Application.compile_env resolves BrRunnerMock in :test" do
    assert BeadsAdapter.__runner__() == BrRunnerMock
  end

  test "name/0 returns :beads" do
    assert BeadsAdapter.name() == :beads
  end

  test "capabilities/0 returns expected map" do
    assert BeadsAdapter.capabilities() == @expected_capabilities
  end

  test "available?/0 returns false when br is not on PATH" do
    original_path = System.get_env("PATH")

    on_exit(fn ->
      case original_path do
        nil -> System.delete_env("PATH")
        path -> System.put_env("PATH", path)
      end
    end)

    System.put_env("PATH", "")

    assert BeadsAdapter.available?() == false
  end

  test "available?/0 returns true when br is on PATH" do
    assert is_binary(System.find_executable("br"))
    assert BeadsAdapter.available?() == true
  end

  test "11 callbacks are defined" do
    assert length(@expected_callbacks) == 11
    assert BeadsAdapter.behaviour_info(:callbacks) == @expected_callbacks

    Enum.each(@expected_callbacks, fn {name, arity} ->
      assert function_exported?(BeadsAdapter, name, arity)
    end)
  end

  test "unimplemented callbacks return {:error, :not_implemented}" do
    assert BeadsAdapter.list_ready(:actor, []) == {:error, :not_implemented}
    assert BeadsAdapter.get("issue-1", %{}) == {:error, :not_implemented}
    assert BeadsAdapter.claim("issue-1", :actor, %{}) == {:error, :not_implemented}
    assert BeadsAdapter.complete("issue-1", :actor, %{}) == {:error, :not_implemented}
    assert BeadsAdapter.fail("issue-1", :actor, %{}) == {:error, :not_implemented}
    assert BeadsAdapter.reopen("issue-1", "retry", %{}) == {:error, :not_implemented}
    assert BeadsAdapter.add_dependency("issue-1", "issue-2", %{}) == {:error, :not_implemented}
  end
end
