defmodule ForemanServerWeb.Router do
  use ForemanServerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, false
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/webhooks", ForemanServerWeb do
    post "/external_trigger", WebhookController, :external_trigger
  end

  if Mix.env() == :dev do
    scope "/debug", ForemanServerWeb do
      pipe_through :browser

      live "/", DebugDashboardLive, :index
      live "/runs", DebugDashboardLive, :runs
      live "/phases", DebugDashboardLive, :phases
      live "/workers", DebugDashboardLive, :workers
      live "/runs/:run_id", RunDebugLive, :show
      live "/phases/:run_id/:phase_id", PhaseDebugLive, :show
      live "/workers/:run_id/:worker_id", WorkerDebugLive, :show
    end
  end
end
