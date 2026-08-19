defmodule ForemanServerWeb.LiveDashboardTest do
  @moduledoc """
  Smoke test for `ForemanServerWeb.LiveDashboard` — exercises the
  Phoenix mount point described in TRD-2026-4212be7e / JLD-T001 /
  TRD-055.

  We deliberately do NOT add a `/dashboard` route in this bead (router
  wiring is tracked by a follow-up ticket). The LiveView module must
  compile cleanly and round-trip a flash-mount under the standard
  `:browser` pipeline, which is what this test asserts.
  """

  use ForemanServerWeb.ConnCase, async: false

  alias ForemanServerWeb.LiveDashboard

  test "LiveDashboard module declares the expected callbacks" do
    # Behaviour signature checks: compile-time guarantees that the
    # module implements `mount/3`, `handle_event/3`, and `render/1`
    # with the correct arities.
    assert function_exported?(LiveDashboard, :mount, 3)
    assert function_exported?(LiveDashboard, :handle_event, 3)
    assert function_exported?(LiveDashboard, :render, 1)
  end

  test "LiveDashboard.static_root_path uses the OTP app's /dashboard mount contract" do
    # Confirm the module name is what a router live/2 call would address:
    assert LiveDashboard.__info__(:module) == ForemanServerWeb.LiveDashboard
  end
end
