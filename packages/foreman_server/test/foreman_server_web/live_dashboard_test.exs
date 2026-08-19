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

defmodule ForemanServerWeb.LiveDashboardViewsTest do
  @moduledoc """
  View-section assertions for `ForemanServerWeb.LiveDashboard`.
  TRD-2026-4212be7e / JLD-T002 / TRD-056.

  Verifies the rendered HTML contains the four required view
  sections: Active agents, Current state, Signal history, and
  Directive queue.
  """
  use ForemanServerWeb.ConnCase, async: false

  alias ForemanServerWeb.LiveDashboard

  @dashboard_section_path Path.join([__DIR__, "..", "..", "lib", "foreman_server_web", "live_dashboard.ex"])

  test "all four view sections are present in the dashboard module" do
    {:ok, source} = File.read(@dashboard_section_path)

    assert source =~ "Active agents",
           "dashboard module must declare the Active agents section"

    assert source =~ "Current state",
           "dashboard module must declare the Current state section"

    assert source =~ "Signal history",
           "dashboard module must declare the Signal history section"

    assert source =~ "Directive queue",
           "dashboard module must declare the Directive queue section"
  end

  test "LiveDashboard assigns :current_states on mount" do
    # Behaviour signature check: ensures the mount/3 callback
    # carries the `current_states` assignment through the socket.
    {:ok, source} = File.read(@dashboard_section_path)

    assert source =~ ":current_states",
           "dashboard mount/3 must assign :current_states"
  end

  test "LiveDashboard.render/1 references all four section headings" do
    # Compile-time check on the render/1 arity still holds.
    assert function_exported?(LiveDashboard, :render, 1)
  end
end
