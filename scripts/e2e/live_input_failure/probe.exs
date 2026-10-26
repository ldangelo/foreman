# One scenario of scripts/e2e/live_input_failure.sh, run inside packages/jido_harness:
#
#     mix run ../../scripts/e2e/live_input_failure/probe.exs <scenario> <deadline_s> <work_dir> <model>
#
# Starts REAL pi through Jido.Harness for a turn that can never succeed and reports how the run ended.
# Scenarios:
#   bogus-key-live    live_input (pi --mode rpc), an API key the provider rejects: the turn fails (401)
#   no-key-live       live_input, no credentials at all: pi answers the prompt with a failed response
#   bogus-key-plain   control, no live_input (pi --mode json): a failed turn always ended the run
#
# Prints one `RESULT ...` line; exits 0 when the run ended `failed` inside the deadline, 1 otherwise
# (`HUNG` = still running at the deadline, the bug this guards).
[scenario, deadline_s, work_dir, model] = System.argv()
deadline_ms = String.to_integer(deadline_s) * 1000

{:ok, _} = Application.ensure_all_started(:jido_harness)

agent_dir = Path.join(work_dir, "pi-agent-#{scenario}")
cwd = Path.join(work_dir, "cwd-#{scenario}")
File.mkdir_p!(agent_dir)
File.mkdir_p!(cwd)

# The model's provider names the API key variable: `minimax/MiniMax-M2.7-highspeed` -> MINIMAX_API_KEY.
key_env = model |> String.split("/") |> hd() |> String.upcase() |> String.replace("-", "_") |> Kernel.<>("_API_KEY")

{live?, key} =
  case scenario do
    "bogus-key-live" -> {true, "bogus-key-for-live-input-failure-probe"}
    "no-key-live" -> {true, nil}
    "bogus-key-plain" -> {false, "bogus-key-for-live-input-failure-probe"}
  end

# A `nil` value unsets the variable for the CLI; the empty agent dir leaves it no stored credentials.
env = %{"PI_CODING_AGENT_DIR" => agent_dir, key_env => key}
provider_options = if live?, do: %{live_input: true}, else: %{}
started = System.monotonic_time(:millisecond)

{:ok, run_id} =
  Jido.Harness.Run.start(:pi, "Reply with the single word OK.",
    model: model,
    cwd: cwd,
    env: env,
    provider_options: provider_options
  )

outcome =
  case Jido.Harness.Run.await(run_id, deadline_ms) do
    {:ok, %{status: :failed, error: error}} -> {"failed", error && error.message}
    {:ok, %{status: status}} -> {"unexpected-#{status}", nil}
    {:error, :timeout} -> {"HUNG", nil}
  end

elapsed = System.monotonic_time(:millisecond) - started
{name, detail} = outcome

detail =
  (detail || "")
  |> String.replace(~r/\s+/, " ")
  |> String.slice(0, 160)

IO.puts("RESULT scenario=#{scenario} outcome=#{name} elapsed_ms=#{elapsed} detail=#{detail}")

# A hung run leaves its CLI running: stop it before reporting.
if name == "HUNG", do: Jido.Harness.Run.cancel(run_id)

System.halt(if name == "failed", do: 0, else: 1)
