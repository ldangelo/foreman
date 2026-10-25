import Config

# Operator settings for the Remote Jobsite API, read from the environment when
# the node boots (`mix phx.server`, `mix run`, or a release). Nothing here is
# set unless its variable is present, so an unset variable never overrides
# `dev.exs`/`prod.exs`, and the API stays off by default.
#
#   FOREMAN_API_TOKEN                        bearer token every /api call must present (unset = /api answers 401)
#   FOREMAN_API_ALLOW_INSECURE_LOCAL=true    with no token set, let /api through unauthenticated (local use only)
#   FOREMAN_JOBSITES_ALLOW_REMOTE_START=true allow POST /api/jobsites to start a jobsite
#   FOREMAN_JOBSITES_ALLOW_HOST_SANDBOX=true allow `"sandbox": "host"` (the agent runs unsandboxed
#                                            on this machine; the default is docker)
#   FOREMAN_JOBSITES_AGENT_ENV_ALLOWLIST=A,B comma-separated names a request may set in `agent.env`
#                                            (e.g. ANTHROPIC_API_KEY); empty/unset leaves the list as configured
#   FOREMAN_START_BEADS_WATCHER=true|false   start/stop BeadsWatcher auto-dispatch (dev.exs defaults to true)
#   FOREMAN_PR_MONITOR_ENABLED=true          poll GitHub for PR state of every run with an associated PR
#   FOREMAN_GITHUB_WEBHOOK_SECRET=<secret>   authenticate POST /webhooks/github (HMAC-SHA256); unset = endpoint refuses all deliveries
#   FOREMAN_NOTIFY_WEBHOOK_URL=<url>         send notifications to one webhook (https, public host unless opted out below)
#   FOREMAN_NOTIFY_WEBHOOK_ALLOW_INSECURE_HTTP=true
#   FOREMAN_NOTIFY_WEBHOOK_ALLOW_PRIVATE_HOSTS=true
#                                            accept an http:// URL / a loopback or private-network host for that webhook
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

  # Without a token /api answers 401 (fail closed); this lets an operator allow
  # unauthenticated access on a trusted local node. Unset changes nothing.
  api_flags =
    for {key, var} <- [allow_insecure_local: "FOREMAN_API_ALLOW_INSECURE_LOCAL"],
        System.get_env(var) != nil,
        do: {key, System.get_env(var) == "true"}

  if api_flags != [], do: config(:foreman_server, :api, api_flags)

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

  # PR watcher (E9): on by default; the exact string `false` turns it off.
  if System.get_env("FOREMAN_PR_WATCHER_ENABLED") == "false" do
    config :foreman_server, :pr_watcher, enabled: false
  end

  # Scheduled-task ticker: on by default (config.exs); "false" turns it off,
  # "true" forces it on.
  case System.get_env("FOREMAN_SCHEDULE_TICKER_ENABLED") do
    "true" -> config :foreman_server, :schedule, ticker_enabled: true
    "false" -> config :foreman_server, :schedule, ticker_enabled: false
    nil ->
      :ok

    other ->
      raise "FOREMAN_SCHEDULE_TICKER_ENABLED must be \"true\" or \"false\", got: #{inspect(other)}"
  end

  # Listen port override (acceptance runs and parallel dev servers). Only a
  # valid TCP port number is applied; anything else leaves dev.exs' port alone.
  case Integer.parse(System.get_env("FOREMAN_HTTP_PORT", "")) do
    {port, ""} when port in 1..65_535 ->
      config :foreman_server, ForemanServerWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: port]

    _ ->
      :ok
  end

  # Outbound notifications to one generic webhook (E10). Sets provider
  # `webhook`, enables delivery for every event class and takes the URL from
  # the variable; unset leaves any `config :foreman_server, :messaging` alone.
  # The URL must be https and name a public host. A receiver on plain http or on
  # the operator's own network (loopback included) needs the matching opt-in,
  # honoured only as the exact string `true`:
  # FOREMAN_NOTIFY_WEBHOOK_ALLOW_INSECURE_HTTP, FOREMAN_NOTIFY_WEBHOOK_ALLOW_PRIVATE_HOSTS.
  case System.get_env("FOREMAN_NOTIFY_WEBHOOK_URL") do
    url when url in [nil, ""] ->
      :ok

    url ->
      config :foreman_server, :messaging,
        enabled: true,
        provider: :webhook,
        event_classes: [:collab_url, :action_needed, :stall, :failure, :run_update],
        run_update_rate_limit_ms: 0,
        webhook: %{
          url: url,
          allow_insecure_http:
            System.get_env("FOREMAN_NOTIFY_WEBHOOK_ALLOW_INSECURE_HTTP") == "true",
          allow_private_hosts:
            System.get_env("FOREMAN_NOTIFY_WEBHOOK_ALLOW_PRIVATE_HOSTS") == "true"
        }
  end

  # The fixed reviewer agent (`config :foreman_server, :review, agent:`). Only
  # `claude` and `pi` are providers the harness knows; an empty variable leaves
  # config.exs' default (claude) in force.
  case System.get_env("FOREMAN_REVIEW_PROVIDER", "") do
    provider when provider in ["claude", "pi"] ->
      config :foreman_server, :review,
        agent: %{
          provider: if(provider == "pi", do: :pi, else: :claude),
          model:
            System.get_env("FOREMAN_REVIEW_MODEL", "") |> then(&if(&1 == "", do: nil, else: &1)),
          effort: nil
        }

    _ ->
      :ok
  end

  # Where PR fix-thread jobsites run (`config :foreman_server, :pr_fix, sandbox:`).
  # Unset leaves the jobsite default (docker). `host` runs the agent unsandboxed on
  # this machine; it additionally needs FOREMAN_JOBSITES_ALLOW_HOST_SANDBOX=true.
  case System.get_env("FOREMAN_PR_FIX_SANDBOX", "") do
    sandbox when sandbox in ["docker", "host"] ->
      config :foreman_server, :pr_fix, sandbox: sandbox

    _ ->
      :ok
  end

  # The shared secret configured on the GitHub webhook. Without it the endpoint
  # answers 503 to everything (fail closed).
  case System.get_env("FOREMAN_GITHUB_WEBHOOK_SECRET") do
    secret when secret in [nil, ""] -> :ok
    secret -> config :foreman_server, :github_webhook_secret, secret
  end
end
