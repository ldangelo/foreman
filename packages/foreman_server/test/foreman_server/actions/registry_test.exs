defmodule ForemanServer.Actions.RegistryTest do
  @moduledoc """
  Tests for `ForemanServer.Actions.Registry` — the Foreman-side
  tool-registration layer for `Jido.Action` modules
  (TRD-2026-4212be7e, JAF-T001).
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Actions.GitStatusAction
  alias ForemanServer.Actions.Registry

  setup do
    name = :"Actions.Registry.Test.#{:erlang.unique_integer()}"

    start_supervised!(
      {Registry, [name: name, actions: [GitStatusAction]]},
      id: :Actions_Registry
    )

    {:ok, name: name}
  end

  describe "init/1 validation (JAF-T001 contract enforcement)" do
    test "rejects a non-Jido.Action module" do
      # The Registry's init/1 should refuse with {:stop, reason};
      # GenServer.start_link converts that to {:error, reason}.
      # We trap exits because start_link is called outside the
      # ExUnit supervisor (the GenServer never starts, so the
      # supervised! macro can't catch the EXIT signal for us).
      Process.flag(:trap_exit, true)
      result = Registry.start_link(actions: [StringIO])
      assert {:error, {:not_a_jido_action, StringIO}} = result
    end
  end

  describe "list_actions/1" do
    test "returns the modules passed at start", %{name: name} do
      assert Registry.list_actions(name) == [GitStatusAction]
    end
  end

  describe "list_tools/1" do
    test "returns a list of LLM tool descriptors, one per action", %{name: name} do
      tools = Registry.list_tools(name)
      assert is_list(tools)
      assert length(tools) == 1
      [tool] = tools
      assert is_map(tool) or is_list(tool)
    end
  end

  describe "lookup/2" do
    test "returns the action module for a known name", %{name: name} do
      assert Registry.lookup(name, "git_status") == GitStatusAction
    end

    test "returns nil for an unknown name", %{name: name} do
      assert Registry.lookup(name, "nonexistent_action") == nil
    end
  end
end
