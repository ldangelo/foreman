defmodule ForemanServer.TestSupport.InvocationSupervisorHelpers do
  @moduledoc """
  Helpers for tests that mint a custom-named
  `ForemanServer.AgentRuntime.InvocationSupervisor`.

  The production module caches the most-recent supervisor's registry
  name in a `:persistent_term` slot keyed by
  `{ForemanServer.AgentRuntime.InvocationSupervisor, :registry_name}`.

  A test that brings up a custom-named supervisor overwrites that
  slot with a name that, after the test exits and `start_supervised!`
  tears the supervisor (and its `Registry`) down, points at a
  registry that no longer exists. The next test that triggers
  `Registry.register/3` against that supervisor fails with
  `(ArgumentError) unknown registry`.

  Fix: capture whatever was in the persistent-term slot before the
  test starts; restore it (or clear it, if there was no previous
  value) when the test exits. Without a restore, the production
  default-named supervisor loses its bookkeeping pointer the moment
  a custom-named test starts (the leak chain).

  Use `start/2` instead of `start_supervised!` whenever a test
  starts a named `InvocationSupervisor` directly. Use
  `schedule_preserve/0` in tests that bring up a parent
  `AgentRuntime.Supervisor` with `invocation_supervisor_name:`
  child — that path doesn't go through `start/2` but still leaks
  the same `persistent_term` key.
  """

  @registry_key {ForemanServer.AgentRuntime.InvocationSupervisor, :registry_name}

  @doc "Like `ExUnit.Callbacks.start_supervised!/2`, but preserves the InvocationSupervisor persistent-term key across the test."
  @spec start(Supervisor.child_spec() | {module(), keyword()}, keyword()) ::
          Supervisor.on_start()
  def start(child_spec, opts \\ []) do
    snapshot = read_persistent_term()
    ExUnit.Callbacks.on_exit(fn -> restore(snapshot) end)
    ExUnit.Callbacks.start_supervised!(child_spec, opts)
  end

  @spec start_link(Supervisor.child_spec() | {module(), keyword()}, keyword()) ::
          Supervisor.on_start()
  def start_link(child_spec, opts \\ []) do
    snapshot = read_persistent_term()
    ExUnit.Callbacks.on_exit(fn -> restore(snapshot) end)
    ExUnit.Callbacks.start_supervised!(child_spec, opts)
  end

  @doc """
  Capture the current `:persistent_term` InvocationSupervisor slot and
  install an `on_exit` that restores it (or clears it) when the test
  ends. Use this in tests that bring up a parent
  `AgentRuntime.Supervisor` with `invocation_supervisor_name:` so
  the nested `InvocationSupervisor`'s bookkeeping doesn't leak
  across test boundaries.
  """
  @spec schedule_preserve(keyword()) :: :ok
  def schedule_preserve(_opts \\ []) do
    snapshot = read_persistent_term()
    ExUnit.Callbacks.on_exit(fn -> restore(snapshot) end)
    :ok
  end

  # Backwards-compatible alias used in earlier edits.
  @deprecated "Use schedule_preserve/1 instead"
  def schedule_erase(opts \\ []), do: schedule_preserve(opts)

  defp read_persistent_term do
    case :persistent_term.get(@registry_key, :__not_set__) do
      :__not_set__ -> :__not_set__
      value -> value
    end
  end

  defp restore(:__not_set__) do
    _ = :persistent_term.erase(@registry_key)
    :ok
  end

  defp restore(value) do
    :persistent_term.put(@registry_key, value)
    :ok
  end
end
