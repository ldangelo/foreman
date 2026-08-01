defmodule ForemanServerWeb.Router do
  @moduledoc false

  use Phoenix.Router

  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ForemanServerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :debug_only do
    plug ForemanServerWeb.Plugs.DebugOnly
  end

  scope "/debug" do
    pipe_through [:browser, :debug_only]

    live_session :debug, layout: {ForemanServerWeb.Layouts, :app} do
      live "/runs", ForemanServerWeb.Debug.RunLive
      live "/phases", ForemanServerWeb.Debug.PhaseLive
      live "/workers", ForemanServerWeb.Debug.WorkerLive
    end
  end

  forward "/", ForemanServer.Http.Router
end
