defmodule ForemanServer.Coordinator.TurnDiagnosticsTest do
  @moduledoc """
  foreman-ig27o: a coordinator turn leaves a trail in the server log: one line
  when it starts (its trigger messages), one when it completes (what each action
  came to) and a warning when it fails. A turn that ended with "no threads" can
  then be diagnosed after the fact. Ids, kinds, statuses and counts only: never
  the text of a message, a reply or an action.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  alias ForemanServer.Coordinator.{Agent.Stub, Commands, Error, ProjectWorker, Turn}
  alias ForemanServer.ProjectSecrets
  alias ForemanServer.Coordinator.Supervisor, as: CoordinatorSupervisor
  alias ForemanServer.CommandGateway
  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.CoordinatorHelpers.{FakeThreadActions, FakeThreads, SpyGateway}
  alias ForemanServer.TestSupport.Eventually

  setup %{tmp_dir: dir} do
    project_id = H.register_project(dir)
    SpyGateway.watch()
    FakeThreads.put([])
    H.subscribe!()

    previous_level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: previous_level)
      SpyGateway.unwatch()
      FakeThreads.clear()
      FakeThreadActions.clear()
    end)

    script = start_supervised!({Stub, responses: []})
    {:ok, project_id: project_id, script: script}
  end

  defp start_runtime(script, project_id) do
    name = :"co_diag_rt_#{System.unique_integer([:positive])}"

    opts = [
      name: name,
      agent: Stub,
      agent_opts: [script: script],
      only: [project_id],
      gateway: SpyGateway,
      threads: FakeThreads,
      thread_actions: FakeThreadActions,
      retry_backoff_ms: 0,
      backfill?: false
    ]

    start_supervised!(Supervisor.child_spec({CoordinatorSupervisor, opts}, id: name))
    CoordinatorSupervisor.runtime(name, opts)
  end

  defp say(p, id, text, source) do
    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        command_id: "op-#{System.unique_integer([:positive])}",
        aggregate_id: "coordinator:#{p}",
        type: "coordinator.message",
        payload: %{project_id: p, message_id: id, text: text, source: source}
      })
  end

  # Starts the runtime for `p` and returns the lines the coordinator of `p` logged
  # until a turn completed and its worker is idle again (so the completing turn's
  # log lines, written before its task returns, are all in).
  defp coordinator_lines(p, script) do
    log =
      capture_log([level: :info], fn ->
        rt = start_runtime(script, p)
        H.await_event("CoordinatorTurnCompleted", &(&1.project_id == p))
        Eventually.await(fn -> not ProjectWorker.busy?(rt, p) end, message: "worker idle")
      end)

    log
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.contains?(&1, "coordinator #{p}:"))
  end

  defp one(lines, marker) do
    assert [line] = Enum.filter(lines, &String.contains?(&1, marker))
    line
  end

  test "an operator turn logs its triggers, authority, reply size and each action outcome",
       %{project_id: p, script: script} do
    reply = "SECRET-REPLY-TEXT on it"

    actions = [
      %{"kind" => "answer", "text" => "SECRET-ANSWER-TEXT"},
      %{"kind" => "teleport", "where" => "mars"}
    ]

    Stub.push(script, [{:ok, %Turn{reply: reply, actions: actions}}])
    say(p, "m1", "SECRET-OPERATOR-TEXT one", "cli")
    say(p, "m2", "SECRET-OPERATOR-TEXT two", "mcp")

    lines = coordinator_lines(p, script)

    start = one(lines, "turn m1:a1 started")
    assert start =~ "attempt=1"
    assert start =~ "triggers: m1 (operator/message/cli), m2 (operator/message/mcp)"

    done = one(lines, "turn m1:a1 completed")
    assert done =~ "authority=operator"
    assert done =~ "reply_bytes=#{byte_size(reply)}"
    assert done =~ "actions: answer=executed, teleport=rejected ("
    assert Regex.match?(~r/teleport=rejected \([^)]+\)/, done)

    refute Enum.any?(lines, &String.contains?(&1, "SECRET"))
  end

  test "a report-triggered turn logs machine authority, the report as system/report, no actions",
       %{project_id: p, script: script} do
    {:ok, _} =
      Commands.append(SpyGateway, p, "report:ReviewRecorded:run-x", %{
        role: "system",
        kind: "report",
        text: "SECRET-REPORT-TEXT verdict NOT_MET",
        report_key: "ReviewRecorded:run-x"
      })

    Stub.push(script, [{:ok, %Turn{reply: "Noted."}}])
    lines = coordinator_lines(p, script)

    start = one(lines, "turn report:ReviewRecorded:run-x:a1 started")
    assert start =~ "triggers: report:ReviewRecorded:run-x (system/report/system)"

    done = one(lines, "turn report:ReviewRecorded:run-x:a1 completed")
    assert done =~ "authority=machine"
    assert done =~ "reply_bytes=#{byte_size("Noted.")} actions: none"

    refute Enum.any?(lines, &String.contains?(&1, "SECRET"))
  end

  test "a rejected action carries its reason cut to 120 characters, on one line",
       %{project_id: p, script: script} do
    long_keys = %{String.duplicate("a", 60) => 1, String.duplicate("b", 60) => 2}
    action = Map.merge(%{"kind" => "answer", "text" => "hi"}, long_keys)
    Stub.push(script, [{:ok, %Turn{reply: "ok", actions: [action]}}])
    say(p, "m1", "do something odd", "cli")

    done = p |> coordinator_lines(script) |> one("turn m1:a1 completed")

    assert [_, reason] = Regex.run(~r/answer=rejected \((.*)\)$/, done)
    assert String.length(reason) == 120
  end

  test "a failed turn logs one warning: attempt, code and the message cut to 200 characters",
       %{project_id: p, script: script} do
    message = "provider down: " <> String.duplicate("x", 400) <> "\nsecond line"
    Stub.push(script, [{:error, Error.new(:agent_failed, message)}])
    say(p, "m1", "SECRET-OPERATOR-TEXT hello", "cli")

    # the retry (the exhausted script answers with a plain turn) completes the message
    lines = coordinator_lines(p, script)

    failed = one(lines, "turn m1:a1 failed")
    assert failed =~ "attempt=1 code=agent_failed: provider down: xxxx"
    clipped = message |> String.replace(~r/\s+/, " ") |> String.slice(0, 200)
    assert String.ends_with?(failed, clipped)
    refute failed =~ "second line"

    assert one(lines, "turn m1:a2 started") =~ "attempt=2"
    assert one(lines, "turn m1:a2 completed") =~ "actions: none"
    refute Enum.any?(lines, &String.contains?(&1, "SECRET"))
  end

  test "a failed turn's log line is redacted before it is cut: a secret straddling char 200 leaks no prefix",
       %{project_id: p, script: script, tmp_dir: dir} do
    store = Application.get_env(:foreman_server, :secret_store)

    Application.put_env(
      :foreman_server,
      :secret_store,
      Keyword.put(store, :dir, Path.join(dir, "secrets"))
    )

    on_exit(fn -> Application.put_env(:foreman_server, :secret_store, store) end)

    secret = "postgres://svc:straddlepw99@db.internal:5432/app"
    assert {:ok, _} = ProjectSecrets.set(p, "DB_URL", secret, "test")

    # The secret starts 10 characters before the cut: unredacted, 10 of its characters are logged.
    message = String.duplicate("y", 190) <> secret <> " tail"
    Stub.push(script, [{:error, Error.new(:agent_failed, message)}])
    say(p, "m1", "hello", "cli")

    lines = coordinator_lines(p, script)
    failed = one(lines, "turn m1:a1 failed")

    refute failed =~ "postgres"
    refute failed =~ "straddlepw99"
    assert failed =~ "[REDACTED]"
  end
end
