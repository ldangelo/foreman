defmodule ForemanServerWeb.Router do
  use ForemanServerWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, false)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(ForemanServerWeb.Plugs.BearerAuth)
  end

  pipeline :require_authenticated do
    plug(ForemanServerWeb.Plugs.RequireAuthenticated)
  end

  forward("/mcp", ForemanServerWeb.MCPRouter, [])

  scope "/api", ForemanServerWeb do
    pipe_through(:api)

    post("/commands", CommandController, :create)
    get("/projects", ProjectController, :index)
    get("/projects/:id", ProjectController, :show)
    get("/tasks", TaskController, :index)
    get("/tasks/:id", TaskController, :show)
    get("/runs", RunController, :index)
    get("/runs/:id", RunController, :show)
    get("/queue", QueueController, :index)

    get("/work/:id", WorkController, :show)

    scope "/admin" do
      post("/workflows/install", WorkflowInstallController, :install)
      post("/workflows/remove", WorkflowInstallController, :remove)
    end
  end

  scope "/webhooks", ForemanServerWeb do
    post("/external_trigger", WebhookController, :external_trigger)
    post("/github", GithubWebhookController, :github)
    post("/operator/ingest", WebhookController, :operator_ingest)
  end

  if Mix.env() == :dev do
    scope "/debug", ForemanServerWeb do
      pipe_through(:browser)

      live("/", DebugDashboardLive, :index)
      live("/runs", DebugDashboardLive, :runs)
      live("/phases", DebugDashboardLive, :phases)
      live("/workers", DebugDashboardLive, :workers)
      live("/runs/:run_id", RunDebugLive, :show)
      live("/phases/:run_id/:phase_id", PhaseDebugLive, :show)
      live("/workers/:run_id/:worker_id", WorkerDebugLive, :show)
    end
  end

  # JLD-T001 / TRD-055: jido_live_dashboard mounted under browser auth +
  # the shared bearer-token guard (see ForemanServerWeb.LiveDashboard
  # moduledoc for the originally-documented wiring). Available in every
  # env (not dev-only) now that the auth guard is wired.
  scope "/dashboard", ForemanServerWeb do
    pipe_through([:browser, :require_authenticated])
    live("/", LiveDashboard)
  end
end
