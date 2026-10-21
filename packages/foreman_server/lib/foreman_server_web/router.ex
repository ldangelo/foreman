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

  # Fail-closed JSON pipeline with no local opt-in: `RequireAuthenticated` answers
  # 401 until an operator sets a token. `:api` (BearerAuth) is also fail-closed
  # when no token is configured, but honours `:api, allow_insecure_local: true`
  # (on in dev/test) to let local development call it without one.
  pipeline :jobsite_api do
    plug(:accepts, ["json"])
    plug(ForemanServerWeb.Plugs.RequireAuthenticated)
  end

  # GitHub authenticates a delivery with an HMAC over the raw body rather than a
  # bearer token. Fails closed: with no secret configured, nothing is accepted.
  pipeline :github_webhook do
    plug(ForemanServerWeb.Plugs.VerifyGithubSignature)
  end

  forward("/mcp", ForemanServerWeb.MCPRouter, [])

  scope "/api/jobsites", ForemanServerWeb do
    pipe_through(:jobsite_api)

    post("/", JobsiteController, :create)
    get("/", JobsiteController, :index)
    get("/:id", JobsiteController, :show)
    post("/:id/pause", JobsiteController, :pause)
    post("/:id/cancel", JobsiteController, :cancel)
    post("/:id/resume", JobsiteController, :resume)
    post("/:id/merge", JobsiteController, :merge)
  end

  scope "/api", ForemanServerWeb do
    pipe_through(:api)

    post("/commands", CommandController, :create)
    get("/projects", ProjectController, :index)
    get("/projects/:id", ProjectController, :show)
    get("/projects/:id/settings", ProjectController, :settings)
    get("/projects/:id/schedules", ProjectController, :schedules)
    get("/tasks", TaskController, :index)
    get("/tasks/:id", TaskController, :show)
    get("/runs", RunController, :index)
    get("/runs/:id", RunController, :show)
    get("/projects/:project_id/threads", ThreadController, :index)
    get("/projects/:project_id/threads/find", ThreadController, :find)
    get("/threads/:id", ThreadController, :show)
    get("/threads/:id/transcript", ThreadTranscriptController, :transcript)
    get("/threads/:id/stream", ThreadTranscriptController, :stream)
    post("/threads/:id/stop", ThreadController, :stop)
    post("/threads/:id/steer", ThreadController, :steer)
    get("/queue", QueueController, :index)

    scope "/admin" do
      post("/workflows/install", WorkflowInstallController, :install)
      post("/workflows/remove", WorkflowInstallController, :remove)
    end
  end

  scope "/webhooks", ForemanServerWeb do
    pipe_through(:github_webhook)

    post("/github", GithubWebhookController, :github)
  end

  scope "/webhooks", ForemanServerWeb do
    post("/external_trigger", WebhookController, :external_trigger)
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
    live("/runs", OperatorRunDashboardLive, :index)
  end
end
