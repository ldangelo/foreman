defmodule ForemanServer.Webhooks.GithubTest do
  # Drives the real projection, aggregate and event store. Attribution is by PR URL
  # through the run's recorded association; nothing in a payload names a run.
  use ExUnit.Case, async: false

  alias ForemanServer.PrAssociate
  alias ForemanServer.Webhooks.Github

  setup do
    run_id = "run-gh-webhook-#{System.unique_integer([:positive])}"
    pr_url = "https://github.com/acme/repo/pull/#{System.unique_integer([:positive])}"
    started = %{run_id: run_id, project_id: "project-gh", task_id: "task-gh"}

    :ok =
      ForemanServer.EventStore.append_to_stream("run:#{run_id}", 0, [
        %EventStore.EventData{event_type: "RunStarted", data: started, metadata: %{}}
      ])

    :ok =
      ForemanServer.ProjectionStore.apply_events([%{event_type: "RunStarted", payload: started}])

    {:ok, ^run_id} = PrAssociate.store(run_id, pr_url)

    %{run_id: run_id, pr_url: pr_url}
  end

  defp payload(action, pr_url, pr_overrides \\ %{}) do
    %{
      "action" => action,
      "pull_request" =>
        Map.merge(
          %{
            "html_url" => pr_url,
            "merged" => false,
            "head" => %{"sha" => "abc123", "ref" => "foreman/task-gh/run"},
            "base" => %{"ref" => "main"}
          },
          pr_overrides
        )
    }
  end

  defp pr_updated(run_id) do
    {:ok, events} = ForemanServer.EventStore.read_stream_forward("run:#{run_id}", 0, 1_000)
    Enum.filter(events, &(&1.event_type == "PrUpdated"))
  end

  describe "status mapping" do
    test "closed + merged is :merged", %{pr_url: pr_url, run_id: run_id} do
      assert {:ok, [command]} =
               Github.build_commands(payload("closed", pr_url, %{"merged" => true}))

      assert command.type == "run.pr.update"
      assert command.aggregate_id == "run:#{run_id}"
      assert command.payload.pr_status == :merged
      assert command.payload.phase == "merge_pending"
    end

    test "closed without a merge is :closed", %{pr_url: pr_url} do
      assert {:ok, [command]} = Github.build_commands(payload("closed", pr_url))
      assert command.payload.pr_status == :closed
      assert command.payload.phase == "pr_closed"
    end

    test "reopened is :open", %{pr_url: pr_url} do
      assert {:ok, [command]} = Github.build_commands(payload("reopened", pr_url))
      assert command.payload.pr_status == :open
      assert command.payload.phase == "pr_open"
    end

    test "mergeable_state dirty is a conflict", %{pr_url: pr_url} do
      assert {:ok, [command]} =
               Github.build_commands(
                 payload("synchronize", pr_url, %{"mergeable_state" => "dirty"})
               )

      assert command.payload.pr_status == :conflicted
      assert command.payload.phase == "pr_conflict"
    end

    test "mergeable_state blocked is NOT a conflict: it is a healthy PR awaiting checks",
         %{pr_url: pr_url} do
      assert :ignored =
               Github.build_commands(
                 payload("synchronize", pr_url, %{"mergeable_state" => "blocked"})
               )
    end
  end

  describe "the command carries everything the aggregate requires" do
    test "ids from the run, branch/sha/base from the payload", %{pr_url: pr_url} do
      assert {:ok, [%{payload: p}]} =
               Github.build_commands(payload("closed", pr_url, %{"merged" => true}))

      assert p.project_id == "project-gh"
      assert p.task_id == "task-gh"
      assert p.pr_url == pr_url
      assert p.branch_name == "foreman/task-gh/run"
      assert p.head_sha == "abc123"
      assert p.base_branch == "main"
    end

    test "a payload missing the head sha is a named error, not a guess", %{pr_url: pr_url} do
      bad = payload("closed", pr_url, %{"head" => %{"ref" => "x"}})

      assert {:error, {:pr_payload_missing, :head_sha}} = Github.build_commands(bad)
    end
  end

  describe "attribution is by PR url, never by anything the sender names" do
    test "a PR no run owns is ignored", %{run_id: run_id} do
      unowned = "https://github.com/acme/repo/pull/9999999"

      assert :ignored = Github.process(payload("closed", unowned, %{"merged" => true}))
      assert pr_updated(run_id) == []
    end

    test "a payload cannot pick its run with a run_id key", %{pr_url: pr_url} do
      attack = Map.put(payload("closed", pr_url, %{"merged" => true}), "run_id", "run-victim")
      attack = put_in(attack, ["sender"], %{"login" => "run-victim"})

      assert {:ok, [command]} = Github.build_commands(attack)
      refute command.aggregate_id == "run:run-victim"
    end

    test "every run associated with the PR is updated" do
      shared = "https://github.com/acme/repo/pull/#{System.unique_integer([:positive])}"

      ids =
        for n <- 1..2 do
          id = "run-gh-shared-#{n}-#{System.unique_integer([:positive])}"
          started = %{run_id: id, project_id: "project-gh", task_id: "task-gh"}

          :ok =
            ForemanServer.EventStore.append_to_stream("run:#{id}", 0, [
              %EventStore.EventData{event_type: "RunStarted", data: started, metadata: %{}}
            ])

          :ok =
            ForemanServer.ProjectionStore.apply_events([
              %{event_type: "RunStarted", payload: started}
            ])

          {:ok, ^id} = PrAssociate.store(id, shared)
          id
        end

      assert :ok = Github.process(payload("closed", shared, %{"merged" => true}))
      for id <- ids, do: assert([_one] = pr_updated(id))
    end
  end

  describe "process/1 against the real aggregate" do
    test "appends PrUpdated to the owning run", %{pr_url: pr_url, run_id: run_id} do
      assert :ok = Github.process(payload("closed", pr_url, %{"merged" => true}))
      assert [event] = pr_updated(run_id)
      assert event.data.pr_status in [:merged, "merged"]
    end

    test "a redelivery appends nothing new", %{pr_url: pr_url, run_id: run_id} do
      body = payload("closed", pr_url, %{"merged" => true})

      assert :ok = Github.process(body)
      assert :ok = Github.process(body)

      assert [_one] = pr_updated(run_id), "GitHub retries deliveries; each must not append"
    end
  end

  describe "ignore paths" do
    test "a non-map payload is ignored" do
      assert :ignored = Github.process("not a map")
      assert :ignored = Github.process(nil)
    end

    test "an unhandled action is ignored", %{pr_url: pr_url} do
      assert :ignored = Github.process(payload("labeled", pr_url))
    end

    test "a payload with no pull_request is ignored" do
      assert :ignored = Github.process(%{"action" => "closed"})
    end
  end

  # TRD-030: the report comment the publisher posts comes back as an `issue_comment` delivery,
  # which asks the watcher to re-read the PR. The re-read must not see Foreman's own comment as
  # review feedback, or every report would move the review digest and emit `run.pr.review`.
  describe "the publisher's own report comment (TRD-030)" do
    alias ForemanServer.{PrReport, PrWatcher, ProjectionStore}
    alias ForemanServer.TestSupport.Eventually
    alias ForemanServer.TestSupport.PrWatchSupport, as: Support

    @describetag :capture_log

    defp comment_delivery(pr_url) do
      %{
        "action" => "created",
        "issue" => %{"html_url" => pr_url, "pull_request" => %{"url" => "x"}},
        "comment" => %{"body" => "hi"}
      }
    end

    defp pr_comment(id, viewer_did_author) do
      %{
        id: id,
        author: "x",
        bot: false,
        viewer_did_author: viewer_did_author,
        body: PrReport.marker("run-1", "sha-1", "d1") <> "\nreport text",
        url: nil,
        created_at: nil
      }
    end

    defp review_events(run_id),
      do: Enum.filter(Support.run_events(run_id), &(&1.event_type == "PrReviewChanged"))

    defp review_digest(run_id, pr_url),
      do: Enum.find(ProjectionStore.pr_watch(run_id), &(&1.pr_url == pr_url)).review_digest

    setup do
      run = Support.start_run!(complete: true)
      {:ok, _} = PrAssociate.store(run.run_id, run.pr_url)
      test_pid = self()
      {:ok, agent} = Agent.start_link(fn -> Support.status() end)

      fetch = fn _url ->
        send(test_pid, :fetched)
        {:ok, Agent.get(agent, & &1)}
      end

      start_supervised!({PrWatcher, fetch_fun: fetch})
      assert {:ok, _} = PrWatcher.refresh_now(run.pr_url)
      assert_received :fetched

      {:ok, Map.put(run, :agent, agent)}
    end

    defp events_of(run_id, type),
      do: Enum.filter(Support.run_events(run_id), &(&1.event_type == type))

    # The webhook alone asks for the re-read: nothing else calls the watcher, so the fetch and
    # the observation counted after it are the webhook's. Returns once that observation is done.
    defp deliver_comment(ctx, comments) do
      before = PrWatcher.stats().observations
      Agent.update(ctx.agent, &%{&1 | comments: comments})
      refute_received :fetched

      assert :ok = Github.process(comment_delivery(ctx.pr_url))
      assert_receive :fetched, 5_000, "the webhook did not make the watcher re-read the PR"

      Eventually.await(fn -> PrWatcher.stats().observations == before + 1 end,
        message: "the watcher finished the webhook's observation"
      )

      refute_received :fetched
    end

    test "the token's own marker comment moves no review digest and emits no run.pr.review",
         ctx do
      digest = review_digest(ctx.run_id, ctx.pr_url)
      risks = length(events_of(ctx.run_id, "PrRiskRecorded"))

      deliver_comment(ctx, [pr_comment("IC_own", true)])

      assert review_events(ctx.run_id) == []
      assert review_digest(ctx.run_id, ctx.pr_url) == digest
      assert length(events_of(ctx.run_id, "PrRiskRecorded")) == risks
      assert events_of(ctx.run_id, "PrCommentPublished") == []
    end

    test "the same marker written by someone else is feedback: run.pr.review is emitted", ctx do
      digest = review_digest(ctx.run_id, ctx.pr_url)

      deliver_comment(ctx, [pr_comment("IC_foreign", false)])

      assert [%{data: %{comment_ids: ["IC_foreign"]}}] = review_events(ctx.run_id)
      refute review_digest(ctx.run_id, ctx.pr_url) == digest
    end
  end
end
