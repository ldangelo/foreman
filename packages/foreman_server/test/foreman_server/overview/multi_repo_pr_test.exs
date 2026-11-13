defmodule ForemanServer.Overview.MultiRepoPrTest do
  @moduledoc """
  foreman-w0tnj (live run `docs/acceptance/multi-repo-realgit-live-run.md`): a run that opened a
  PR in two repositories (a = the run's primary, events without `repo_id`; b = events with
  `repo_id: "b"`) must be read PER PR by the Overview.

    * the Pull requests tab lists one row per PR, not one row per run (the primary's);
    * the card is classified over every live PR: a failing check on b's open PR keeps the thread
      in Waiting on you after a's PR merged, and the thread only resolves once no PR is live.

  A single-repository run reads exactly as it did: the control tests below pin that.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.{Overview, ProjectionStore}
  alias ForemanServer.Overview.Tabs
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @project "mr-project"
  @run "mr-run"
  @url_a "https://github.com/acme/a/pull/1"
  @url_b "https://github.com/acme/b/pull/2"

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    register_project!(%{})
    :ok
  end

  # A registered project: a PR of an unknown project has unknown evidence (TRD-024). `config`
  # holds the project's settings (`required_checks` turns the evidence gate on).
  defp register_project!(config) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: @project, path: "/r/" <> @project, config: config}
        }
      ])
  end

  defp ev(type, payload), do: %{event_type: type, payload: payload}
  defp apply!(events), do: :ok = ProjectionStore.apply_events(events)

  defp repo(payload, nil), do: payload
  defp repo(payload, repo_id), do: Map.put(payload, :repo_id, repo_id)

  defp started(run_id, repo_ids) do
    [
      ev("RunStarted", %{
        run_id: run_id,
        task_id: "t-" <> run_id,
        project_id: @project,
        repo_ids: repo_ids
      }),
      ev("RunCompleted", %{run_id: run_id, project_id: @project})
    ]
  end

  # What the run pipeline records for one repository's PR: the association (a strict event: it
  # declares no project_id) and the gate hold.
  defp opened(run_id, repo_id, url, number) do
    association = %{run_id: run_id, pr_url: url, pr_number: number}

    ready =
      Map.merge(association, %{
        project_id: @project,
        head_sha: "sha-#{number}",
        base_branch: "main"
      })

    [ev("PrAssociated", repo(association, repo_id)), ev("PrReady", repo(ready, repo_id))]
  end

  # The two-repository run of the live stage: both PRs open, both gates pending.
  defp two_repo_run(run_id \\ @run) do
    apply!(
      started(run_id, ["b"]) ++ opened(run_id, nil, @url_a, 1) ++ opened(run_id, "b", @url_b, 2)
    )
  end

  defp merged(run_id, repo_id, url, number) do
    ev(
      "PrUpdated",
      repo(
        %{
          run_id: run_id,
          pr_url: url,
          pr_status: "merged",
          head_sha: "sha-#{number}",
          base_branch: "main",
          observed_at: 2_000_000 + number
        },
        repo_id
      )
    )
  end

  defp status(run_id, repo_id, url, pr_status) do
    ev(
      "PrUpdated",
      repo(
        %{run_id: run_id, pr_url: url, pr_status: pr_status, observed_at: 1_000_000},
        repo_id
      )
    )
  end

  defp checks(run_id, repo_id, url, state) do
    ev(
      "PrChecksChanged",
      repo(
        %{
          run_id: run_id,
          project_id: @project,
          task_id: "t-" <> run_id,
          pr_url: url,
          head_sha: "sha-x",
          pr_status: "open",
          checks_state: state,
          failing: if(state == "failing", do: [%{name: "e2e-ci"}], else: []),
          digest: "d-#{state}",
          observation_seq: 1
        },
        repo_id
      )
    )
  end

  defp gate_approved(run_id, repo_id) do
    ev(
      "MergeGateApproved",
      repo(%{run_id: run_id, approver: "leo", approver_identity: "leo", approved_at: 5}, repo_id)
    )
  end

  defp card(run_id \\ @run) do
    {:ok, overview} = Overview.build(@project, include_resolved: true)

    case overview.groups
         |> Map.values()
         |> List.flatten()
         |> Enum.filter(&(&1.thread_id == "run:" <> run_id)) do
      [card] -> card
      other -> flunk("expected exactly one card for #{run_id}, got #{inspect(other)}")
    end
  end

  defp classification(run_id \\ @run) do
    card = card(run_id)
    {card.group, card.reason}
  end

  defp rows(run_id \\ @run) do
    %{available: true, rows: rows} = Tabs.build(@project).pull_requests
    Enum.filter(rows, &(&1["run_id"] == run_id))
  end

  defp row_for(url, run_id \\ @run), do: Enum.find(rows(run_id), &(&1["pr_url"] == url))

  describe "Pull requests tab: one row per PR" do
    test "a run that opened a PR in two repositories shows both PRs" do
      two_repo_run()

      assert [row_a, row_b] = rows()

      assert %{"run_id" => @run, "pr_url" => @url_a, "pr_number" => 1, "pr_state" => "open"} =
               row_a

      assert %{
               "run_id" => @run,
               "thread_id" => "run:" <> @run,
               "repo_id" => "b",
               "pr_url" => @url_b,
               "pr_number" => 2,
               "pr_state" => "open",
               "merge_gate" => "pending",
               "head_sha" => "sha-2"
             } = row_b

      # The primary's row names no repository: a missing `repo_id` always means the run's primary.
      refute Map.has_key?(row_a, "repo_id")
    end

    test "each row carries its own state: a merged, b still open" do
      two_repo_run()
      apply!([merged(@run, nil, @url_a, 1)])

      assert length(rows()) == 2
      assert %{"pr_state" => "merged"} = row_for(@url_a)
      assert %{"pr_state" => "open", "repo_id" => "b"} = row_for(@url_b)
    end

    test "a PR merged in b alone leaves a's row open" do
      two_repo_run()
      apply!([merged(@run, "b", @url_b, 2)])

      assert length(rows()) == 2
      assert %{"pr_state" => "open"} = row_for(@url_a)
      assert %{"pr_state" => "merged", "repo_id" => "b"} = row_for(@url_b)
    end

    test "control: a single-repository run keeps exactly one row and no repo_id key" do
      apply!(started("solo", []) ++ opened("solo", nil, @url_a, 1))

      assert [row] = rows("solo")
      assert %{"pr_url" => @url_a, "pr_state" => "open", "merge_gate" => "pending"} = row
      refute Map.has_key?(row, "repo_id")
    end

    test "control: a repository that opened no PR adds no row" do
      apply!(started(@run, ["b"]) ++ opened(@run, nil, @url_a, 1))

      assert [%{"pr_url" => @url_a}] = rows()
    end

    test "newest activity first; rows with the same activity list the primary first" do
      Process.put(:projection_store_now_ms, fn -> 1_000 end)
      two_repo_run("older")
      Process.put(:projection_store_now_ms, fn -> 2_000 end)
      two_repo_run("newer")
      Process.delete(:projection_store_now_ms)

      %{rows: all} = Tabs.build(@project).pull_requests

      assert Enum.map(all, &{&1["run_id"], &1["repo_id"]}) == [
               {"newer", nil},
               {"newer", "b"},
               {"older", nil},
               {"older", "b"}
             ]
    end
  end

  describe "card classification over every live PR" do
    test "control: both PRs open and pending, nothing failing: ready for review" do
      two_repo_run()
      assert classification() == {:ready_for_review, :pr_ready}
    end

    test "control: a failing check on b's PR waits on you while a is still open" do
      two_repo_run()
      apply!([checks(@run, "b", @url_b, "failing")])
      assert classification() == {:waiting_on_you, :ci_failing}
    end

    test "a failing check on b's PR keeps the thread in Waiting on you after a's PR merged" do
      two_repo_run()
      apply!([checks(@run, "b", @url_b, "failing"), merged(@run, nil, @url_a, 1)])

      assert classification() == {:waiting_on_you, :ci_failing}

      {:ok, overview} = Overview.build(@project, include_resolved: true)
      assert overview.counts.resolved == 0
      assert overview.counts.waiting_on_you == 1
      assert %{needed: true, count: 1, reasons: [:ci_failing]} = overview.attention
    end

    test "Fix CI is offered for b's live PR once a's PR merged" do
      two_repo_run()
      apply!([checks(@run, "b", @url_b, "failing"), merged(@run, nil, @url_a, 1)])

      assert %{pr_actions: actions} = card()

      assert %{kind: :fix_ci, enabled: true, pr_url: @url_b} =
               Enum.find(actions, &(&1.kind == :fix_ci))
    end

    test "b's check turning green after a merged leaves b's PR as the thread's open work" do
      two_repo_run()

      apply!([
        checks(@run, "b", @url_b, "failing"),
        merged(@run, nil, @url_a, 1),
        checks(@run, "b", @url_b, "passing")
      ])

      assert classification() == {:ready_for_review, :pr_ready}
    end

    test "a merged and b open with nothing failing is ready for review, not resolved" do
      two_repo_run()
      apply!([merged(@run, nil, @url_a, 1)])
      assert classification() == {:ready_for_review, :pr_ready}
    end

    test "a closed unmerged and b open and failing waits on you" do
      two_repo_run()
      apply!([status(@run, nil, @url_a, "closed"), checks(@run, "b", @url_b, "failing")])
      assert classification() == {:waiting_on_you, :ci_failing}
    end

    test "a merge conflict on b's PR waits on you after a merged" do
      two_repo_run()
      apply!([merged(@run, nil, @url_a, 1), status(@run, "b", @url_b, "conflicted")])
      assert classification() == {:waiting_on_you, :conflict}
    end

    test "b's approved merge gate is landing once a merged" do
      two_repo_run()
      apply!([merged(@run, nil, @url_a, 1), gate_approved(@run, "b")])
      assert classification() == {:landing, :merge_in_flight}
    end

    test "a's pending gate is not mistaken for b's approval (gate read over live PRs only)" do
      two_repo_run()
      apply!([gate_approved(@run, nil), merged(@run, nil, @url_a, 1)])

      # a's approved gate belonged to a PR that has since merged: b is merely pending.
      assert classification() == {:ready_for_review, :pr_ready}
    end

    test "control: a failing check on the primary still waits on you when b already merged" do
      two_repo_run()
      apply!([merged(@run, "b", @url_b, 2), checks(@run, nil, @url_a, "failing")])
      assert classification() == {:waiting_on_you, :ci_failing}
    end

    test "the thread resolves once every PR is merged" do
      two_repo_run()
      apply!([merged(@run, nil, @url_a, 1), merged(@run, "b", @url_b, 2)])
      assert classification() == {:resolved, :pr_merged}
    end

    test "the thread resolves once every PR is merged or closed, a merged and b closed" do
      two_repo_run()
      apply!([merged(@run, nil, @url_a, 1), status(@run, "b", @url_b, "closed")])
      assert classification() == {:resolved, :pr_merged}
    end

    test "the thread is classified closed when every PR was closed unmerged" do
      two_repo_run()
      apply!([status(@run, nil, @url_a, "closed"), status(@run, "b", @url_b, "closed")])
      assert classification() == {:resolved, :pr_closed}
    end

    test "control: a single-repository merged run is resolved even with a stale failing watch" do
      apply!(started("solo", []) ++ opened("solo", nil, @url_a, 1))
      apply!([checks("solo", nil, @url_a, "failing"), merged("solo", nil, @url_a, 1)])
      assert classification("solo") == {:resolved, :pr_merged}
    end

    test "the card DTO of a single-repository run is unchanged by the multi-PR rollup" do
      apply!(started("solo", []) ++ opened("solo", nil, @url_a, 1))
      %{pr_state: :open, merge_gate: :pending} = card("solo")
      apply!([merged("solo", nil, @url_a, 1)])
      assert %{pr_state: :merged, merge_gate: :pending} = card("solo")
    end

    test "summary, summaries and attention agree with build for a multi-repository run" do
      two_repo_run()
      apply!([checks(@run, "b", @url_b, "failing"), merged(@run, nil, @url_a, 1)])

      {:ok, overview} = Overview.build(@project)
      assert overview.counts.waiting_on_you == 1
      assert Overview.summary(@project).counts == overview.counts
      assert Overview.attention(@project) == overview.attention

      assert %{@project => %{counts: counts, attention: attention}} =
               Overview.summaries([@project])

      assert counts == overview.counts
      assert attention == overview.attention
    end
  end

  # TRD-024: each PR of a run shows its OWN evidence, and the thread waits on the operator while
  # a pending PR's evidence is ineligible or unknown.
  describe "approval evidence per PR" do
    @unit %{"name" => "unit", "kind" => "check_run"}
    @hostile "<script>alert('f')</script>"

    # Everything the gate reads for one PR: a passing required check, a clean findings record
    # (with one declined minor finding carrying hostile text) and a risk record, all for `head`.
    defp evidence(run_id, repo_id, url, head) do
      base = %{run_id: run_id, pr_url: url, head_sha: head}

      [
        ev(
          "PrChecksChanged",
          repo(
            Map.merge(base, %{
              project_id: @project,
              task_id: "t-" <> run_id,
              pr_status: "open",
              checks_state: "passing",
              failing: [],
              checks: [%{"name" => "unit", "kind" => "check_run", "state" => "passing"}],
              observed_at: 1_000_000,
              evidence_digest: "ed-#{head}",
              digest: "d-#{head}",
              observation_seq: 1
            }),
            repo_id
          )
        ),
        ev(
          "ReviewFindingsRecorded",
          repo(
            Map.merge(base, %{
              status: "recorded",
              digest: "fd-#{head}",
              findings: [
                %{
                  "severity" => "minor",
                  "disposition" => "declined",
                  "description" => "finding of #{head}: #{@hostile}"
                }
              ]
            }),
            repo_id
          )
        ),
        ev(
          "PrRiskRecorded",
          repo(
            Map.merge(base, %{
              level: "low",
              rubric_version: "1",
              digest: "rd-#{head}",
              findings_digest: "fd-#{head}",
              seq: 1
            }),
            repo_id
          )
        )
      ]
    end

    setup do
      register_project!(%{required_checks: [@unit]})
    end

    test "each PR of a run carries its own evidence, not the primary's" do
      two_repo_run()
      apply!(evidence(@run, nil, @url_a, "sha-1"))

      assert %{"evidence" => a} = row_for(@url_a)
      assert %{"evidence" => b} = row_for(@url_b)

      assert a["pr_url"] == @url_a
      assert a["status"] == "eligible"
      assert a["reasons"] == []
      assert a["risk"]["level"] == "low"
      assert [%{"description" => description}] = a["findings"]["items"]
      assert description =~ "finding of sha-1"

      assert b["pr_url"] == @url_b
      assert b["status"] == "ineligible"
      codes = Enum.map(b["reasons"], & &1["code"])
      assert "findings_absent" in codes and "risk_missing" in codes
      assert b["findings"] == nil and b["risk"] == nil
    end

    test "a's evidence for its own head does not clear b's: the thread waits on the operator" do
      two_repo_run()
      apply!(evidence(@run, nil, @url_a, "sha-1"))

      assert classification() == {:waiting_on_you, :evidence_blocked}
      assert :evidence_blocked in Overview.attention(@project).reasons

      apply!(evidence(@run, "b", @url_b, "sha-2"))
      assert classification() == {:ready_for_review, :pr_ready}
    end

    test "evidence recorded for another head blocks the PR" do
      two_repo_run()
      apply!(evidence(@run, nil, @url_a, "sha-1") ++ evidence(@run, "b", @url_b, "sha-2"))

      apply!([
        ev("ReviewFindingsRecorded", %{
          run_id: @run,
          repo_id: "b",
          pr_url: @url_b,
          head_sha: "older-head",
          status: "recorded",
          findings: []
        })
      ])

      assert classification() == {:waiting_on_you, :evidence_blocked}

      assert %{"evidence" => %{"reasons" => reasons}} = row_for(@url_b)
      assert "findings_other_sha" in Enum.map(reasons, & &1["code"])
    end

    test "b's approved gate lands the thread whatever a's evidence says" do
      two_repo_run()
      apply!([gate_approved(@run, "b")])
      assert classification() == {:landing, :merge_in_flight}
    end

    test "a merged PR with bad evidence no longer blocks; the other PR's evidence decides" do
      two_repo_run()
      apply!(evidence(@run, "b", @url_b, "sha-2") ++ [merged(@run, nil, @url_a, 1)])
      assert classification() == {:ready_for_review, :pr_ready}
    end

    test "with the gate off the same PRs read as they did before" do
      register_project!(%{})
      two_repo_run()

      assert classification() == {:ready_for_review, :pr_ready}
      assert %{"evidence" => %{"status" => "off", "reasons" => []}} = row_for(@url_a)
    end

    test "a PR of a project the store does not know has unknown evidence and blocks" do
      ProjectionStoreReset.reset!()
      two_repo_run()

      assert classification() == {:waiting_on_you, :evidence_blocked}
      assert %{"evidence" => %{"status" => "unknown", "reasons" => [reason]}} = row_for(@url_a)
      assert reason["code"] == "evidence_unreadable"
    end

    test "the project's policy is read once per classification, not once per PR" do
      for n <- 1..3 do
        run = "many-#{n}"
        apply!(started(run, []) ++ opened(run, nil, "https://github.com/acme/m/pull/#{n}", n))
      end

      calls =
        count_calls({ForemanServer.PrEvidence, :project_policy, 2}, fn ->
          %{counts: counts} = Overview.summary(@project)
          assert counts.waiting_on_you == 3
        end)

      assert calls == 1
    end
  end

  # The number of calls `mfa` receives in this process while `fun` runs, counted by a separate
  # tracer process (a process does not receive its own trace messages).
  defp count_calls({module, _function, _arity} = mfa, fun) do
    test = self()
    tracer = spawn_link(fn -> tracer_loop(test, 0) end)
    {:module, ^module} = Code.ensure_loaded(module)
    :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern(mfa, false, [:local])
    end

    ref = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _pid, ^ref}
    send(tracer, :report)
    assert_receive {:trace_calls, count}
    count
  end

  defp tracer_loop(test, count) do
    receive do
      {:trace, _pid, :call, _mfa} -> tracer_loop(test, count + 1)
      :report -> send(test, {:trace_calls, count})
    end
  end
end
