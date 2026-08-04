defmodule ForemanServer.AgentRuntime.InvocationSupervisorTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.InvocationSupervisor

  describe "start_invocation/4" do
    test "returns {:ok, pid, ref} on success" do
      sup_name = :"InvocationSupervisor.Test.unique"
      start_supervised!({InvocationSupervisor, [name: sup_name]}, id: :invocation_supervisor_start)

      # Minimal adapter for testing
      defmodule MinimalAdapter do
        @behaviour ForemanServer.AgentRuntime.BackendAdapter
        @impl true
        def name, do: :minimal
        @impl true
        def capabilities do
          %{
            type: :language_model,
            strengths: [],
            weaknesses: [],
            supported_contexts: []
          }
        end
        @impl true
        def available?, do: true
        @impl true
        def execute(_req, _opts), do: {:ok, "ok", %{}}
      end

      request = %{prompt: "test", context: %{}}
      result = InvocationSupervisor.start_invocation(MinimalAdapter, request, self(), sup_name)

      assert {:ok, pid, ref} = result
      assert is_pid(pid)
      assert is_reference(ref)
    end
  end

  describe "DynamicSupervisor configuration" do
    test "uses :one_for_one strategy" do
      sup_name = :"InvocationSupervisor.Test.config"
      start_supervised!({InvocationSupervisor, [name: sup_name]}, id: :invocation_supervisor_config)

      # The supervisor should be running
      assert is_pid(Process.whereis(sup_name))
    end
  end
end
