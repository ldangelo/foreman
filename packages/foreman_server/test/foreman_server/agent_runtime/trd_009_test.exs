defmodule ForemanServer.AgentRuntime.TRD009Test do
  @moduledoc """
  TRD-009-TEST — Verify privacy-safe runtime completion telemetry.

  AC for TRD-009-TEST (`docs/TRD/TRD-2026-6af02293-otp-agent-runtime.md`):

    "Given attached test handlers for success, direct failure, and fallback
     success, when executions complete, then one event per call has all
     required fields and no sensitive payload values."

  Each test attaches a telemetry handler to
  `[:foreman, :agent_runtime, :invocation, :complete]`, runs an execution
  through the AgentRuntime facade, and asserts:

    1. exactly one completion event fires per call;
    2. the event's measurements carry `%{duration_us, attempt_count}`;
    3. the event's metadata carries `%{status, task_type, attempted_backends,
       final_backend, successful_backend}`;
    4. prompt, context, adapter output, and adapter error strings never
       appear in the event payload.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime

  alias ForemanServer.AgentRuntime.{
    AdapterCatalog,
    BackendAdapter,
    InvocationSupervisor,
    Supervisor
  }

  alias ForemanServer.TestSupport.InvocationSupervisorHelpers

  # --- Adapters for the three AC paths ---

  defmodule SuccessAdapter do
    @behaviour BackendAdapter

    @impl true
    def name, do: :trd9_success

    @impl true
    def capabilities,
      do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: [:chat]}

    @impl true
    def available?, do: true

    @impl true
    def execute(_request, _opts), do: {:ok, "ok", %{}}
  end

  defmodule DirectFailureAdapter do
    @behaviour BackendAdapter

    @impl true
    def name, do: :trd9_direct_failure

    @impl true
    def capabilities,
      do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: [:chat]}

    @impl true
    def available?, do: true

    @impl true
    def execute(_request, _opts), do: {:error, :direct_failure_reason}
  end

  defmodule FallbackPrimaryFailsAdapter do
    @behaviour BackendAdapter

    @impl true
    def name, do: :trd9_fallback_primary

    @impl true
    def capabilities,
      do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: [:chat]}

    @impl true
    def available?, do: true

    @impl true
    def execute(_request, _opts), do: {:error, :primary_failed_marker}
  end

  defmodule FallbackSucceedsAdapter do
    @behaviour BackendAdapter

    @impl true
    def name, do: :trd9_fallback_success

    @impl true
    def capabilities,
      do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: [:chat]}

    @impl true
    def available?, do: true

    @impl true
    def execute(_request, _opts), do: {:ok, "fallback_output_marker", %{}}
  end

  # --- Test runtime helpers ---

  defp start_runtime do
    test_id = :rand.uniform(999_999)

    sup_name = :"AgentRuntime.Test.#{test_id}"
    catalog_name = :"Catalog#{test_id}"
    invocation_name = :"InvocationSupervisor#{test_id}"
    sup_id = :"agent_runtime_sup#{test_id}"

    sup_opts = [
      name: sup_name,
      adapter_catalog_name: catalog_name,
      invocation_supervisor_name: invocation_name,
      adapters: []
    ]

    InvocationSupervisorHelpers.schedule_erase()
    start_supervised!({Supervisor, sup_opts}, id: sup_id)
    {catalog_name, invocation_name}
  end

  defp gen_sentinel(prefix \\ "sentinel") do
    "#{prefix}_#{:erlang.unique_integer([:positive])}_#{System.unique_integer([:positive])}"
  end

  # Attach a handler to the completion event, run `fun`, then synchronously
  # drain every event the handler received while attached and detach.
  defp capture_completion_events(fun) do
    parent = self()
    handler_id = "trd-009-test-#{:rand.uniform(1_000_000_000)}"

    :telemetry.attach(
      handler_id,
      [:foreman, :agent_runtime, :invocation, :complete],
      fn event, measurements, metadata, _config ->
        send(parent, {:captured_event, event, measurements, metadata})
      end,
      nil
    )

    try do
      result = fun.()
      events = drain_events([])
      {events, result}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_events(acc) do
    receive do
      {:captured_event, event, measurements, metadata} ->
        drain_events([{event, measurements, metadata} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  # --- Acceptance criteria ---

  describe "AC-1 — success path emits exactly one completion event with all required fields" do
    test "all six required metadata fields + two measurements are present" do
      {catalog_name, invocation_name} = start_runtime()
      {:ok, _} = AdapterCatalog.register(SuccessAdapter, catalog_name)

      prompt = gen_sentinel("prompt")

      {events, _result} =
        capture_completion_events(fn ->
          AgentRuntime.execute(prompt, %{},
            strategy: :manual,
            backend: :trd9_success,
            task_type: :chat,
            catalog: catalog_name,
            invocation_supervisor: invocation_name
          )
        end)

      assert length(events) == 1
      {_, measurements, metadata} = hd(events)

      # Two measurements: duration_us, attempt_count
      assert is_integer(measurements.duration_us)
      assert measurements.duration_us >= 0
      assert is_integer(measurements.attempt_count)
      assert measurements.attempt_count == 1

      # Six metadata fields
      assert metadata.status == :ok
      assert metadata.task_type == :chat
      assert metadata.final_backend == :trd9_success
      assert metadata.successful_backend == :trd9_success
      assert is_list(metadata.attempted_backends)
      assert metadata.attempted_backends == [:trd9_success]
    end

    test "success event payload contains no sensitive strings" do
      {catalog_name, invocation_name} = start_runtime()
      {:ok, _} = AdapterCatalog.register(SuccessAdapter, catalog_name)

      prompt = gen_sentinel("prompt")
      secret_value = gen_sentinel("secret")
      context = %{private_key: secret_value, token: gen_sentinel("token")}

      {events, _result} =
        capture_completion_events(fn ->
          AgentRuntime.execute(prompt, context,
            strategy: :manual,
            backend: :trd9_success,
            task_type: :chat,
            catalog: catalog_name,
            invocation_supervisor: invocation_name
          )
        end)

      assert length(events) == 1
      {_, measurements, metadata} = hd(events)
      payload = inspect({measurements, metadata})

      for sensitive <- [prompt, "private_key", "token", secret_value] do
        refute String.contains?(payload, sensitive),
               "Sensitive string leaked into telemetry: #{sensitive}\npayload=#{payload}"
      end
    end
  end

  describe "AC-2 — direct failure path emits exactly one completion event with all required fields" do
    test "all six required metadata fields + two measurements are present" do
      {catalog_name, invocation_name} = start_runtime()
      {:ok, _} = AdapterCatalog.register(DirectFailureAdapter, catalog_name)

      prompt = gen_sentinel("prompt")

      {events, _result} =
        capture_completion_events(fn ->
          AgentRuntime.execute(prompt, %{},
            strategy: :manual,
            backend: :trd9_direct_failure,
            task_type: :chat,
            catalog: catalog_name,
            invocation_supervisor: invocation_name
          )
        end)

      assert length(events) == 1
      {_, measurements, metadata} = hd(events)

      assert is_integer(measurements.duration_us)
      assert is_integer(measurements.attempt_count)

      # Direct failure without fallback reaches the catch-all
      # `completion_fields({:error, _reason}, _)` clause.
      assert metadata.status in [:direct_error, :error]
      assert metadata.task_type == :chat
      assert metadata.final_backend == :trd9_direct_failure
      assert is_nil(metadata.successful_backend)
      assert metadata.attempted_backends == [:trd9_direct_failure]
    end

    test "direct failure event payload contains no sensitive strings" do
      {catalog_name, invocation_name} = start_runtime()
      {:ok, _} = AdapterCatalog.register(DirectFailureAdapter, catalog_name)

      prompt = gen_sentinel("prompt")
      secret_value = gen_sentinel("secret")
      context = %{secret: secret_value}

      {events, _result} =
        capture_completion_events(fn ->
          AgentRuntime.execute(prompt, context,
            strategy: :manual,
            backend: :trd9_direct_failure,
            task_type: :chat,
            catalog: catalog_name,
            invocation_supervisor: invocation_name
          )
        end)

      assert length(events) == 1
      {_, measurements, metadata} = hd(events)
      payload = inspect({measurements, metadata})

      for sensitive <- [prompt, "secret", secret_value] do
        refute String.contains?(payload, sensitive),
               "Sensitive string leaked into failure telemetry: #{sensitive}\npayload=#{payload}"
      end
    end
  end

  describe "AC-3 — fallback success path emits exactly one completion event with order preserved" do
    test "attempted_backends preserves execution order and identifies the successful backend" do
      {catalog_name, invocation_name} = start_runtime()
      {:ok, _} = AdapterCatalog.register(FallbackPrimaryFailsAdapter, catalog_name)
      {:ok, _} = AdapterCatalog.register(FallbackSucceedsAdapter, catalog_name)

      prompt = gen_sentinel("prompt")

      {events, _result} =
        capture_completion_events(fn ->
          AgentRuntime.execute(prompt, %{},
            strategy: :automatic,
            task_type: :chat,
            catalog: catalog_name,
            invocation_supervisor: invocation_name,
            fallback: true,
            max_attempts: 2
          )
        end)

      assert length(events) == 1
      {_, measurements, metadata} = hd(events)

      assert is_integer(measurements.duration_us)
      assert measurements.attempt_count == 2

      assert metadata.status == :ok
      assert metadata.task_type == :chat
      assert metadata.final_backend == :trd9_fallback_success
      assert metadata.successful_backend == :trd9_fallback_success
      assert metadata.attempted_backends == [:trd9_fallback_primary, :trd9_fallback_success]
    end

    test "fallback success event payload contains no sensitive strings" do
      {catalog_name, invocation_name} = start_runtime()
      {:ok, _} = AdapterCatalog.register(FallbackPrimaryFailsAdapter, catalog_name)
      {:ok, _} = AdapterCatalog.register(FallbackSucceedsAdapter, catalog_name)

      prompt = gen_sentinel("prompt")
      secret_value = gen_sentinel("private")
      context = %{private_key: secret_value}

      {events, _result} =
        capture_completion_events(fn ->
          AgentRuntime.execute(prompt, context,
            strategy: :automatic,
            task_type: :chat,
            catalog: catalog_name,
            invocation_supervisor: invocation_name,
            fallback: true,
            max_attempts: 2
          )
        end)

      assert length(events) == 1
      {_, measurements, metadata} = hd(events)
      payload = inspect({measurements, metadata})

      for sensitive <- [
            prompt,
            "private_key",
            secret_value,
            # FallbackSucceedsAdapter returns "fallback_output_marker" – must not escape.
            "fallback_output_marker",
            # FallbackPrimaryFailsAdapter returns :primary_failed_marker – must not escape.
            "primary_failed_marker"
          ] do
        refute String.contains?(payload, sensitive),
               "Sensitive string leaked into fallback success telemetry: #{sensitive}\npayload=#{payload}"
      end
    end
  end
end
