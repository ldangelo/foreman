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
#   FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN=<token> + FOREMAN_NOTIFY_TELEGRAM_CHAT_ID=<id>
#                                            send notifications through a Telegram bot (both required together)
#   FOREMAN_NOTIFY_SLACK_WEBHOOK_URL=<url>   send notifications to a Slack incoming webhook (https, public host, no opt-outs)
#
# At most one of the webhook, Telegram and Slack variables may be set: the node
# has one notification provider, so a mix aborts boot instead of picking one.
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
    "true" ->
      config :foreman_server, :schedule, ticker_enabled: true

    "false" ->
      config :foreman_server, :schedule, ticker_enabled: false

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

  # Outbound notifications (E10): one provider, chosen by which variables are set.
  # Each enables delivery for every event class with no run-update rate limit;
  # none set leaves any `config :foreman_server, :messaging` alone. Empty counts
  # as unset. Secrets (the bot token, the Slack URL) go into config only and are
  # never logged: a refusal names the variable, never its value.
  #
  # webhook: the URL must be https and name a public host. A receiver on plain
  # http or on the operator's own network (loopback included) needs the matching
  # opt-in, honoured only as the exact string `true`:
  # FOREMAN_NOTIFY_WEBHOOK_ALLOW_INSECURE_HTTP, FOREMAN_NOTIFY_WEBHOOK_ALLOW_PRIVATE_HOSTS.
  # slack: the URL is held to the same https/public-host rules with no opt-outs
  # (`ConfigResolver` at resolve time, the Slack provider before each send).
  non_empty_env = fn name ->
    case System.get_env(name) do
      value when value in [nil, ""] -> nil
      value -> value
    end
  end

  notify_all = [
    enabled: true,
    event_classes: [:collab_url, :action_needed, :stall, :failure, :run_update],
    run_update_rate_limit_ms: 0
  ]

  telegram_token_var = "FOREMAN_NOTIFY_TELEGRAM_BOT_TOKEN"
  telegram_chat_var = "FOREMAN_NOTIFY_TELEGRAM_CHAT_ID"

  notify_providers =
    for {provider, vars} <- [
          webhook: ["FOREMAN_NOTIFY_WEBHOOK_URL"],
          telegram: [telegram_token_var, telegram_chat_var],
          slack: ["FOREMAN_NOTIFY_SLACK_WEBHOOK_URL"]
        ],
        Enum.any?(vars, &non_empty_env.(&1)),
        do: {provider, vars}

  case notify_providers do
    [] ->
      :ok

    [_, _ | _] = several ->
      vars = several |> Enum.flat_map(&elem(&1, 1)) |> Enum.filter(&non_empty_env.(&1))

      raise "notification variables for more than one provider are set (#{Enum.join(vars, ", ")}); " <>
              "the node has one notification provider - unset all but one provider's variables"

    [{:webhook, _}] ->
      config :foreman_server,
             :messaging,
             notify_all ++
               [
                 provider: :webhook,
                 webhook: %{
                   url: non_empty_env.("FOREMAN_NOTIFY_WEBHOOK_URL"),
                   allow_insecure_http:
                     System.get_env("FOREMAN_NOTIFY_WEBHOOK_ALLOW_INSECURE_HTTP") == "true",
                   allow_private_hosts:
                     System.get_env("FOREMAN_NOTIFY_WEBHOOK_ALLOW_PRIVATE_HOSTS") == "true"
                 }
               ]

    [{:telegram, _}] ->
      token = non_empty_env.(telegram_token_var)
      chat_id = non_empty_env.(telegram_chat_var)

      if is_nil(token) or is_nil(chat_id) do
        raise "#{telegram_token_var} and #{telegram_chat_var} must be set together"
      end

      config :foreman_server,
             :messaging,
             notify_all ++ [provider: :telegram, telegram: %{token: token, chat_id: chat_id}]

    [{:slack, _}] ->
      config :foreman_server,
             :messaging,
             notify_all ++
               [
                 provider: :slack,
                 slack: %{webhook_url: non_empty_env.("FOREMAN_NOTIFY_SLACK_WEBHOOK_URL")}
               ]
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
