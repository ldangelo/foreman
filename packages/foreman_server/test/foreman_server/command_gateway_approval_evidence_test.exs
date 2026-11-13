defmodule ForemanServer.CommandGatewayApprovalEvidenceTest do
  # The gateway half of the evidence gate (TRD-022): `merge_approve` reads GitHub once, reads the
  # project's policy as it stands now, records the observation batch from that one read and
  # stamps `evidence` on the approval. Through the real gateway, aggregate and event store;
  # only `gh` is stubbed, and the router is wrapped (meck passthrough) to record - and in some
  # tests refuse - what the gateway dispatches.
  use ExUnit.Case, async: false

  alias ForemanServer.{Aggregate, CommandGateway, CommandRouter, EventStore, PrEvidence}
  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.{ProjectionStore, RunPrMerge}
  alias ForemanServer.TestSupport.{KeyStoreReset, MeckScope}
  alias ForemanServer.TestSupport.GateEvidence
  alias ForemanServer.Workflow.MergeGate

  @approver "github:ldangelo"
  @switch :require_durable_store_for_gating
  @unit %{"name" => "unit", "kind" => "check_run"}
  @lint %{"name" => "lint", "kind" => "check_run"}

  setup_all do
    MeckScope.new_once!([CommandRouter])
  end

  setup do
    MeckScope.restore_on_exit!([CommandRouter])
    MergeGate.clear()
    original = Application.fetch_env(:foreman_server, @switch)

    on_exit(fn ->
      Application.delete_env(:foreman_server, :merge_gate_readers)
      RunPrMerge.clear_command_runner()

      case original do
        {:ok, value} -> Application.put_env(:foreman_server, @switch, value)
        :error -> Application.delete_env(:foreman_server, @switch)
      end
    end)

    {:ok, gh} = Agent.start_link(fn -> %{head: "head-one", views: [], other: []} end)
    install_gh(gh)
    %{gh: gh}
  end

  # -- fixtures ---------------------------------------------------------------------------

  defp token, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp register_project!(config) do
    project_id = "project-gate-#{token()}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: project_id, path: "/tmp/#{project_id}", config: config}
        }
      ])

    project_id
  end

  defp set_required!(project_id, nil) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectUpdated",
          payload: %{project_id: project_id, cleared_settings: ["required_checks"]}
        }
      ])
  end

  defp set_required!(project_id, required) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectUpdated",
          payload: %{project_id: project_id, required_checks: required}
        }
      ])
  end

  # A run whose PR is ready (gate pending at head-one). `project: :unknown` leaves the project out
  # of the projection, `project: :no_run` leaves the run itself out of it.
  defp ready_run!(project_id, opts \\ []) do
    run_id = "run-gate-#{token()}"
    pr_url = "https://github.com/acme/repo/pull/#{System.unique_integer([:positive])}"
    started = %{run_id: run_id, project_id: project_id, task_id: "task-gate"}

    :ok =
      EventStore.append_to_stream("run:#{run_id}", 0, [
        %Elixir.EventStore.EventData{event_type: "RunStarted", data: started, metadata: %{}}
      ])

    unless opts[:no_run] do
      :ok = ProjectionStore.apply_events([%{event_type: "RunStarted", payload: started}])
    end

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.pr.ready",
        command_id: "ready-#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{
          run_id: run_id,
          project_id: project_id,
          task_id: "task-gate",
          pr_url: pr_url,
          branch_name: "foreman/task-gate/run",
          head_sha: "head-one",
          base_branch: "main"
        }
      })

    run = %{run_id: run_id, pr_url: pr_url, project_id: project_id, task_id: "task-gate"}
    # the review findings of the head the PR opened at: a clean block, so an approval is not
    # refused `findings_absent` (TRD-036)
    :ok = GateEvidence.record_findings!(run, "head-one")
    run
  end

  defp gated_run!(required \\ [@unit]) do
    project_id = register_project!(%{required_checks: required})
    {project_id, ready_run!(project_id)}
  end

  defp install_gh(gh) do
    RunPrMerge.set_command_runner(fn "gh", args, _opts ->
      case args do
        ["pr", "view" | _] ->
          Agent.get_and_update(gh, fn state ->
            reply =
              case state[:view_failure] do
                nil -> {view_json(state.head), 0}
                failure -> failure
              end

            {reply, %{state | views: [args | state.views]}}
          end)

        other ->
          Agent.update(gh, fn state -> %{state | other: [other | state.other]} end)
          {"", 0}
      end
    end)
  end

  defp view_json(head) do
    Jason.encode!(%{
      "state" => "OPEN",
      "mergeable" => "MERGEABLE",
      "headRefOid" => head,
      "headRefName" => "foreman/task-gate/run",
      "baseRefName" => "main",
      "statusCheckRollup" => [
        %{
          "__typename" => "CheckRun",
          "completedAt" => "2026-11-12T13:58:49Z",
          "conclusion" => "SUCCESS",
          "name" => "unit",
          "startedAt" => "2026-11-12T13:58:43Z",
          "status" => "COMPLETED",
          "workflowName" => "ci"
        }
      ],
      "files" => [%{"path" => "lib/a.ex", "additions" => 3, "deletions" => 1}],
      "changedFiles" => 1,
      "additions" => 3,
      "deletions" => 1
    })
  end

  defp gh_views(gh), do: Agent.get(gh, & &1.views)
  defp gh_other(gh), do: Agent.get(gh, & &1.other)
  defp set_head!(gh, head), do: Agent.update(gh, &%{&1 | head: head})

  defp approve(run_id, extra \\ %{}) do
    CommandGateway.dispatch_operator(%{
      command_id: "approve-#{token()}",
      type: "merge_approve",
      aggregate_id: "run:#{run_id}",
      payload:
        Map.merge(
          %{
            run_id: run_id,
            approver: "leo",
            approver_identity: @approver,
            head_sha: "head-one"
          },
          extra
        )
    })
  end

  # Every command the gateway handed to the router for `run_id`, in order.
  defp dispatched(run_id) do
    for {_pid, {CommandRouter, :dispatch, [command | _]}, _result} <- :meck.history(CommandRouter),
        get(command.payload, :run_id) == run_id,
        do: command
  end

  defp types(commands), do: Enum.map(commands, & &1.type)
  defp get(map, key), do: Aggregate.get(map, key)

  # Dispatched after the run's `run.pr.ready` and the fixture's findings record (the fixture's own
  # commands).
  defp after_ready(run_id),
    do: Enum.reject(dispatched(run_id), &(&1.type in ["run.pr.ready", "run.pr.findings"]))

  defp events(run_id, type) do
    {:ok, events} = EventStore.read_stream_forward("run:#{run_id}", 0, 1_000)
    for %{event_type: ^type, data: data} <- events, do: data
  end

  defp reject_type(type, reason) do
    :meck.expect(CommandRouter, :dispatch, fn command, timeout ->
      if command.type == type,
        do: {:error, reason},
        else: :meck.passthrough([command, timeout])
    end)
  end

  # -- the batch --------------------------------------------------------------------------

  describe "a gated project" do
    test "reads GitHub once, records update, forced checks and risk from that read, then approves",
         %{gh: gh} do
      {project_id, %{run_id: run_id}} = gated_run!()
      {:ok, policy} = PrEvidence.project_policy(project_id)

      assert {:ok, _} = approve(run_id)

      assert [view] = gh_views(gh)
      assert ["pr", "view", _url, "--json", fields] = view
      refute fields =~ "reviewThreads"
      assert gh_other(gh) == []

      assert [update, checks, risk, approve_command] = after_ready(run_id)

      assert types([update, checks, risk, approve_command]) ==
               ["run.pr.update", "run.pr.checks", "run.pr.risk", "merge_approve"]

      refute "run.pr.review" in types(after_ready(run_id))

      nonce = get(checks.payload, :observation_ref)
      assert is_binary(nonce) and byte_size(nonce) == 32
      assert checks.command_id =~ ":forced:#{nonce}"
      assert get(checks.payload, :source) == "gate"

      evidence = approve_command.payload.evidence
      assert evidence.checks_ref == nonce
      assert evidence.policy == policy
      assert is_integer(evidence.now_ms)
      assert get(checks.payload, :observed_at) == evidence.now_ms

      assert [%{} = forced] =
               for(
                 data <- events(run_id, "PrChecksChanged"),
                 get(data, :observation_ref) == nonce,
                 do: data
               )

      assert get(forced, :source) == "gate"
      assert [_approved] = events(run_id, "MergeGateApproved")
    end

    test "every attempt uses its own nonce and its own forced run.pr.checks", %{gh: gh} do
      {_project_id, %{run_id: run_id}} = gated_run!()

      # the first attempt is refused after the batch was recorded
      :meck.expect(CommandRouter, :dispatch, fn command, timeout ->
        if command.type == "merge_approve",
          do: {:error, :injected},
          else: :meck.passthrough([command, timeout])
      end)

      assert {:error, :injected} = approve(run_id)
      :meck.delete(CommandRouter, :dispatch, 2)
      assert {:ok, _} = approve(run_id)

      assert length(gh_views(gh)) == 2

      forced = for c <- after_ready(run_id), c.type == "run.pr.checks", do: c
      assert [first, second] = forced
      assert get(first.payload, :observation_ref) != get(second.payload, :observation_ref)
      assert first.command_id != second.command_id

      sources =
        for data <- events(run_id, "PrChecksChanged"),
            do: {get(data, :source), get(data, :observation_ref)}

      assert Enum.sort(sources) ==
               Enum.sort([
                 {"gate", get(first.payload, :observation_ref)},
                 {"gate", get(second.payload, :observation_ref)}
               ])

      approvals = for c <- after_ready(run_id), c.type == "merge_approve", do: c

      assert Enum.map(approvals, & &1.payload.evidence.checks_ref) ==
               [get(first.payload, :observation_ref), get(second.payload, :observation_ref)]
    end

    test "a head that moved since the last observation: evidence is recorded for the new head first",
         %{gh: gh} do
      {_project_id, run} = gated_run!()
      %{run_id: run_id} = run
      set_head!(gh, "head-two")
      :ok = GateEvidence.record_findings!(run, "head-two")

      assert {:ok, _} = approve(run_id, %{head_sha: "head-two"})

      assert [update, checks, risk, %{type: "merge_approve"}] = after_ready(run_id)
      assert get(update.payload, :head_sha) == "head-two"
      assert get(checks.payload, :head_sha) == "head-two"
      assert get(risk.payload, :head_sha) == "head-two"
      assert [%{} = approved] = events(run_id, "MergeGateApproved")
      assert get(approved, :head_sha) == "head-two"
    end

    test "a named head that is not GitHub's is refused with both and dispatches nothing",
         %{gh: gh} do
      {_project_id, %{run_id: run_id}} = gated_run!()
      set_head!(gh, "head-two")

      assert {:error, {:head_sha_mismatch, "head-one", "head-two"}} = approve(run_id)
      assert after_ready(run_id) == []
    end

    test "a GitHub read that fails refuses the approval and dispatches nothing", %{gh: gh} do
      {_project_id, %{run_id: run_id}} = gated_run!()
      Agent.update(gh, &Map.put(&1, :view_failure, {"boom", 1}))

      assert {:error, {:gh_failed, 1, "boom"}} = approve(run_id)
      assert after_ready(run_id) == []
      assert events(run_id, "MergeGateApproved") == []
    end
  end

  # -- the policy -------------------------------------------------------------------------

  describe "the policy is read as it stands now" do
    test "a tightened list is the stamped one, a cleared list is gate off", %{gh: gh} do
      {project_id, %{run_id: run_id}} = gated_run!([@unit])

      # a refused first attempt, so that a second approval of the same gate is possible
      reject_type("merge_approve", :injected)
      assert {:error, :injected} = approve(run_id)
      :meck.delete(CommandRouter, :dispatch, 2)

      set_required!(project_id, [@unit, @lint])
      {:ok, tightened} = PrEvidence.project_policy(project_id)
      assert length(tightened.required) == 2

      reject_type("merge_approve", :injected_again)
      assert {:error, :injected_again} = approve(run_id)
      :meck.delete(CommandRouter, :dispatch, 2)

      set_required!(project_id, nil)
      assert {:ok, _} = approve(run_id)

      approvals = for c <- after_ready(run_id), c.type == "merge_approve", do: c
      assert [first, second, third] = approvals

      assert length(first.payload.evidence.policy.required) == 1

      assert second.payload.evidence.policy == tightened

      assert third.payload.evidence == %{
               policy: nil,
               checks_ref: nil,
               now_ms: third.payload.evidence.now_ms
             }

      assert length(gh_views(gh)) == 3
    end

    test "a project the projection does not know is refused, never read as gate off", %{gh: gh} do
      %{run_id: run_id} = ready_run!("project-unknown-#{token()}")

      assert {:error, {:policy_unavailable, :project_not_found}} = approve(run_id)

      assert after_ready(run_id) == []
      assert length(gh_views(gh)) == 1
      assert events(run_id, "MergeGateApproved") == []
    end

    test "a run the projection does not know is refused too" do
      project_id = register_project!(%{required_checks: [@unit]})
      %{run_id: run_id} = ready_run!(project_id, no_run: true)

      assert {:error, {:policy_unavailable, :run_unknown}} = approve(run_id)
      assert after_ready(run_id) == []
    end

    test "a project with no required_checks: no batch, no extra read, a nil policy stamped",
         %{gh: gh} do
      project_id = register_project!(%{})
      %{run_id: run_id} = ready_run!(project_id)

      assert {:ok, _} = approve(run_id)

      assert length(gh_views(gh)) == 1
      assert [%{type: "merge_approve"} = command] = after_ready(run_id)
      assert %{policy: nil, checks_ref: nil, now_ms: now_ms} = command.payload.evidence
      assert is_integer(now_ms)
      assert events(run_id, "PrChecksChanged") == []
    end
  end

  # -- the guards -------------------------------------------------------------------------

  describe "refusals" do
    test "a gated project is refused on a store that is not durable, and nothing is dispatched" do
      KeyStoreReset.reset!()
      Application.put_env(:foreman_server, @switch, true)
      refute KeyStore.durable?()
      {_project_id, %{run_id: run_id}} = gated_run!()

      assert {:error, {:store_not_durable, note}} = approve(run_id)
      assert is_binary(note)
      assert after_ready(run_id) == []
      assert events(run_id, "MergeGateApproved") == []

      # a project with the gate off is not gated by the guard
      %{run_id: open_run} = ready_run!(register_project!(%{}))
      assert {:ok, _} = approve(open_run)
    end

    for type <- ["run.pr.update", "run.pr.checks", "run.pr.risk"] do
      test "a rejected #{type} refuses the approval and fires the telemetry event" do
        type = unquote(type)
        {_project_id, %{run_id: run_id}} = gated_run!()
        reject_type(type, :boom)
        attach_refused!()

        assert {:error, {:evidence_not_recorded, ^type, :boom}} = approve(run_id)
        assert_receive {:refused, %{run_id: ^run_id, type: ^type, reason: :boom}}

        refute "merge_approve" in types(after_ready(run_id))
        assert events(run_id, "MergeGateApproved") == []
      end
    end

    test "a batch command that times out (exits) refuses the approval like a rejected one" do
      {_project_id, %{run_id: run_id}} = gated_run!()

      :meck.expect(CommandRouter, :dispatch, fn command, timeout ->
        if command.type == "run.pr.checks",
          do: exit({:timeout, {GenServer, :call, [:actor, :dispatch, timeout]}}),
          else: :meck.passthrough([command, timeout])
      end)

      attach_refused!()

      assert {:error, {:evidence_not_recorded, "run.pr.checks", {:exit, {:timeout, _}}}} =
               approve(run_id)

      assert_receive {:refused, %{run_id: ^run_id, type: "run.pr.checks"}}
      refute "merge_approve" in types(after_ready(run_id))
      assert events(run_id, "MergeGateApproved") == []
    end

    test "a policy read that exits, or an invalid stored policy, is policy_unavailable" do
      {_project_id, %{run_id: run_id}} = gated_run!()

      Application.put_env(:foreman_server, :merge_gate_readers,
        run: fn _run_id -> exit(:projection_down) end
      )

      assert {:error, {:policy_unavailable, {:exit, :projection_down}}} = approve(run_id)

      Application.put_env(:foreman_server, :merge_gate_readers,
        run: fn _run_id -> %{project_id: "p"} end,
        project: fn "p" -> exit(:timeout) end
      )

      assert {:error, {:policy_unavailable, {:exit, :timeout}}} = approve(run_id)

      Application.put_env(:foreman_server, :merge_gate_readers,
        run: fn _run_id -> %{project_id: "p"} end,
        project: fn "p" -> %{config: %{required_checks: "not a list"}} end
      )

      assert {:error, {:policy_unavailable, {:invalid_required_checks, _}}} = approve(run_id)

      assert after_ready(run_id) == []
      assert events(run_id, "MergeGateApproved") == []
    end

    defp attach_refused! do
      test_pid = self()
      handler = "gate-refused-#{token()}"

      :telemetry.attach(
        handler,
        [:foreman_server, :merge_gate, :evidence_refused],
        fn _event, _measurements, metadata, _config -> send(test_pid, {:refused, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "an approval the aggregate refuses before GitHub is read reads nothing", %{gh: gh} do
      {_project_id, %{run_id: run_id}} = gated_run!()

      assert {:error, _} = approve(run_id, %{approver_identity: "github:nobody-at-all"})
      assert gh_views(gh) == []
      assert after_ready(run_id) == []
    end
  end

  describe "the stamped evidence" do
    test "replaces any evidence the caller sent, atom or string keyed", %{gh: _gh} do
      {_project_id, %{run_id: run_id}} = gated_run!()
      forged = %{policy: nil, checks_ref: "forged", now_ms: 1}

      for key <- [:evidence, "evidence"] do
        reject_type("merge_approve", :injected)
        assert {:error, :injected} = approve(run_id, %{key => forged})
        :meck.delete(CommandRouter, :dispatch, 2)
      end

      assert {:ok, _} = approve(run_id, %{"evidence" => forged})

      approvals = for c <- after_ready(run_id), c.type == "merge_approve", do: c
      assert length(approvals) == 3

      for command <- approvals do
        refute Map.has_key?(command.payload, "evidence")
        assert command.payload.evidence.checks_ref != "forged"
        assert command.payload.evidence.policy != nil
        assert command.payload.evidence.now_ms != 1
      end
    end

    test "a forged evidence is dropped on a gate-off project too" do
      %{run_id: run_id} = ready_run!(register_project!(%{}))

      assert {:ok, _} = approve(run_id, %{evidence: %{policy: %{required: [], version: "x"}}})

      assert [%{type: "merge_approve", payload: payload}] = after_ready(run_id)
      assert payload.evidence.policy == nil
    end

    test "a gate that is not pending dispatches and stamps nothing; the aggregate refuses" do
      {_project_id, %{run_id: run_id}} = gated_run!()
      assert {:ok, _} = approve(run_id)

      for key <- [:evidence, "evidence"] do
        before = length(after_ready(run_id))

        assert {:error, :merge_gate_already_approved} =
                 approve(run_id, %{key => %{policy: nil, checks_ref: "x", now_ms: 1}})

        assert [%{type: "merge_approve", payload: payload}] =
                 Enum.drop(after_ready(run_id), before)

        refute Map.has_key?(payload, :evidence)
        refute Map.has_key?(payload, "evidence")
      end
    end
  end

  describe "the merge gate's decisions are operator-only (dispatch_system refuses them)" do
    defp system_command(type, run_id, payload) do
      %{
        command_id: "system-#{type}-#{token()}",
        type: type,
        aggregate_id: "run:#{run_id}",
        payload:
          Map.merge(%{run_id: run_id, approver: "leo", approver_identity: @approver}, payload)
      }
    end

    test "merge_approve with a hand-made gate-off evidence is refused and nothing is appended" do
      {_project_id, %{run_id: run_id}} = gated_run!()
      forged = %{policy: nil, checks_ref: nil, now_ms: 1}

      command = system_command("merge_approve", run_id, %{head_sha: "head-one", evidence: forged})
      assert {:error, {:operator_only, "merge_approve"}} = CommandGateway.dispatch_system(command)

      assert events(run_id, "MergeGateApproved") == []
      refute "merge_approve" in types(after_ready(run_id))

      # the operator path, which stamps its own evidence, still decides the gate
      assert {:ok, _} = approve(run_id)
      assert [_approved] = events(run_id, "MergeGateApproved")
    end

    test "run.pr.waive_evidence is refused too" do
      {_project_id, %{run_id: run_id}} = gated_run!()

      command =
        system_command("run.pr.waive_evidence", run_id, %{
          head_sha: "head-one",
          policy_version: "v",
          reasons: ["skipped"],
          reason: "x"
        })

      assert {:error, {:operator_only, "run.pr.waive_evidence"}} =
               CommandGateway.dispatch_system(command)

      assert events(run_id, "PrEvidenceWaived") == []
    end
  end

  describe "RunPrMerge.verify_head/3" do
    test "still answers :ok or an error; observe_head/3 also returns what it read", %{gh: gh} do
      {_project_id, %{run_id: run_id, pr_url: pr_url}} = gated_run!()

      assert :ok = RunPrMerge.verify_head(run_id, nil, "head-one")

      assert {:ok, %{pr_url: ^pr_url, status: %{head_sha: "head-one"}}} =
               RunPrMerge.observe_head(run_id, nil, "head-one")

      assert {:error, {:head_sha_mismatch, "other", "head-one"}} =
               RunPrMerge.verify_head(run_id, nil, "other")

      assert length(gh_views(gh)) == 3

      assert {:ok, _} = approve(run_id)
      assert :ok = RunPrMerge.verify_head(run_id, nil, "head-one")
      assert {:ok, nil} = RunPrMerge.observe_head(run_id, nil, "head-one")
    end
  end
end
