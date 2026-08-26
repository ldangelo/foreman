defmodule ForemanServer.TaskProvider.RegistryAppStartTest do
  @moduledoc """
  App-start wiring test for `ForemanServer.TaskProvider.Registry`.

  Stateful test files under `task_provider/`, `task_providers/`, `workflow/`,
  `architecture/`, and `cli/` are designed to run with `mix test --no-start`:
  each test owns the Registry via `start_supervised!/1` so it can configure a
  fresh routing snapshot. This file is the **one** slice test that exercises
  the application-supervision path: it asserts the Registry booted from
  `Application.get_env(:foreman_server, :task_provider)` and serves routing
  through the canonical read-only public API. It must NOT mutate the
  application-supervised Registry.

  Must be run with the application started (`mix test`, NOT `--no-start`).
  Running with `--no-start` will fail because the supervised Registry is not
  present.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProviders.BeadsAdapter

  test "Registry GenServer is running under its canonical name (app supervision)" do
    pid = Process.whereis(Registry)

    assert is_pid(pid),
           "Registry GenServer must be supervised and registered under its canonical name"

    state = :sys.get_state(pid)
    assert is_map(state.routing)
    assert is_list(state.accepted_versions)
    assert is_map(state.per_project)
  end

  test "Registry boot snapshot loaded BeadsAdapter under :beads from Application config" do
    pid = Process.whereis(Registry)
    assert is_pid(pid)

    state = :sys.get_state(pid)

    assert state.routing[:beads] == BeadsAdapter,
           "expected BeadsAdapter to be registered under the :beads routing key from boot config (got: #{inspect(state.routing)})"
  end

  test "routing_snapshot/0 returns the boot-loaded BeadsAdapter under :beads" do
    snapshot = Registry.routing_snapshot()

    assert snapshot[:beads] == BeadsAdapter,
           "expected :beads routing key to map to BeadsAdapter (got: #{inspect(snapshot)})"
  end

  test "route/2 returns the booted BeadsAdapter for :claim + :beads routing key" do
    assert {:ok, BeadsAdapter} = Registry.route(:claim, :beads)
  end

  test "route/2 returns {:error, :no_provider_for_transition} for unsupported transition" do
    assert {:error, :no_provider_for_transition} =
             Registry.route(:nonexistent_transition, :beads)
  end

  test "route/2 returns {:error, :no_provider_for_transition} for mismatched routing key" do
    assert {:error, :no_provider_for_transition} =
             Registry.route(:claim, :nonexistent_provider)
  end
end
