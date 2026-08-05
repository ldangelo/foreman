defmodule ForemanServer.AgentRuntime.FailurePolicyTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.FailurePolicy

  # TRD-007 §Failure Policy and Attempt Semantics.
  #
  # Configuration lives under `:foreman_server, :agent_runtime` (TRD line 256)
  # with two relevant keys: `:default_timeout_ms` and `:failure_policies`
  # (a map keyed by task type).
  #
  # Per-call opts are passed positionally to `FailurePolicy.resolve/2`.

  defp with_rt_config(rt_config, fun) do
    original = Application.get_env(:foreman_server, :agent_runtime, [])

    try do
      Application.put_env(:foreman_server, :agent_runtime, rt_config)
      fun.()
    after
      Application.put_env(:foreman_server, :agent_runtime, original)
    end
  end

  defp rt(failure_policies, default_timeout_ms \\ 60_000) do
    [
      default_timeout_ms: default_timeout_ms,
      failure_policies: failure_policies
    ]
  end

  defp expected(fallback, max_attempts, timeout_ms) do
    %{
      fail_fast: true,
      fallback: fallback,
      max_attempts: max_attempts,
      timeout_ms: timeout_ms
    }
  end

  describe "resolve/2 — AC1: task-type config supplies fallback, max_attempts, and timeout_ms" do
    test "returns task-type configured fields as-is" do
      with_rt_config(
        rt(%{code_generation: %{fallback: true, max_attempts: 5, timeout_ms: 120_000}}),
        fn ->
          assert FailurePolicy.resolve(:code_generation, []) ==
                   expected(true, 5, 120_000)
        end
      )
    end

    test "task-type partial config — only :fallback present" do
      with_rt_config(
        rt(%{refactor: %{fallback: true}}, 30_000),
        fn ->
          assert FailurePolicy.resolve(:refactor, []) ==
                   expected(true, 2, 30_000)
        end
      )
    end
  end

  describe "resolve/2 — AC2: no task-type policy returns fail-fast, no fallback, one attempt, global timeout" do
    test "falls back to global defaults when task type has no entry" do
      with_rt_config(rt(%{}), fn ->
        assert FailurePolicy.resolve(:unknown_task, []) == expected(false, 1, 60_000)
      end)
    end

    test "returns the configured default_timeout_ms" do
      with_rt_config(rt(%{}, 45_000), fn ->
        assert FailurePolicy.resolve(:some_task, []).timeout_ms == 45_000
      end)
    end

    test "returns defaults when task_type is nil" do
      with_rt_config(rt(%{}), fn ->
        assert FailurePolicy.resolve(nil, []) == expected(false, 1, 60_000)
      end)
    end
  end

  describe "resolve/2 — AC3: fallback enabled at any layer without max_attempts → max_attempts is 2" do
    test "task-type fallback:true with no max_attempts → 2" do
      with_rt_config(rt(%{explain: %{fallback: true}}, 30_000), fn ->
        assert FailurePolicy.resolve(:explain, []) == expected(true, 2, 30_000)
      end)
    end

    test "per-call fallback:true with no max_attempts anywhere → 2" do
      with_rt_config(rt(%{}), fn ->
        assert FailurePolicy.resolve(:some_task, fallback: true) ==
                 expected(true, 2, 60_000)
      end)
    end

    test "explicit fallback:false stays at default max_attempts of 1" do
      with_rt_config(rt(%{test_task: %{fallback: false}}, 30_000), fn ->
        assert FailurePolicy.resolve(:test_task, []) == expected(false, 1, 30_000)
      end)
    end
  end

  describe "resolve/2 — AC4: per-call opts override task and global values" do
    test "per-call :fallback overrides task-type" do
      cfg = rt(%{code_generation: %{fallback: true, max_attempts: 5, timeout_ms: 120_000}})

      with_rt_config(cfg, fn ->
        assert FailurePolicy.resolve(:code_generation, fallback: false) ==
                 expected(false, 5, 120_000)
      end)
    end

    test "per-call :max_attempts overrides task-type" do
      cfg = rt(%{code_generation: %{fallback: true, max_attempts: 5, timeout_ms: 120_000}})

      with_rt_config(cfg, fn ->
        assert FailurePolicy.resolve(:code_generation, max_attempts: 10) ==
                 expected(true, 10, 120_000)
      end)
    end

    test "per-call :timeout_ms overrides task-type" do
      cfg = rt(%{code_generation: %{fallback: true, max_attempts: 5, timeout_ms: 120_000}})

      with_rt_config(cfg, fn ->
        assert FailurePolicy.resolve(:code_generation, timeout_ms: 5_000) ==
                 expected(true, 5, 5_000)
      end)
    end

    test "per-call opts as map override all fields" do
      cfg = rt(%{code_generation: %{fallback: true, max_attempts: 5, timeout_ms: 120_000}})

      with_rt_config(cfg, fn ->
        assert FailurePolicy.resolve(:code_generation, %{
                 fallback: false,
                 max_attempts: 3,
                 timeout_ms: 10_000
               }) == expected(false, 3, 10_000)
      end)
    end

    test "explicit per-call max_attempts is honored even when fallback is true at task layer" do
      with_rt_config(rt(%{test_task: %{fallback: true}}, 30_000), fn ->
        assert FailurePolicy.resolve(:test_task, max_attempts: 1) ==
                 expected(true, 1, 30_000)
      end)
    end

    test "3-layer precedence: per-call > task-type > global default" do
      # Global default_timeout_ms is 30_000 (NOT 60_000), so a non-overridden
      # field must surface that 30_000 — proving the global layer is consulted.
      task_cfg =
        rt(%{code_generation: %{fallback: true, max_attempts: 5, timeout_ms: 120_000}}, 30_000)

      with_rt_config(task_cfg, fn ->
        # Per-call sets only :fallback. timeout_ms comes from task-type (120k),
        # not from global default (30k). max_attempts comes from task-type (5).
        assert FailurePolicy.resolve(:code_generation, fallback: false) ==
                 expected(false, 5, 120_000)
      end)
    end

    test "2-layer precedence: task-type > global default when no per-call opts" do
      # Global timeout is 30_000; task-type omits :timeout_ms so it falls through.
      task_cfg = rt(%{code_generation: %{fallback: true, max_attempts: 5}}, 30_000)

      with_rt_config(task_cfg, fn ->
        assert FailurePolicy.resolve(:code_generation, []) ==
                 expected(true, 5, 30_000)
      end)
    end

    test "1-layer: global default_timeout_ms is the only contributor when no task-type, no per-call" do
      with_rt_config(rt(%{}, 75_000), fn ->
        assert FailurePolicy.resolve(:any_task, []) == expected(false, 1, 75_000)
      end)
    end
  end

  describe "resolve/2 — edge cases" do
    test "empty opts list works" do
      with_rt_config(rt(%{}), fn ->
        assert FailurePolicy.resolve(:task, []) == expected(false, 1, 60_000)
      end)
    end

    test "empty opts map works" do
      with_rt_config(rt(%{}), fn ->
        assert FailurePolicy.resolve(:task, %{}) == expected(false, 1, 60_000)
      end)
    end

    test "config without :default_timeout_ms uses 60_000" do
      Application.put_env(:foreman_server, :agent_runtime, failure_policies: %{})

      try do
        assert FailurePolicy.resolve(:task, []).timeout_ms == 60_000
      after
        Application.put_env(:foreman_server, :agent_runtime, [])
      end
    end
  end

  describe "integration with AgentRuntime facade" do
    test "failure_policy/2 delegates to FailurePolicy.resolve/2" do
      with_rt_config(
        rt(%{some_task: %{fallback: true, max_attempts: 3, timeout_ms: 45_000}}),
        fn ->
          assert ForemanServer.AgentRuntime.failure_policy(:some_task, []) ==
                   expected(true, 3, 45_000)
        end
      )
    end

    test "failure_policy/2 accepts keyword opts and applies fallback→max_attempts=2 rule" do
      with_rt_config(rt(%{}), fn ->
        # per-call fallback:true → max_attempts defaults to 2 (any layer)
        assert ForemanServer.AgentRuntime.failure_policy(:task, fallback: true) ==
                 expected(true, 2, 60_000)
      end)
    end
  end
end
