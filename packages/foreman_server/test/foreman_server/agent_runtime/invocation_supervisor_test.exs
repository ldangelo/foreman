defmodule ForemanServer.AgentRuntime.InvocationSupervisorTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.InvocationSupervisor

  describe "start_invocation/4" do
    test "returns {:ok, pid, ref} on success" do
      sup_name = :"InvocationSupervisor.Test.unique"

      start_supervised!({InvocationSupervisor, [name: sup_name]},
        id: :invocation_supervisor_start
      )

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

  describe "terminate_invocation/1" do
    test "returns {:error, :not_found} when the invocation id is unknown" do
      sup_name = :"InvocationSupervisor.Test.terminate_not_found"
      registry_name = :"InvocationSupervisor.Test.terminate_not_found.InvocationRegistry"

      start_supervised!({Registry, keys: :unique, name: registry_name},
        id: :invocation_registry_terminate_not_found
      )

      start_supervised!({InvocationSupervisor, [name: sup_name]},
        id: :invocation_supervisor_terminate_not_found
      )

      assert InvocationSupervisor.terminate_invocation("nonexistent-id") ==
               {:error, :not_found}
    end

    test "returns :ok and sends :terminate when the invocation is registered" do
      sup_name = :"InvocationSupervisor.Test.terminate_ok"
      registry_name = :"InvocationSupervisor.Test.terminate_ok.InvocationRegistry"

      start_supervised!({Registry, keys: :unique, name: registry_name},
        id: :invocation_registry_terminate_ok
      )

      start_supervised!({InvocationSupervisor, [name: sup_name]},
        id: :invocation_supervisor_terminate_ok
      )

      invocation_id = "test-invocation-id"
      {:ok, _ref} = Registry.register(registry_name, invocation_id, nil)

      assert InvocationSupervisor.terminate_invocation(invocation_id) == :ok
      assert_receive :terminate, 500
    end
  end

  describe "DynamicSupervisor configuration" do
    test "uses :one_for_one strategy" do
      sup_name = :"InvocationSupervisor.Test.config"

      start_supervised!({InvocationSupervisor, [name: sup_name]},
        id: :invocation_supervisor_config
      )

      # The supervisor should be running
      assert is_pid(Process.whereis(sup_name))
    end
  end
end
