defmodule ForemanServer.TestSupport.MeckScope do
  @moduledoc """
  Creates a `:meck` passthrough mock once per test module and restores it between tests.

  `:meck.new(mod, [:passthrough])` rebuilds a full copy of `mod` as the "original" the
  passthrough forwards to. For a huge module such as `ForemanServer.ProjectionStore`
  (5.5k lines) that costs over a second, so doing it in every test's `setup` dominated the
  runtime of the dispatcher test modules.

  Usage:

      setup_all do
        MeckScope.new_once!([ForemanServer.ProjectionStore])
      end

      setup do
        MeckScope.restore_on_exit!([ForemanServer.ProjectionStore])
      end

  `new_once!/2` registers an `on_exit` (run when the module ends, not per test) that unloads
  the mocks, so nothing leaks into the next module. `restore!/1` deletes every user
  expectation (a deleted function on a passthrough mock calls the real implementation again)
  and clears the call history. It does not depend on `:meck.validate/1`, so an expectation
  that raised cannot poison the next test.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @type mocks :: module() | [module()]

  @doc """
  Creates passthrough mocks for `mods`. Call from `setup_all`; the mocks are unloaded when the
  test module finishes. Returns `:ok` so it can be the last expression of the callback.

  `opts` defaults to `[:no_link, :passthrough]`.
  """
  @spec new_once!(mocks(), [atom()]) :: :ok
  def new_once!(mods, opts \\ [:no_link, :passthrough]) do
    mods = List.wrap(mods)
    Enum.each(mods, &:meck.new(&1, opts))
    on_exit(fn -> unload!(mods) end)
    :ok
  end

  @doc """
  Removes every user expectation from the mocks and clears their call history, so the next test
  sees the real functions and no recorded calls.
  """
  @spec restore!(mocks()) :: :ok
  def restore!(mods) do
    mods = List.wrap(mods)

    for {mod, fun, arity} <- :meck.expects(mods, true) do
      :meck.delete(mod, fun, arity)
    end

    :meck.reset(mods)
    :ok
  end

  @doc """
  Registers `restore!/1` as an `on_exit` of the current test. Call from `setup`.
  """
  @spec restore_on_exit!(mocks()) :: :ok
  def restore_on_exit!(mods) do
    on_exit(fn -> restore!(mods) end)
    :ok
  end

  defp unload!(mods) do
    Enum.each(mods, fn mod ->
      try do
        :meck.unload(mod)
      catch
        :exit, _ -> :ok
      end
    end)
  end
end
