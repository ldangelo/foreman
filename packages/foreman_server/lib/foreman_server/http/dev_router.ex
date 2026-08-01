defmodule ForemanServer.Http.DevRouter do
  @moduledoc "Development-only HTTP router: wraps the main router with Plug.Debugger for detailed error pages in dev."

  use Plug.Builder
  use Plug.Debugger, otp_app: :foreman_server
  plug ForemanServer.Http.Router
end
