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
    :ok
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
end
