# S2 live spike 2 for pi: interrupt process effect (ps), decode_error payload, bogus resume id.
alias Jido.Harness.Session
t0 = System.monotonic_time(:millisecond)
log = fn tag, v -> IO.puts("[+#{System.monotonic_time(:millisecond) - t0}ms] #{tag}: #{inspect(v, limit: 40, printable_limit: 600)}") end
scratch = "/tmp/s2-scratch-pi2"; File.rm_rf!(scratch); File.mkdir_p!(scratch); System.cmd("git", ["init", "-q"], cd: scratch)
req = %{cwd: scratch, model: "MiniMax-M2.7-highspeed", provider_options: %{model_provider: "minimax"}, approval_mode: :default}
ps = fn pat -> {o, _} = System.cmd("sh", ["-c", "ps -axo pid,ppid,command | grep -v grep | grep -E '#{pat}' | cut -c1-140"]); String.trim(o) end
events = fn sid -> {:ok, e} = Session.replay(sid, cursor: 0, limit: 10_000); e end
# Bounded poll: returns the first truthy value of fun, or nil once timeout_ms elapsed.
wait_for = fn fun, timeout_ms ->
  deadline = System.monotonic_time(:millisecond) + timeout_ms
  Stream.repeatedly(fn -> Process.sleep(100); fun.() || (System.monotonic_time(:millisecond) > deadline && :timeout) end)
  |> Enum.find(& &1)
  |> case do :timeout -> nil; v -> v end
end

{:ok, sid} = Session.start(:pi, req)
log.("pi procs after start", ps.("rpc"))
{:ok, t} = Session.send_message(sid, "Run the bash command `sleep 117` and nothing else.")
saw_tool_call = wait_for.(fn -> Enum.any?(events.(sid), &(&1.type == :tool_call)) end, 60_000)
log.("tool_call seen before deadline", saw_tool_call || false)
Process.sleep(500)
log.("before interrupt", ps.("sleep 117|rpc"))
log.("interrupt", Session.interrupt(sid, :active))
log.("await", Session.await(sid, t, 20_000) |> then(fn {:ok, r} -> Map.take(r, [:status, :text]); o -> o end))
Process.sleep(1000)
log.("after interrupt", ps.("sleep 117|rpc"))
log.("info", Map.take(Map.from_struct(elem(Session.info(sid), 1)), [:state, :active_turn_id]))
evs = events.(sid)
ir = for(e <- evs, e.type in [:turn_interrupted, :turn_failed, :turn_completed, :session_idle], do: {e.type, e.payload})
log.("interrupt-related events", ir)
Session.close(sid)
Process.sleep(1000)
log.("after close", ps.("rpc"))

# bogus resume id
case Session.start(:pi, Map.put(req, :provider_session_id, "00000000-dead-beef-0000-000000000000")) do
  {:ok, s2} ->
    log.("bogus resume start", :ok)
    {:ok, bt} = Session.send_message(s2, "Say OK.")
    r = Session.await(s2, bt, 60_000) |> then(fn {:ok, r} -> Map.take(r, [:status, :text, :provider_session_id]); o -> o end)
    log.("bogus resume turn", r)
    be = for(e <- events.(s2), e.type != :provider_event, do: {e.type, Map.take(e.payload, ["error", "status"])})
    log.("bogus events", be)
    log.("bogus info", elem(Session.info(s2), 1) |> Map.take([:state, :error]))
    Session.kill(s2)
  err -> log.("bogus resume start", err)
end
