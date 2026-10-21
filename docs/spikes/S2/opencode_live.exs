# S2 bonus: ACP session (opencode) to capture approval_requested shape. Run like pi_live.exs.
alias Jido.Harness.Session
t0 = System.monotonic_time(:millisecond)
log = fn tag, v -> IO.puts("[+#{System.monotonic_time(:millisecond) - t0}ms] #{tag}: #{inspect(v, limit: 40, printable_limit: 1500)}") end
scratch = "/tmp/s2-scratch-oc"; File.rm_rf!(scratch); File.mkdir_p!(scratch); System.cmd("git", ["init", "-q"], cd: scratch)
cfg = ~s({"model":"minimax/MiniMax-M3.1-Flash","permission":{"edit":"ask","bash":"ask"}})
events = fn sid -> {:ok, e} = Session.replay(sid, cursor: 0, limit: 10_000); e end
res = fn r -> case r do {:ok, %Jido.Harness.TurnResult{} = tr} -> Map.take(tr, [:status, :text, :provider_session_id]); o -> o end end
start = fn extra ->
  Session.start(:opencode, Map.merge(%{cwd: scratch, approval_mode: :default, env: %{"OPENCODE_CONFIG_CONTENT" => cfg}, approval_timeout_ms: 20_000}, extra))
end
{:ok, sid} = start.(%{})
log.("session", sid)
log.("info", elem(Session.info(sid), 1) |> Map.take([:state, :transport]))
{:ok, t1} = Session.send_message(sid, "Create a file named hello.txt containing the word HELLO using your file edit tool. Nothing else.")
find = fn -> Enum.find(events.(sid), &(&1.type == :approval_requested)) end
req = Stream.repeatedly(fn -> Process.sleep(200); find.() end) |> Enum.find(& &1)
log.("approval_requested event", Map.from_struct(req) |> Map.drop([:raw]))
log.("info while waiting", elem(Session.info(sid), 1) |> Map.take([:state, :pending_approvals]))
log.("respond deny", Session.respond_approval(sid, req.request_id, %{decision: :deny, reason: "spike deny"}))
log.("turn1 (deny)", res.(Session.await(sid, t1, 120_000)))
log.("hello.txt after deny", File.exists?(Path.join(scratch, "hello.txt")))
log.("resolved events", for(e <- events.(sid), e.type == :approval_resolved, do: {e.request_id, e.payload}))
# approve
n = length(events.(sid))
{:ok, t2} = Session.send_message(sid, "Create a file named approved.txt containing the word YES using your file edit tool. Nothing else.")
req2 = Stream.repeatedly(fn -> Process.sleep(200); Enum.find(Enum.drop(events.(sid), n), &(&1.type == :approval_requested)) end) |> Enum.find(& &1)
log.("respond approve", Session.respond_approval(sid, req2.request_id, %{decision: :approve, scope: :once}))
log.("turn2 (approve)", res.(Session.await(sid, t2, 120_000)))
log.("approved.txt", File.read(Path.join(scratch, "approved.txt")))
# unanswered -> timeout
n = length(events.(sid))
{:ok, t3} = Session.send_message(sid, "Create a file named timeout.txt containing the word T using your file edit tool. Nothing else.")
Stream.repeatedly(fn -> Process.sleep(200); Enum.find(Enum.drop(events.(sid), n), &(&1.type == :approval_requested)) end) |> Enum.find(& &1)
log.("unanswered: waiting for approval_timeout_ms=20000", :ok)
log.("turn3 (unanswered)", res.(Session.await(sid, t3, 120_000)))
log.("timeout resolved", for(e <- Enum.drop(events.(sid), n), e.type == :approval_resolved, do: e.payload))
log.("timeout.txt exists", File.exists?(Path.join(scratch, "timeout.txt")))
log.("provider_session_id", elem(Session.info(sid), 1).provider_session_id)
Session.kill(sid)
