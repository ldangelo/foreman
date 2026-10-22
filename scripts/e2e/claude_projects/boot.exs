# Boots the Foreman server of the Claude Projects acceptance harness
# (scripts/e2e/claude_projects_flow.sh, scripts/e2e/failure_injection.sh):
#
#     elixir --name <node> --cookie <cookie> -S mix run --no-start --no-halt boot.exs
#
# Everything here is a RUNTIME override for this one node; no committed default changes.
# Environment (set by the harness): E2E_PORT, E2E_WORKFLOW_ROOT.

port = "E2E_PORT" |> System.fetch_env!() |> String.to_integer()

endpoint = Application.get_env(:foreman_server, ForemanServerWeb.Endpoint)

Application.put_env(
  :foreman_server,
  ForemanServerWeb.Endpoint,
  Keyword.merge(endpoint, http: [ip: {127, 0, 0, 1}, port: port], server: true, code_reloader: false)
)

# Scratch workflows (pi + minimax only) instead of the bundled ones, which pin a model this
# host cannot reach (foreman-pv11k).
Application.put_env(:foreman_server, :workflow_root, System.fetch_env!("E2E_WORKFLOW_ROOT"))

{:ok, _} = Application.ensure_all_started(:foreman_server)
IO.puts("E2E-SERVER-READY port=#{port} node=#{node()}")
