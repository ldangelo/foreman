defmodule ForemanServer.AgentRuntime.InvocationTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.InvocationSupervisor
  alias ForemanServer.AgentRuntime.BackendAdapter

  # Test adapters
  defmodule SuccessAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :success_adapter
    @impl true
    def capabilities do
      %{
        type: :language_model,
        strengths: [:coding],
        weaknesses: [],
        supported_contexts: [:chat]
      }
    end
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "success response", %{meta: true}}
  end

  defmodule ErrorAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :error_adapter
    @impl true
    def capabilities do
      %{
        type: :language_model,
        strengths: [:coding],
        weaknesses: [],
        supported_contexts: [:chat]
      }
    end
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:error, :something_went_wrong}
  end

  defmodule CrashAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :crash_adapter
    @impl true
    def capabilities do
      %{
        type: :language_model,
        strengths: [:coding],
        weaknesses: [],
        supported_contexts: [:chat]
      }
    end
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: raise("adapter crashed")
  end

  # Blocking adapter - signals when execution starts then blocks
  # Accepts test_pid in request context to signal completion
  defmodule BlockingAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :blocking_adapter
    @impl true
    def capabilities do
      %{
        type: :language_model,
        strengths: [:coding],
        weaknesses: [],
        supported_contexts: [:chat]
      }
    end
    @impl true
    def available?, do: true
    @impl true
    def execute(request, _opts) do
      # Signal that we started to the test process
      test_pid = request.context.test_pid
      send(test_pid, {:blocking_adapter, :started})
      # Block until released
      receive do
        {:release, result} -> result
      end
    end
  end

  # Helper to start supervisor with unique name
  defp start_invocation_supervisor(id) do
    name = :"InvocationSupervisor.Test.#{id}"
    start_supervised!({InvocationSupervisor, [name: name]}, id: id)
    name
  end

  describe "success path" do
    test "returns {:ok, backend_name, content, metadata}" do
      sup_name = start_invocation_supervisor(:invocation_success)

      request = %{prompt: "hello", context: %{}}
      {:ok, _pid, ref} = InvocationSupervisor.start_invocation(SuccessAdapter, request, self(), sup_name)

      assert_receive {:agent_runtime_invocation_complete, ^ref, result}

      assert result == {:ok, :success_adapter, "success response", %{meta: true}}
    end
  end

  describe "error path" do
    test "returns {:error, reason} unchanged from adapter" do
      sup_name = start_invocation_supervisor(:invocation_error)

      request = %{prompt: "hello", context: %{}}
      {:ok, _pid, ref} = InvocationSupervisor.start_invocation(ErrorAdapter, request, self(), sup_name)

      assert_receive {:agent_runtime_invocation_complete, ^ref, result}

      # Adapter error is passed through unchanged
      assert result == {:error, :something_went_wrong}
    end
  end

  describe "crash isolation" do
    test "crashed invocation sends error to caller and terminates normally" do
      sup_name = start_invocation_supervisor(:invocation_crash)

      request = %{prompt: "hello", context: %{}}
      {:ok, _pid, ref} = InvocationSupervisor.start_invocation(CrashAdapter, request, self(), sup_name)

      assert_receive {:agent_runtime_invocation_complete, ^ref, result}

      # Should receive error tuple with module and reason
      assert {:error, {CrashAdapter, _reason}} = result
    end

    test "sibling invocations are unaffected by crash" do
      sup_name = start_invocation_supervisor(:invocation_sibling)

      # Start two invocations
      request = %{prompt: "hello", context: %{}}
      {:ok, _pid1, _ref1} = InvocationSupervisor.start_invocation(CrashAdapter, request, self(), sup_name)
      {:ok, _pid2, _ref2} = InvocationSupervisor.start_invocation(SuccessAdapter, request, self(), sup_name)

      # Both should complete (order may vary)
      results = for _ <- 1..2 do
        receive do
          {:agent_runtime_invocation_complete, _ref, result} -> result
        after 1000 -> flunk("timeout waiting for result")
        end
      end

      # One should be error (crash), one should be success
      assert length(results) == 2
      assert Enum.any?(results, fn
        {:ok, :success_adapter, _, _} -> true
        _ -> false
      end)
    end

    test "forced process crash does not restart and sibling completes" do
      sup_name = start_invocation_supervisor(:invocation_force_crash)
      test_pid = self()

      # Start first invocation (will block) - pass test_pid in context
      request = %{prompt: "hello", context: %{test_pid: test_pid}}
      {:ok, pid1, _ref1} = InvocationSupervisor.start_invocation(BlockingAdapter, request, self(), sup_name)

      # Wait for blocking adapter to start executing
      assert_receive {:blocking_adapter, :started}, 1000

      # Start sibling invocation concurrently (will complete)
      {:ok, pid2, ref2} = InvocationSupervisor.start_invocation(SuccessAdapter, request, self(), sup_name)

      # Now kill the blocked invocation
      monitor_ref = Process.monitor(pid1)
      Process.exit(pid1, :kill)

      # Wait for the EXIT signal
      receive do
        {:DOWN, ^monitor_ref, :process, ^pid1, :killed} -> :ok
      after 1000 -> flunk("timeout waiting for :DOWN")
      end

      # Verify no child was restarted (supervisor uses one_for_one with restart: :temporary)
      children = DynamicSupervisor.which_children(sup_name)
      assert children == []

      # Sibling should have completed despite sibling crash
      assert_receive {:agent_runtime_invocation_complete, ^ref2, result}
      assert {:ok, :success_adapter, _, _} = result

      # Verify no replacement was started for the killed process
      assert pid2 != pid1
    end
  end
end
