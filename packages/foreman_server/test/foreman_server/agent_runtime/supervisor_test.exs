defmodule ForemanServer.AgentRuntime.SupervisorTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.Supervisor

  describe "start_link/1" do
    test "starts the supervisor with AdapterCatalog and InvocationSupervisor children" do
      unique = :erlang.unique_integer()
      sup_name = :"AgentRuntime.Supervisor.Test.#{unique}"
      catalog_name = :"AdapterCatalog.Test.#{unique}"
      invocation_name = :"InvocationSupervisor.Test.#{unique}"

      pid = start_supervised!({Supervisor, [name: sup_name, adapter_catalog_name: catalog_name, invocation_supervisor_name: invocation_name]}, id: :AgentRuntime_supervisor)

      # Verify supervisor is running
      assert is_pid(pid)

      # Verify children are registered under expected names
      assert Process.whereis(catalog_name) != nil
      assert Process.whereis(invocation_name) != nil
    end

    test "can be started with a custom name" do
      unique = :erlang.unique_integer()
      sup_name = :"AgentRuntime.Supervisor.Test.#{unique}"
      catalog_name = :"AdapterCatalog.Test.#{unique}"
      invocation_name = :"InvocationSupervisor.Test.#{unique}"

      pid = start_supervised!({Supervisor, [name: sup_name, adapter_catalog_name: catalog_name, invocation_supervisor_name: invocation_name]}, id: :AgentRuntime_supervisor_named)

      assert Process.whereis(sup_name) == pid
    end
  end

  describe "when configured" do
    test "supervisor starts all children" do
      unique = :erlang.unique_integer()
      sup_name = :"AgentRuntime.Supervisor.Test.#{unique}"
      catalog_name = :"AdapterCatalog.Test.#{unique}"
      invocation_name = :"InvocationSupervisor.Test.#{unique}"

      _pid = start_supervised!({Supervisor, [name: sup_name, adapter_catalog_name: catalog_name, invocation_supervisor_name: invocation_name]}, id: :AgentRuntime_supervisor_full)

      # Both children should be registered under the custom names
      assert is_pid(Process.whereis(catalog_name))
      assert is_pid(Process.whereis(invocation_name))
    end
  end
end
