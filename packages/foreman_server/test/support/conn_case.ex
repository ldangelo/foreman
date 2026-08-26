defmodule ForemanServerWeb.ConnCase do
  @moduledoc """
  Phoenix.ConnTest wrapper for ForemanServerWeb.

  Phoenix does not ship a reusable `Phoenix.ConnCase` module; it generates one
  per project via `mix phx.gen.case`. We write it here following the same
  pattern: an ExUnit.CaseTemplate that injects `Phoenix.ConnTest`,
  `Plug.Conn`, and the `@endpoint`.

  Used by:
  - ForemanServerWeb.DashboardAuthTest
  - ForemanServerWeb.LiveDashboardTest / LiveDashboardViewsTest
  - ForemanServer.OperatorInboxLatencyRegressionTest
  - ForemanServer.Integration.AgentSignalToProjectionTest
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Phoenix.ConnTest
      import Plug.Conn

      @endpoint ForemanServerWeb.Endpoint
    end
  end
end
