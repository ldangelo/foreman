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

# E2E_REVIEW_ANALYSIS=0 switches the automated review analysis off on this node (archives keep being
# written). The GitHub extras harness (scripts/e2e/github_live_extras.sh) sets it: no reviewer agent
# runs per terminal run and no gap bead (labelled `foreman-exec`, so dispatchable) appears in the
# scratch project's beads, which would start runs and open PRs the stages do not expect.
if System.get_env("E2E_REVIEW_ANALYSIS") == "0" do
  review = Application.get_env(:foreman_server, :review, [])
  Application.put_env(:foreman_server, :review, Keyword.put(review, :analysis, false))
end

{:ok, _} = Application.ensure_all_started(:foreman_server)
IO.puts("E2E-SERVER-READY port=#{port} node=#{node()}")
