# S2 live spike for pi. Run: cd packages/jido_harness && mix run ../../docs/spikes/S2/pi_live.exs
alias Jido.Harness.Session
t0 = System.monotonic_time(:millisecond)
now = fn -> System.monotonic_time(:millisecond) - t0 end
log = fn tag, v -> IO.puts("[+#{now.()}ms] #{tag}: #{inspect(v, limit: 40, printable_limit: 400)}") end
out_dir = "/tmp/s2-out"; File.mkdir_p!(out_dir)

scratch = "/tmp/s2-scratch-pi"
File.rm_rf!(scratch); File.mkdir_p!(scratch)
System.cmd("git", ["init", "-q"], cd: scratch)
req = %{cwd: scratch, model: "MiniMax-M2.7-highspeed", provider_options: %{model_provider: "minimax"}, approval_mode: :default}

events = fn sid ->
  {:ok, evs} = Session.replay(sid, cursor: 0, limit: 10_000)
  evs
end
dump = fn sid, name ->
  lines = for e <- events.(sid) do
    raw = e.payload["raw"] && e.payload["raw"]["type"]
    k = e.payload["kind"]
    txt = e.payload["text"] || e.payload["tool"] || e.payload["name"]
    "#{e.timestamp} #{e.type} turn=#{e.turn_id && String.slice(e.turn_id, -5..-1//1)} req=#{e.request_id && String.slice(e.request_id, -5..-1//1)} psid=#{inspect(e.provider_session_id)} kind=#{k} raw=#{raw} #{txt && String.slice(to_string(txt), 0, 80)}"
  end
  File.write!(Path.join(out_dir, name), Enum.join(lines, "\n"))
end
wait_for = fn sid, type, timeout ->
  deadline = now.() + timeout
  Stream.repeatedly(fn -> Process.sleep(100); Enum.any?(events.(sid), &(&1.type == type)) or now.() > deadline end) |> Enum.find(& &1)
end
settle = fn sid ->
  Stream.repeatedly(fn -> n = length(events.(sid)); Process.sleep(4000); length(events.(sid)) == n end) |> Enum.find(& &1)
end
bounded = fn label, f ->
  task = Task.async(f)
  case Task.yield(task, 150_000) || Task.shutdown(task, :brutal_kill) do
    {:ok, v} -> v
    other -> log.(label <> " TIMED OUT/hung", other); :hung
  end
end
res = fn r -> case r do {:ok, %Jido.Harness.TurnResult{} = tr} -> Map.take(tr, [:status, :text, :provider_session_id]); o -> o end end

{:ok, sid} = Session.start(:pi, req)
log.("session", sid)
log.("info", Session.info(sid))

# --- A: steer during tool execution
{:ok, t1} = Session.send_message(sid, "Run the bash command `sleep 10`, then create file result.txt containing exactly the word ALPHA. Then say done.")
wait_for.(sid, :tool_call, 60_000)
log.("A tool_call seen; steering", now.())
log.("A steer", Session.steer(sid, "Change of plan: skip the rest and create result.txt containing exactly the word BETA instead, then say done."))
log.("A turn1", res.(Session.await(sid, t1, 120_000)))
log.("A result.txt at turn_completed", File.read(Path.join(scratch, "result.txt")))
settle.(sid)
log.("A result.txt after settle", File.read(Path.join(scratch, "result.txt")))
dump.(sid, "pi-A-events.txt")

# --- B: steer immediately (before any tool)
{:ok, t2} = Session.send_message(sid, "Run the bash command `sleep 5`, then create file b.txt containing exactly the word ONE. Then say done.")
log.("B steer", Session.steer(sid, "Also: b.txt must contain TWO instead of ONE."))
log.("B turn", res.(Session.await(sid, t2, 120_000)))
log.("B b.txt at turn_completed", File.read(Path.join(scratch, "b.txt")))
settle.(sid)
log.("B b.txt after settle", File.read(Path.join(scratch, "b.txt")))
dump.(sid, "pi-B-events.txt")
log.("steer_idle", Session.steer(sid, "hello"))
log.("respond_approval_unknown", Session.respond_approval(sid, "nope", %{decision: :allow}))

# --- C: follow_up while busy
{:ok, t3} = Session.send_message(sid, "Run the bash command `sleep 6`, then say done1.")
wait_for.(sid, :turn_started, 1000)
fu = Session.follow_up(sid, "Now just reply with the single word FOLLOWED.")
log.("C follow_up", fu)
log.("C info while busy", Map.take(Map.from_struct(elem(Session.info(sid), 1)), [:state, :queued_turns, :active_turn_id]))
log.("C turn3", res.(Session.await(sid, t3, 120_000)))
with {:ok, ft} <- fu, do: log.("C followup turn", res.(Session.await(sid, ft, 120_000)))
settle.(sid)
dump.(sid, "pi-C-events.txt")

# --- D: interrupt
n0 = length(events.(sid))
{:ok, t4} = Session.send_message(sid, "Remember the secret word PINEAPPLE. Then run the bash command `sleep 120`.")
bounded.("D wait tool_call", fn -> Stream.repeatedly(fn -> Process.sleep(100); length(Enum.filter(Enum.drop(events.(sid), n0), &(&1.type == :tool_call))) >= 1 end) |> Enum.find(& &1) end)
{o, _} = System.cmd("sh", ["-c", "pgrep -fl 'sleep 120'; pgrep -f 'pi --mode rpc' | wc -l"]); log.("D procs before interrupt", o)
log.("D interrupt", Session.interrupt(sid, :active))
log.("D turn4", res.(Session.await(sid, t4, 30_000)))
settle.(sid)
Process.sleep(500)
{o, _} = System.cmd("sh", ["-c", "pgrep -fl 'sleep 120'; echo ---; pgrep -f 'pi --mode rpc' | wc -l"]); log.("D procs after interrupt", o)
log.("D info", Map.take(Map.from_struct(elem(Session.info(sid), 1)), [:state, :active_turn_id, :provider_session_id]))
{:ok, t5} = Session.send_message(sid, "What secret word did I give you? One word answer.")
log.("D turn5 same session after interrupt", res.(Session.await(sid, t5, 90_000)))
dump.(sid, "pi-D-events.txt")

# --- E: resume
files = Path.wildcard(Path.expand("~/.pi/agent/sessions/*s2-scratch-pi*/*.jsonl")) |> Enum.sort()
file_ids = for f <- files, do: (f |> File.stream!() |> Enum.take(1) |> hd() |> Jason.decode!() |> Map.get("id"))
log.("E session file ids", file_ids)
psids = file_ids
_unused = events.(sid) |> Enum.map(& &1.provider_session_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
log.("E provider_session_ids in events", psids)
log.("E pi session files", Path.wildcard(Path.expand("~/.pi/agent/sessions/*s2-scratch-pi*/*")))
log.("close", Session.close(sid))
Process.sleep(1500)
{o, _} = System.cmd("sh", ["-c", "pgrep -f 'pi --mode rpc' | wc -l"]); log.("E pi procs after close", o)

for {label, extra, ropts} <- [
      {"E1 --session <captured id>", List.first(psids), %{}},
      {"E2 --continue", nil, %{continue: true}}
    ] do
  r = req |> Map.merge(if extra, do: %{provider_session_id: extra}, else: %{}) |> Map.update!(:provider_options, &Map.merge(&1, ropts))
  case Session.start(:pi, r) do
    {:ok, s2} ->
      {:ok, t} = Session.send_message(s2, "What secret word did I give you earlier? One word answer.")
      log.(label, res.(Session.await(s2, t, 90_000)))
      Session.kill(s2)
    err -> log.(label, err)
  end
end
