defmodule ForemanServer.Coordinator.SetupProposerTest do
  # The first-turn setup proposal through a real coordinator runtime, gateway and event
  # store. The probe is a fixture (no `gh`, `br`, provider), and the scripted agent counts
  # its calls: posting a proposal must never invoke a model.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  alias ForemanServer.Coordinator.{Agent.Stub, SetupProposer, Turn}
  alias ForemanServer.{CommandGateway, CoordinatorAPI, ProjectionStore}

  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.Eventually
  alias ForemanServer.TestSupport.RecommendationsProbe

  defmodule RaisingProbe do
    @moduledoc false
    @behaviour ForemanServer.Projects.Recommendations.Facts.Probe
    alias ForemanServer.Projects.Recommendations.Facts.Probe

    defdelegate exists?(path), to: Probe.System
    defdelegate glob(pattern), to: Probe.System
    defdelegate read_head(path, max_bytes), to: Probe.System
    def find_executable(_name), do: raise("probe exploded")
    def cmd(_executable, _args, _timeout_ms), do: {:error, :failed}
    def call(_fun, _timeout_ms), do: {:error, :failed}
  end

  setup %{tmp_dir: dir} do
    RecommendationsProbe.install!()
    H.subscribe!()
    script = start_supervised!({Stub, responses: []})
    {:ok, project_id: "co-#{System.unique_integer([:positive])}", repo: dir, script: script}
  end

  defp start_runtime(project_id, script, opts \\ []) do
    name = :"co_setup_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [
          name: name,
          agent: Stub,
          agent_opts: [script: script],
          only: [project_id],
          retry_backoff_ms: 0,
          backfill?: false,
          setup_proposals: true,
          setup_catch_up?: false
        ],
        opts
      )

    start_supervised!(
      Supervisor.child_spec({ForemanServer.Coordinator.Supervisor, opts}, id: name)
    )

    ForemanServer.Coordinator.Supervisor.runtime(name, opts)
  end

  defp conversation(project_id), do: elem(ProjectionStore.coordinator_state(project_id), 1)

  defp proposals(project_id),
    do: for(%{kind: "setup_proposal"} = m <- conversation(project_id).messages, do: m)

  defp await_proposal(project_id),
    do:
      H.await_event(
        "CoordinatorMessageAppended",
        &(&1.project_id == project_id and &1.kind == "setup_proposal")
      )

  # A call through the proposer is a barrier behind every message it was sent; the proposals
  # themselves are built in tasks, so wait for those to finish too.
  defp settle(rt) do
    :sys.get_state(SetupProposer.name(rt))
    Eventually.await(fn -> Task.Supervisor.children(rt.task_sup) == [] end)
  end

  defp completed(project_id),
    do: H.await_event("CoordinatorTurnCompleted", &(&1.project_id == project_id))

  test "registering a project posts exactly one proposal from no model and starts no turn", ctx do
    rt = start_runtime(ctx.project_id, ctx.script)
    H.register_project(ctx.repo, id: ctx.project_id)

    await_proposal(ctx.project_id)
    settle(rt)

    key = "setup_proposal:" <> ctx.project_id

    assert [%{role: "system", kind: "setup_proposal", report_key: ^key, text: text}] =
             proposals(ctx.project_id)

    assert text =~ "repo.agents_md_missing"
    assert text =~ "foreman project recommend #{ctx.project_id}"
    assert length(conversation(ctx.project_id).messages) == 1

    assert Stub.calls(ctx.script) == []

    assert {:ok, %{status: :idle, pending_messages: 0}} =
             ProjectionStore.coordinator_status(ctx.project_id)
  end

  test "redelivery of the registration and a repeated proposal append nothing", ctx do
    rt = start_runtime(ctx.project_id, ctx.script)
    H.register_project(ctx.repo, id: ctx.project_id)
    await_proposal(ctx.project_id)
    settle(rt)

    registered = %{event_type: "ProjectRegistered", data: %{project_id: ctx.project_id}}
    send(SetupProposer.name(rt), {:projection_event, registered})
    settle(rt)

    assert :ok = SetupProposer.propose(rt, ctx.project_id, :initial)
    assert length(proposals(ctx.project_id)) == 1
  end

  test "a restarted proposer posts nothing: its catch-up finds a conversation that is not empty",
       ctx do
    first = start_runtime(ctx.project_id, ctx.script)
    H.register_project(ctx.repo, id: ctx.project_id)
    await_proposal(ctx.project_id)
    settle(first)
    stop_supervised!(first.name)

    second = start_runtime(ctx.project_id, ctx.script, setup_catch_up?: true)
    settle(second)

    assert length(proposals(ctx.project_id)) == 1
  end

  test "the startup catch-up posts for a project registered while the proposer was not running",
       ctx do
    H.register_project(ctx.repo, id: ctx.project_id)
    assert proposals(ctx.project_id) == []

    rt = start_runtime(ctx.project_id, ctx.script, setup_catch_up?: true)
    await_proposal(ctx.project_id)
    settle(rt)

    assert [%{report_key: key}] = proposals(ctx.project_id)
    assert key == "setup_proposal:" <> ctx.project_id
    assert Stub.calls(ctx.script) == []
  end

  test "the catch-up leaves a project whose conversation already has a message alone", ctx do
    H.register_project(ctx.repo, id: ctx.project_id)
    {:ok, _} = CoordinatorAPI.post_message(ctx.project_id, %{text: "hello", source: "cli"})
    Stub.push(ctx.script, [{:ok, %Turn{reply: "hi", actions: []}}])

    rt = start_runtime(ctx.project_id, ctx.script)
    completed(ctx.project_id)

    assert :ok = SetupProposer.catch_up(rt)
    assert proposals(ctx.project_id) == []
  end

  test "the catch-up skips archived projects and projects the runtime does not serve", ctx do
    H.register_project(ctx.repo, id: ctx.project_id)

    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        command_id: "archive-#{ctx.project_id}",
        aggregate_id: "project:" <> ctx.project_id,
        type: "project.archive",
        payload: %{project_id: ctx.project_id}
      })

    rt = start_runtime(ctx.project_id, ctx.script)
    assert :ok = SetupProposer.catch_up(rt)
    assert proposals(ctx.project_id) == []

    other = "co-other-#{System.unique_integer([:positive])}"
    other_repo = Path.join(ctx.repo, "other")
    File.mkdir_p!(other_repo)
    H.register_project(other_repo, id: other)

    assert :ok = SetupProposer.catch_up(rt)
    assert proposals(other) == []
  end

  test "a failed collection appends nothing, and says why", ctx do
    H.register_project(ctx.repo, id: ctx.project_id)
    rt = start_runtime(ctx.project_id, ctx.script)

    log =
      capture_log(fn ->
        assert :error = SetupProposer.propose(rt, "no-such-project-e13", :initial)
      end)

    assert log =~ "recommendations unavailable"

    Application.put_env(:foreman_server, :recommendations,
      probe: RaisingProbe,
      probe_timeout_ms: 500
    )

    log =
      capture_log(fn ->
        assert :error = SetupProposer.propose(rt, ctx.project_id, :initial)
      end)

    assert log =~ "nothing posted"
    assert proposals(ctx.project_id) == []
    assert conversation(ctx.project_id).messages == []
  end

  test "/setup posts a fresh proposal under its own id, once per request, and starts no turn",
       ctx do
    rt = start_runtime(ctx.project_id, ctx.script)
    H.register_project(ctx.repo, id: ctx.project_id)
    await_proposal(ctx.project_id)
    settle(rt)

    {:ok, %{message_id: request}} =
      CoordinatorAPI.post_message(ctx.project_id, %{text: "/setup", source: "cli"})

    await_proposal(ctx.project_id)
    settle(rt)

    expected = "setup_proposal:#{ctx.project_id}:#{request}"

    assert [first, %{message_id: ^expected, report_key: nil, text: text}] =
             proposals(ctx.project_id)

    assert first.report_key == "setup_proposal:" <> ctx.project_id
    assert text =~ "repo.agents_md_missing"

    redelivered = %{
      event_type: "CoordinatorMessageAppended",
      data: %{
        project_id: ctx.project_id,
        message_id: request,
        role: "operator",
        source: "cli",
        text: "/setup"
      }
    }

    send(SetupProposer.name(rt), {:projection_event, redelivered})
    settle(rt)

    assert length(proposals(ctx.project_id)) == 2
    assert Stub.calls(ctx.script) == []

    assert {:ok, %{status: :idle, pending_messages: 0}} =
             ProjectionStore.coordinator_status(ctx.project_id)
  end

  test "/setup from an untrusted source is an ordinary message for the model", ctx do
    Stub.push(ctx.script, [{:ok, %Turn{reply: "I cannot do that.", actions: []}}])
    rt = start_runtime(ctx.project_id, ctx.script)
    H.register_project(ctx.repo, id: ctx.project_id)
    await_proposal(ctx.project_id)
    settle(rt)

    {:ok, _} = CoordinatorAPI.post_message(ctx.project_id, %{text: "/setup", source: "mcp"})
    completed(ctx.project_id)
    settle(rt)

    assert length(proposals(ctx.project_id)) == 1
    assert length(Stub.calls(ctx.script)) == 1
  end

  test "the operator replies \"apply 1\" and Foreman applies the fix it computed itself", ctx do
    File.mkdir_p!(Path.join(ctx.repo, ".beads"))
    db = Path.join([ctx.repo, ".beads", "beads.db"])
    File.write!(db, "")

    test_pid = self()

    answer = fn context ->
      send(test_pid, {:context, context.text})

      {:ok,
       %Turn{
         reply: "I'm asking Foreman to apply item 1.",
         actions: [
           %{"kind" => "apply_recommendation", "recommendation_id" => "task_provider.wire_beads"}
         ]
       }}
    end

    Stub.push(ctx.script, [answer])
    rt = start_runtime(ctx.project_id, ctx.script)
    H.register_project(ctx.repo, id: ctx.project_id)
    await_proposal(ctx.project_id)
    settle(rt)

    [%{text: proposal}] = proposals(ctx.project_id)
    assert proposal =~ "1. [action] task_provider.wire_beads"
    assert proposal =~ ~s(Reply "apply 1")
    assert ProjectionStore.project(ctx.project_id).task_provider == nil

    {:ok, _} = CoordinatorAPI.post_message(ctx.project_id, %{text: "apply 1", source: "cli"})
    completed(ctx.project_id)

    # The model saw Foreman's own proposal, with the ids, in the recent messages.
    assert_received {:context, context_text}
    assert context_text =~ "system/setup_proposal:"
    assert context_text =~ "task_provider.wire_beads"

    assert %{task_provider: %{provider: "beads", config: %{database_path: ^db}}} =
             ProjectionStore.project(ctx.project_id)

    notices = for %{kind: "notice", text: text} <- conversation(ctx.project_id).messages, do: text
    assert notices == ["Applied setup recommendation task_provider.wire_beads."]
  end
end
