# Boots the Foreman server of the live Claude + in-flight approvals harness
# (scripts/e2e/live_claude/stack.sh):
#
#     elixir --name <node> --cookie <cookie> -S mix run --no-start --no-halt boot.exs
#
# Everything here is a RUNTIME override for this one node; no committed default changes.
# Environment (set by the harness): E2E_PORT, E2E_WORKFLOW_ROOT; optional approvals tuning
# E2E_APPROVAL_TIMEOUT_MS, E2E_INFLIGHT_PROGRESS_MS, E2E_SWEEP_INTERVAL_MS (milliseconds).

port = "E2E_PORT" |> System.fetch_env!() |> String.to_integer()

endpoint = Application.get_env(:foreman_server, ForemanServerWeb.Endpoint)

Application.put_env(
  :foreman_server,
  ForemanServerWeb.Endpoint,
  Keyword.merge(endpoint, http: [ip: {127, 0, 0, 1}, port: port], server: true, code_reloader: false)
)

# Scratch workflows (claude phases) instead of the bundled ones.
Application.put_env(:foreman_server, :workflow_root, System.fetch_env!("E2E_WORKFLOW_ROOT"))

approvals =
  [
    {:approval_timeout_ms, "E2E_APPROVAL_TIMEOUT_MS"},
    {:inflight_progress_ms, "E2E_INFLIGHT_PROGRESS_MS"},
    {:sweep_interval_ms, "E2E_SWEEP_INTERVAL_MS"}
  ]
  |> Enum.flat_map(fn {key, var} ->
    case System.get_env(var) do
      nil -> []
      value -> [{key, String.to_integer(value)}]
    end
  end)

if approvals != [] do
  Application.put_env(
    :foreman_server,
    :approvals,
    Keyword.merge(Application.get_env(:foreman_server, :approvals, []), approvals)
  )
end

{:ok, _} = Application.ensure_all_started(:foreman_server)
IO.puts("E2E-SERVER-READY port=#{port} node=#{node()} approvals=#{inspect(approvals)}")
