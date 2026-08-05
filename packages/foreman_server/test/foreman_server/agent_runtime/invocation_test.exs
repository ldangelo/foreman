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

  defmodule UnavailableForInvocationAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :unavailable_for_invocation
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
    def available?, do: false
    @impl true
    def execute(_req, _opts), do: flunk("unavailable adapter must not be invoked")
  end

  # Helper to start supervisor with unique name
  defp start_invocation_supervisor(id) do
    name = :"InvocationSupervisor.Test.#{id}"
    start_supervised!({InvocationSupervisor, [name: name]}, id: id)
    name
  end

  # Default policy for tests
  defp default_policy do
    %{fail_fast: true, fallback: false, max_attempts: 1, timeout_ms: 60_000}
  end

  describe "success path" do
    test "returns {:ok, content} normalized from invocation result" do
      sup_name = start_invocation_supervisor(:invocation_success)

      request = %{prompt: "hello", context: %{}}
      policy = default_policy()
      candidates = [{SuccessAdapter, true}]

      {:ok, _pid, ref} =
        InvocationSupervisor.start_invocation(candidates, policy, request, self(), sup_name)

      assert_receive {:agent_runtime_invocation_complete, ^ref, result}

      # Result is now normalized to 2-tuple: {:ok, content}
      assert result == {:ok, "success response"}
    end
  end

  describe "error path" do
    test "returns {:error, reason} unchanged from adapter" do
      sup_name = start_invocation_supervisor(:invocation_error)

      request = %{prompt: "hello", context: %{}}
      policy = default_policy()
      candidates = [{ErrorAdapter, true}]

      {:ok, _pid, ref} =
        InvocationSupervisor.start_invocation(candidates, policy, request, self(), sup_name)

      assert_receive {:agent_runtime_invocation_complete, ^ref, result}

      # Adapter error is passed through unchanged
      assert result == {:error, :something_went_wrong}
    end
  end

  describe "crash isolation" do
    test "crashed invocation sends error to caller and terminates normally" do
      sup_name = start_invocation_supervisor(:invocation_crash)

      request = %{prompt: "hello", context: %{}}
      policy = default_policy()
      candidates = [{CrashAdapter, true}]

      {:ok, _pid, ref} =
        InvocationSupervisor.start_invocation(candidates, policy, request, self(), sup_name)

      assert_receive {:agent_runtime_invocation_complete, ^ref, result}

      # Should receive error tuple with module and reason
      assert {:error, {CrashAdapter, _reason}} = result
    end

    test "sibling invocations are unaffected by crash" do
      sup_name = start_invocation_supervisor(:invocation_sibling)

      # Start two invocations
      request = %{prompt: "hello", context: %{}}
      policy = default_policy()

      candidates1 = [{CrashAdapter, true}]
      candidates2 = [{SuccessAdapter, true}]

      {:ok, _pid1, _ref1} =
        InvocationSupervisor.start_invocation(candidates1, policy, request, self(), sup_name)

      {:ok, _pid2, _ref2} =
        InvocationSupervisor.start_invocation(candidates2, policy, request, self(), sup_name)

      # Both should complete (order may vary)
      results =
        for _ <- 1..2 do
          receive do
            {:agent_runtime_invocation_complete, _ref, result} -> result
          after
            1000 -> flunk("timeout waiting for result")
          end
        end

      # One should be error (crash), one should be success
      assert length(results) == 2

      assert Enum.any?(results, fn
               {:ok, _content} -> true
               _ -> false
             end)
    end

    test "forced process crash does not restart and sibling completes" do
      sup_name = start_invocation_supervisor(:invocation_force_crash)
      test_pid = self()

      # Start first invocation (will block) - pass test_pid in context
      request = %{prompt: "hello", context: %{test_pid: test_pid}}
      policy = default_policy()

      candidates1 = [{BlockingAdapter, true}]

      {:ok, pid1, _ref1} =
        InvocationSupervisor.start_invocation(candidates1, policy, request, self(), sup_name)

      # Wait for blocking adapter to start executing
      assert_receive {:blocking_adapter, :started}, 1000

      # Start sibling invocation concurrently (will complete)
      candidates2 = [{SuccessAdapter, true}]

      {:ok, pid2, ref2} =
        InvocationSupervisor.start_invocation(candidates2, policy, request, self(), sup_name)

      # Now kill the blocked invocation
      monitor_ref = Process.monitor(pid1)
      Process.exit(pid1, :kill)

      # Wait for the EXIT signal
      receive do
        {:DOWN, ^monitor_ref, :process, ^pid1, :killed} -> :ok
      after
        1000 -> flunk("timeout waiting for :DOWN")
      end

      # Verify no child was restarted (supervisor uses one_for_one with restart: :temporary)
      children = DynamicSupervisor.which_children(sup_name)
      assert children == []

      # Sibling should have completed despite sibling crash
      assert_receive {:agent_runtime_invocation_complete, ^ref2, result}
      assert {:ok, "success response"} = result

      # Verify no replacement was started for the killed process
      assert pid2 != pid1
    end
  end

  describe "fallback exhaustion" do
    test "fallback: true with one available candidate that fails returns :all_backends_failed" do
      sup_name = start_invocation_supervisor(:invocation_exhaust_single)

      request = %{prompt: "hello", context: %{}}
      policy = %{fail_fast: true, fallback: true, max_attempts: 1, timeout_ms: 60_000}
      candidates = [{ErrorAdapter, true}]

      {:ok, _pid, ref} =
        InvocationSupervisor.start_invocation(candidates, policy, request, self(), sup_name)

      assert_receive {:agent_runtime_invocation_complete, ^ref, result}

      # AC 3 holds even when only one allowed attempt was recorded.
      assert {:error, :all_backends_failed, %{attempts: attempts}} = result
      assert length(attempts) == 1
      assert {:error, :error_adapter, :something_went_wrong} = hd(attempts)
    end

    test "fallback: true with mixed available/unavailable candidates returns :all_backends_failed" do
      sup_name = start_invocation_supervisor(:invocation_exhaust_mixed)

      request = %{prompt: "hello", context: %{}}
      policy = %{fail_fast: true, fallback: true, max_attempts: 2, timeout_ms: 60_000}

      # ErrorAdapter is available and fails; ManualUnavailableAdapter is unavailable.
      # The unavailable candidate must be skipped (not recorded); the one available
      # candidate fails → all attempted failed → :all_backends_failed.
      candidates = [{ErrorAdapter, true}, {UnavailableForInvocationAdapter, false}]

      {:ok, _pid, ref} =
        InvocationSupervisor.start_invocation(candidates, policy, request, self(), sup_name)

      assert_receive {:agent_runtime_invocation_complete, ^ref, result}

      assert {:error, :all_backends_failed, %{attempts: attempts}} = result
      assert length(attempts) == 1
      assert {:error, :error_adapter, :something_went_wrong} = hd(attempts)
    end

    test "fallback: false with one available candidate that fails returns direct error" do
      sup_name = start_invocation_supervisor(:invocation_no_fallback_fail)

      request = %{prompt: "hello", context: %{}}
      policy = default_policy()
      candidates = [{ErrorAdapter, true}]

      {:ok, _pid, ref} =
        InvocationSupervisor.start_invocation(candidates, policy, request, self(), sup_name)

      assert_receive {:agent_runtime_invocation_complete, ^ref, result}

      # Per AC 2: fallback disabled → direct error, no :all_backends_failed wrapping.
      assert result == {:error, :something_went_wrong}
    end
  end
end
