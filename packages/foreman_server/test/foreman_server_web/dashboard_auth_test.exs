defmodule ForemanServerWeb.DashboardAuthTest do
  use ForemanServerWeb.ConnCase, async: false

  test "unauthenticated request gets redirect or 401" do
    conn = build_conn() |> get("/dashboard")
    assert conn.status in [302, 401, 403]
  end
end
