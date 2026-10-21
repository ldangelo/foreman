# S1 mechanism (B): Jido.AI.Reasoning.ReAct called directly (no Foreman app boot).
# Run (from packages/foreman_server, deps copied): MIX_ENV=dev mix run --no-start docs-path/react_spike.exs
# Tools are Jido.Actions that append to a log file (stand-in for CommandGateway dispatch).
{:ok, _} = Application.ensure_all_started(:req_llm)
{:ok, _} = Application.ensure_all_started(:jido_ai)
log = System.get_env("S1_REACT_LOG", "/tmp/s1-react-calls.jsonl")
File.write!(log, "")

defmodule S1.Rec do
  def rec(tool, params), do: File.write!(System.get_env("S1_REACT_LOG", "/tmp/s1-react-calls.jsonl"), Jason.encode!(%{tool: tool, args: params}) <> "\n", [:append])
end

defmodule S1.ThreadCreate do
  use Jido.Action, name: "foreman_thread_create", description: "Start a worker thread for one independent task.",
    schema: Zoi.object(%{title: Zoi.string(), workflow: Zoi.string(), prompt: Zoi.string()})
  def run(params, _ctx), do: (S1.Rec.rec("create", params); {:ok, %{ok: true, id: "X-1"}})
end
defmodule S1.ThreadMessage do
  use Jido.Action, name: "foreman_thread_message", description: "Send a follow-up to an EXISTING thread.",
    schema: Zoi.object(%{thread_id: Zoi.string(), text: Zoi.string()})
  def run(params, _ctx), do: (S1.Rec.rec("message", params); {:ok, %{ok: true}})
end
defmodule S1.Reply do
  use Jido.Action, name: "foreman_project_reply", description: "Reply to the user in the project chat.",
    schema: Zoi.object(%{text: Zoi.string()})
  def run(params, _ctx), do: (S1.Rec.rec("reply", params); {:ok, %{ok: true}})
end

model = System.get_env("S1_REACT_MODEL", "minimax:MiniMax-M2.7-highspeed")
prompt = System.get_env("S1_REACT_PROMPT", "Start a fix thread titled 'Login typo' with prompt 'fix typo in login page'.")
t0 = System.monotonic_time(:millisecond)
res =
  try do
    Jido.AI.Reasoning.ReAct.run(prompt,
      %{model: model, system_prompt: "You are a coordinator. Act only by calling the provided tools. Then give a one-line summary.",
        tools: [S1.ThreadCreate, S1.ThreadMessage, S1.Reply], max_iterations: 5, llm_timeout_ms: 60_000})
  rescue e -> %{result: nil, termination_reason: {:raised, Exception.message(e)}, usage: %{}}
  end
IO.puts("elapsed_ms=#{System.monotonic_time(:millisecond) - t0}")
IO.inspect(Map.take(res, [:result, :termination_reason, :usage]), limit: 20, printable_limit: 400)
IO.puts("calls:\n" <> File.read!(log))
