import Config

# Operator settings for the Remote Jobsite API, read from the environment when
# the node boots (`mix phx.server`, `mix run`, or a release). Nothing here is
# set unless its variable is present, so an unset variable never overrides
# `dev.exs`/`prod.exs`, and the API stays off by default.
#
#   FOREMAN_API_TOKEN                        bearer token every /api/jobsites call must present
#   FOREMAN_JOBSITES_ALLOW_REMOTE_START=true allow POST /api/jobsites to start a jobsite
#   FOREMAN_JOBSITES_ALLOW_HOST_SANDBOX=true allow `"sandbox": "host"` (the agent runs unsandboxed
#                                            on this machine; the default is docker)
#   FOREMAN_JOBSITES_AGENT_ENV_ALLOWLIST=A,B comma-separated names a request may set in `agent.env`
#                                            (e.g. ANTHROPIC_API_KEY); empty/unset leaves the list as configured
#   FOREMAN_START_BEADS_WATCHER=true|false   start/stop BeadsWatcher auto-dispatch (dev.exs defaults to true)
#   FOREMAN_PR_MONITOR_ENABLED=true          poll GitHub for PR state of every run with an associated PR
#   FOREMAN_GITHUB_WEBHOOK_SECRET=<secret>   authenticate POST /webhooks/github (HMAC-SHA256); unset = endpoint refuses all deliveries
#
# Only the exact string `true` enables a flag. The test environment is left
# alone so a developer's shell cannot change a test's outcome.
if config_env() != :test do
  case System.get_env("FOREMAN_API_TOKEN") do
    token when token in [nil, ""] -> :ok
    token -> config :foreman_server, :api_bearer_token, token
  end

  jobsite_flags =
    for {key, var} <- [
          allow_remote_start: "FOREMAN_JOBSITES_ALLOW_REMOTE_START",
          allow_host_sandbox: "FOREMAN_JOBSITES_ALLOW_HOST_SANDBOX"
        ],
        System.get_env(var) != nil,
        do: {key, System.get_env(var) == "true"}

  if jobsite_flags != [], do: config(:foreman_server, :jobsites, jobsite_flags)

  case System.get_env("FOREMAN_JOBSITES_AGENT_ENV_ALLOWLIST") do
    value when value in [nil, ""] ->
      :ok

    value ->
      names = value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      config :foreman_server, :jobsites, agent_env_allowlist: names
  end

  # Unlike the flags above this one may switch BeadsWatcher off as well as on,
  # because dev.exs turns it on by default.
  case System.get_env("FOREMAN_START_BEADS_WATCHER") do
    nil -> :ok
    value -> config :foreman_server, :start_beads_watcher?, value == "true"
  end

  # Opt-in: only the exact string `true` starts the PR monitor.
  if System.get_env("FOREMAN_PR_MONITOR_ENABLED") == "true" do
    config :foreman_server, :pr_monitor_enabled, true
  end

  # The shared secret configured on the GitHub webhook. Without it the endpoint
  # answers 503 to everything (fail closed).
  case System.get_env("FOREMAN_GITHUB_WEBHOOK_SECRET") do
    secret when secret in [nil, ""] -> :ok
    secret -> config :foreman_server, :github_webhook_secret, secret
  end
end
