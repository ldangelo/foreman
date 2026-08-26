defmodule ForemanServer.AgentRuntime.InvocationSupervisorTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.InvocationSupervisor
  alias ForemanServer.TestSupport.InvocationSupervisorHelpers

  describe "start_invocation/4" do
    test "returns {:ok, pid, ref} on success" do
      sup_name = :"InvocationSupervisor.Test.unique"

      InvocationSupervisorHelpers.start({InvocationSupervisor, [name: sup_name]},
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

      InvocationSupervisorHelpers.start({InvocationSupervisor, [name: sup_name]},
        id: :invocation_supervisor_terminate_not_found
      )

      assert InvocationSupervisor.terminate_invocation("nonexistent-id") ==
               {:error, :not_found}
    end

    test "returns :ok and stops the invocation child when registered via start_invocation" do
      defmodule BlockingAdapter do
        @behaviour ForemanServer.AgentRuntime.BackendAdapter

        @impl true
        def name, do: :blocking_test_adapter

        @impl true
        def capabilities do
          %{
            type: :cli,
            strengths: [:code_generation],
            weaknesses: [],
            supported_contexts: [:implement]
          }
        end

        @impl true
        def available?, do: true

        @impl true
        def execute(_request, _opts) do
          # Block until the supervisor terminates this child process.
          receive do
            :stop -> {:ok, "completed", %{}}
          end
        end
      end

      sup_name = :"InvocationSupervisor.Test.terminate_ok"
      InvocationSupervisorHelpers.start({InvocationSupervisor, [name: sup_name]},
        id: :invocation_supervisor_terminate_ok
      )

      policy = %{
        fail_fast: true,
        fallback: false,
        max_attempts: 1,
        timeout_ms: 60_000
      }

      {:ok, pid, ref} =
        InvocationSupervisor.start_invocation(
          [{BlockingAdapter, true}],
          policy,
          %{prompt: "ping"},
          self(),
          nil,
          sup_name,
          %{}
        )

      # Monitor before terminating: DynamicSupervisor.terminate_child/2 is
      # synchronous, so the child is already dead by the time it returns.
      # Monitoring afterward would race and observe :noproc instead of the
      # :shutdown exit reason.
      monitor = Process.monitor(pid)

      assert InvocationSupervisor.terminate_invocation(ref) == :ok

      assert_receive {:DOWN, ^monitor, :process, ^pid, :shutdown}, 1_000
    end
  end
  describe "DynamicSupervisor configuration" do
    test "uses :one_for_one strategy" do
      sup_name = :"InvocationSupervisor.Test.config"

      InvocationSupervisorHelpers.start({InvocationSupervisor, [name: sup_name]},
        id: :invocation_supervisor_config
      )

      # The supervisor should be running
      assert is_pid(Process.whereis(sup_name))
    end
  end
end
