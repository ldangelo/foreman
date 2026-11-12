defmodule ForemanServer.PrReadyFailedTest do
  # TRD-033: a failed ready signal is a recorded condition. `PrReadySignal` dispatches the
  # system command `run.pr.ready_failed`; the `Run` aggregate appends `PrReadyFailed`; the ONE
  # shared fold (`PrEvidence`) holds `evidence.delivery_issue` in the aggregate and in the
  # projection; the next `PrReady` clears it. Real command dispatch, event store, aggregate
  # and projection; only `gh` is scripted.
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Run
  alias ForemanServer.CommandGateway
  alias ForemanServer.Identity
  alias ForemanServer.PrEvidence
  alias ForemanServer.PrReadySignal
  alias ForemanServer.PrWatchFold
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.PrReadyGithub
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support

  @pr_url "https://github.com/acme/widgets/pull/3301"

  setup do
    on_exit(&PrReadySignal.clear_command_runner/0)
    %{run: Support.start_run!(complete: true)}
  end

  defp attrs(run, extra \\ %{}) do
    Map.merge(
      %{
        run_id: run.run_id,
        project_id: run.project_id,
        task_id: run.task_id,
        pr_url: @pr_url,
        branch_name: "foreman/#{run.run_id}/implement",
        base_branch: "main"
      },
      extra
    )
  end

  defp failed_events(run_id),
    do: run_id |> Support.run_events() |> Enum.filter(&(&1.event_type == "PrReadyFailed"))

  defp failed_command(run, extra \\ %{}, at \\ 1_000) do
    %{
      type: "run.pr.ready_failed",
      command_id: Identity.run_pr_ready_failed_command_id(run.run_id, nil, at),
      aggregate_id: "run:#{run.run_id}",
      payload:
        Map.merge(
          %{
            run_id: run.run_id,
            project_id: run.project_id,
            task_id: run.task_id,
            pr_url: @pr_url,
            stage: "head_read",
            reason: "gh_failed:1",
            failed_at: at
          },
          extra
        )
    }
  end

  # The record both folds hold for `@pr_url`, read from the live aggregate state and from the
  # projection.
  defp aggregate_record(run_id) do
    state =
      run_id
      |> Support.run_events()
      |> Enum.reduce(Run.initial_state(), fn event, state ->
        Run.apply_event(state, %{event_type: event.event_type, payload: event.data})
      end)

    state.pr_watch[@pr_url]
  end

  defp projection_record(run_id),
    do: run_id |> ProjectionStore.pr_watch() |> Enum.find(&(&1.pr_url == @pr_url))

  describe "the failure record at the signal" do
    test "a failed GitHub read appends no PrReady and records stage head_read with the reason, never gh output",
         %{run: run} do
      PrReadyGithub.install!(fn _url -> {:error, 13} end)

      assert {:error, {:head_read_failed, {:gh_failed, 13, _output}}} =
               PrReadySignal.signal(attrs(run))

      refute "PrReady" in Support.run_event_types(run.run_id)

      assert [failed] = failed_events(run.run_id)
      assert failed.data.stage == "head_read"
      assert failed.data.reason == "gh_failed:13"
      assert failed.data.pr_url == @pr_url
      assert failed.data.run_id == run.run_id
      assert failed.data.project_id == run.project_id
      assert failed.data.task_id == run.task_id
      assert is_integer(failed.data.failed_at)
      refute Map.get(failed.data, :repo_id)
      refute inspect(failed.data) =~ "could not resolve"

      # the run still completed: a PR outlives its run
      assert "RunCompleted" in Support.run_event_types(run.run_id)
    end

    test "a refused run.pr.ready records stage ready_dispatch", %{run: run} do
      PrReadyGithub.install!(%{@pr_url => PrReadyGithub.sha("h")})

      # GitHub is readable; the command is refused (no branch_name)
      assert {:error, {:ready_dispatch_failed, {:missing_or_invalid, :branch_name}}} =
               PrReadySignal.signal(attrs(run, %{branch_name: ""}))

      refute "PrReady" in Support.run_event_types(run.run_id)

      assert [failed] = failed_events(run.run_id)
      assert failed.data.stage == "ready_dispatch"
      assert failed.data.reason == "missing_or_invalid"
    end

    test "a secondary repository's failure carries its repo_id", %{run: run} do
      PrReadyGithub.install!(fn _url -> {:error, 1} end)

      assert {:error, {:head_read_failed, _}} =
               PrReadySignal.signal(attrs(run, %{repo_id: "b"}))

      assert [%{data: %{repo_id: "b", stage: "head_read"}}] = failed_events(run.run_id)
    end

    test "a successful signal records no failure", %{run: run} do
      PrReadyGithub.install!(%{@pr_url => PrReadyGithub.sha("h")})
      assert :ok = PrReadySignal.signal(attrs(run))
      assert failed_events(run.run_id) == []
      assert %{evidence: %{delivery_issue: nil}} = projection_record(run.run_id)
    end
  end

  describe "the command" do
    test "is accepted on a completed run and appends PrReadyFailed", %{run: run} do
      assert "RunCompleted" in Support.run_event_types(run.run_id)

      assert {:ok, %{"event_type" => "PrReadyFailed"}} =
               CommandGateway.dispatch_system(failed_command(run))

      assert [_] = failed_events(run.run_id)
    end

    test "without a pr_url is rejected and nothing is appended", %{run: run} do
      command = failed_command(run)
      command = %{command | payload: Map.delete(command.payload, :pr_url)}

      assert {:error, {:missing_or_invalid, :pr_url}} = CommandGateway.dispatch_system(command)
      assert failed_events(run.run_id) == []
    end

    test "with a stage outside head_read | ready_dispatch is rejected", %{run: run} do
      for stage <- ["push", "", nil, :head_read_failed, "HEAD_READ"] do
        assert {:error, {:missing_or_invalid, :stage}} =
                 CommandGateway.dispatch_system(failed_command(run, %{stage: stage}))
      end

      assert failed_events(run.run_id) == []
    end

    test "without a reason or failed_at is rejected", %{run: run} do
      for {key, value} <- [reason: nil, reason: "", failed_at: nil, failed_at: -1, failed_at: "1"] do
        assert {:error, {:missing_or_invalid, ^key}} =
                 CommandGateway.dispatch_system(failed_command(run, %{key => value}))
      end

      assert failed_events(run.run_id) == []
    end

    test "two attempts with different failed_at are two events; one attempt repeated is one",
         %{run: run} do
      assert {:ok, _} = CommandGateway.dispatch_system(failed_command(run, %{}, 1_000))
      CommandGateway.dispatch_system(failed_command(run, %{}, 1_000))
      assert length(failed_events(run.run_id)) == 1

      assert {:ok, _} = CommandGateway.dispatch_system(failed_command(run, %{}, 2_000))

      assert [%{data: %{failed_at: 1_000}}, %{data: %{failed_at: 2_000}}] =
               failed_events(run.run_id)
    end

    test "has an id per run, repository and attempt" do
      assert Identity.run_pr_ready_failed_command_id("r", nil, 5) ==
               "workflow:r:pr_ready_failed:5"

      assert Identity.run_pr_ready_failed_command_id("r", "b", 5) ==
               "workflow:r:b:pr_ready_failed:5"

      refute Identity.run_pr_ready_failed_command_id("r", nil, 5) ==
               Identity.run_pr_ready_failed_command_id("r", nil, 6)
    end
  end

  describe "evidence.delivery_issue in both folds" do
    test "both folds hold it, equal, and a later successful PrReady clears it in both", %{
      run: run
    } do
      PrReadyGithub.install!(fn _url -> {:error, 1} end)
      assert {:error, _} = PrReadySignal.signal(attrs(run))

      [%{data: %{failed_at: failed_at}}] = failed_events(run.run_id)
      expected = %{stage: "head_read", reason: "gh_failed:1", failed_at: failed_at}

      assert %{evidence: %{delivery_issue: ^expected}} = aggregate_record(run.run_id)
      assert %{evidence: %{delivery_issue: ^expected}} = projection_record(run.run_id)

      PrReadyGithub.install!(%{@pr_url => PrReadyGithub.sha("h")})
      assert :ok = PrReadySignal.signal(attrs(run))

      assert %{evidence: %{delivery_issue: nil}} = aggregate_record(run.run_id)
      assert %{evidence: %{delivery_issue: nil}} = projection_record(run.run_id)
    end

    test "a failure after a PrReady is held again, and head moves do not clear it" do
      record = %{head_sha: "h1", evidence: PrEvidence.empty()}
      failed = %{pr_url: @pr_url, stage: "ready_dispatch", reason: "x", failed_at: 7}

      record = PrEvidence.apply_event(record, "PrReadyFailed", failed)

      assert record.evidence.delivery_issue == %{
               stage: "ready_dispatch",
               reason: "x",
               failed_at: 7
             }

      moved = PrEvidence.apply_event(record, "PrChecksChanged", %{head_sha: "h2", checks: nil})
      assert moved.evidence.delivery_issue == record.evidence.delivery_issue

      cleared = PrEvidence.apply_event(moved, "PrReady", %{head_sha: "h2"})
      assert cleared.evidence.delivery_issue == nil
    end

    test "the projection rebuilt from the event log (string keys) holds the same record", %{
      run: run
    } do
      PrReadyGithub.install!(fn _url -> {:error, 1} end)
      assert {:error, _} = PrReadySignal.signal(attrs(run))

      live = projection_record(run.run_id).evidence.delivery_issue
      assert %{stage: "head_read"} = live

      replayed =
        run.run_id
        |> failed_events()
        |> Enum.reduce(%{}, fn event, watch ->
          payload = event.data |> Jason.encode!() |> Jason.decode!()
          PrWatchFold.fold(watch, event.event_type, payload)
        end)

      assert replayed[run.run_id][@pr_url].evidence.delivery_issue == live
    end
  end
end
