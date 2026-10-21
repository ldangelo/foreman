# Boots the Foreman server of the live multi-repo harness (scripts/e2e/multi_repo.sh):
#
#     elixir --name <node> --cookie <cookie> -S mix run --no-start --no-halt boot.exs
#
# Everything below is a RUNTIME override for this one node. Nothing here (nor any
# flag the harness sets) changes a committed default: the multi-repo run gate
# stays whatever config/config.exs says for every other node.
#
# Environment (all set by the harness): E2E_PORT, E2E_WORKFLOW_ROOT.

port = "E2E_PORT" |> System.fetch_env!() |> String.to_integer()

endpoint = Application.get_env(:foreman_server, ForemanServerWeb.Endpoint)

Application.put_env(
  :foreman_server,
  ForemanServerWeb.Endpoint,
  Keyword.merge(endpoint,
    http: [ip: {127, 0, 0, 1}, port: port],
    server: true,
    code_reloader: false
  )
)

# The run-start gate, set explicitly for this live node so the harness never depends on the
# committed default. It is toggled again at runtime (`Application.put_env` over
# `--rpc-eval`) by the `gate` stage to prove the refusal path.
Application.put_env(:foreman_server, :multi_repo, runs: true)

# Scratch workflows live under the harness work dir, not ~/.foreman/workflows.
Application.put_env(:foreman_server, :workflow_root, System.fetch_env!("E2E_WORKFLOW_ROOT"))

# The automated review analyzer would launch a second agent (default `claude`) after
# every run. Archive capture (diff.patch, diffs/<repo>.patch, manifest) stays on: it is
# what the harness asserts. Read at application start, so it must be set before it.
review = Application.get_env(:foreman_server, :review, [])
Application.put_env(:foreman_server, :review, Keyword.put(review, :analysis, false))

# Read-only probes the harness calls over `--rpc-eval` (a distribution cookie is
# the only thing that can reach them).
Code.require_file("probe.exs", __DIR__)

{:ok, _} = Application.ensure_all_started(:foreman_server)
IO.puts("E2E-SERVER-READY port=#{port} node=#{node()} multi_repo=#{inspect(Application.get_env(:foreman_server, :multi_repo))}")
