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
end
