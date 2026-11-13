defmodule ForemanServer.PrReport.PublisherTest do
  @moduledoc """
  TRD-021: the PR report publisher. The risk records come from the real `PrWatcher` observing a
  scripted PR (so the events are the ones production appends), the comments from a fake `gh`
  that keeps a list of comments and counts every write that reaches it, and the keyed effect,
  the command handler, the fold and the projection are the real ones.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.Idempotency.Reconcilers.PrComment, as: CommentEffect
  alias ForemanServer.{PrAssociate, PrEvidence, PrReport, PrWatcher, ProjectionStore}
  alias ForemanServer.PrReport.Publisher
  alias ForemanServer.TestSupport.Eventually
  alias ForemanServer.TestSupport.KeyStoreReset
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support

  @required [%{"name" => "unit", "kind" => "check_run"}]

  # -- the fake GitHub --------------------------------------------------------------

  defmodule FakeGh do
    @moduledoc false
    # The comments of one PR and the `gh` calls the three PrComment functions make. Every
    # write that reaches it is logged in `writes`; `fail_write` answers a write with an error
    # (the write did not happen), `lose_answer` performs it and then answers with an error.

    def start(pr_url) do
      {:ok, agent} =
        Agent.start_link(fn ->
          %{
            pr_url: pr_url,
            comments: [],
            next: 1,
            writes: [],
            fail_write: nil,
            lose_answer: false
          }
        end)

      agent
    end

    def runner(agent),
      do: fn "gh", args, _opts -> Agent.get_and_update(agent, &call(&1, args)) end

    def seed(agent, body, own? \\ true, minimized? \\ false),
      do: Agent.update(agent, &(add(&1, body, own?, minimized?) |> elem(1)))

    def comments(agent), do: Agent.get(agent, &Enum.reverse(&1.comments))
    def writes(agent), do: Agent.get(agent, &Enum.reverse(&1.writes))
    def fail_write(agent, output), do: Agent.update(agent, &%{&1 | fail_write: output})
    def lose_answer(agent), do: Agent.update(agent, &%{&1 | lose_answer: true})

    defp call(state, ["pr", "view", _url, "--json", "comments"]) do
      items =
        state.comments
        |> Enum.reverse()
        |> Enum.map(fn c ->
          %{
            "id" => "IC_#{c.n}",
            "url" => "#{state.pr_url}#issuecomment-#{c.n}",
            "body" => c.body,
            "viewerDidAuthor" => c.own?,
            "isMinimized" => c.minimized?,
            "createdAt" =>
              "2026-11-12T10:00:#{String.pad_leading(Integer.to_string(c.n), 2, "0")}Z"
          }
        end)

      {{Jason.encode!(%{comments: items}), 0}, state}
    end

    defp call(state, ["api", "repos/" <> _path, "-f", "body=" <> body]) do
      write(state, :create, nil, body, fn state ->
        {n, state} = add(state, body, true)
        {n, state}
      end)
    end

    defp call(state, ["api", "-X", "PATCH", "repos/" <> path, "-f", "body=" <> body]) do
      n = path |> String.split("/") |> List.last() |> String.to_integer()

      write(state, :update, n, body, fn state ->
        comments = Enum.map(state.comments, &if(&1.n == n, do: %{&1 | body: body}, else: &1))
        {n, %{state | comments: comments}}
      end)
    end

    defp write(state, kind, target, body, perform) do
      state = %{state | writes: [{kind, target, body} | state.writes]}

      cond do
        state.fail_write != nil ->
          {{state.fail_write, 1}, state}

        state.lose_answer ->
          {_n, state} = perform.(state)
          {{"HTTP 502 bad gateway", 1}, %{state | lose_answer: false}}

        true ->
          {n, state} = perform.(state)

          answer = %{
            id: n,
            node_id: "IC_#{n}",
            html_url: "#{state.pr_url}#issuecomment-#{n}"
          }

          {{Jason.encode!(answer), 0}, state}
      end
    end

    defp add(state, body, own?, minimized? \\ false) do
      n = state.next
      comment = %{n: n, body: body, own?: own?, minimized?: minimized?}
      {n, %{state | next: n + 1, comments: [comment | state.comments]}}
    end
  end

  # -- the scripted PR ---------------------------------------------------------------

  defp start_github(initial) do
    {:ok, agent} = Agent.start_link(fn -> initial end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
    {agent, fn _url -> Agent.get(agent, & &1) end}
  end

  defp passing(head) do
    check = %{Support.failing_check("unit") | state: :passing, conclusion: "SUCCESS"}
    {:ok, Support.status(head_sha: head, checks: [check], checks_state: :passing)}
  end

  defp register_project!(config) do
    id = "p-pub-#{System.unique_integer([:positive])}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: id, path: "/tmp/#{id}", config: config}
        }
      ])

    id
  end

  # The risk record of `head` as the event the publisher is triggered by.
  defp risk_trigger(run_id, head) do
    run_id
    |> Support.run_events()
    |> Enum.filter(&(&1.event_type == "PrRiskRecorded" and &1.data.head_sha == head))
    |> List.last()
    |> Map.fetch!(:data)
  end

  defp report_events(run_id),
    do:
      for(%{event_type: "PrCommentPublished", data: data} <- Support.run_events(run_id), do: data)

  defp report(run_id),
    do: run_id |> ProjectionStore.pr_watch() |> hd() |> get_in([:evidence, :report])

  defp record(run_id), do: run_id |> ProjectionStore.pr_watch() |> hd()

  defp marker_of(body), do: PrReport.parse_marker(body)

  defp key_of(trigger), do: CommentEffect.key(trigger.run_id, trigger.head_sha, trigger.digest)

  setup do
    KeyStoreReset.reset!()
    :ok = ProjectionStore.subscribe(replay_existing: false)

    project_id = register_project!(%{required_checks: @required})
    ctx = Support.start_run!(project_id: project_id, complete: true)
    {github, fetch} = start_github(passing("sha-1"))
    gh = FakeGh.start(ctx.pr_url)
    on_exit(fn -> if Process.alive?(gh), do: Agent.stop(gh) end)

    {:ok, _} = PrAssociate.store(ctx.run_id, ctx.pr_url)
    start_supervised!({PrWatcher, fetch_fun: fetch})
    {:ok, _} = PrWatcher.refresh_now(ctx.pr_url)

    {:ok,
     Map.merge(ctx, %{
       github: github,
       gh: gh,
       runner: FakeGh.runner(gh),
       opts: [command_runner: FakeGh.runner(gh)],
       trigger: risk_trigger(ctx.run_id, "sha-1"),
       project_id: project_id
     })}
  end

  defp move_head!(ctx, head) do
    Agent.update(ctx.github, fn _ -> passing(head) end)
    {:ok, _} = PrWatcher.refresh_now(ctx.pr_url)
    risk_trigger(ctx.run_id, head)
  end

  describe "create" do
    test "publishes one comment bound to the head and digest and records it", ctx do
      assert {:published, %{action: :created, comment_id: id}} =
               Publisher.publish(ctx.trigger, ctx.opts)

      assert [{:create, nil, _body}] = FakeGh.writes(ctx.gh)
      assert [%{body: body, own?: true}] = FakeGh.comments(ctx.gh)
      assert {:ok, %{run_id: run_id, head_sha: "sha-1", digest: digest}} = marker_of(body)
      assert run_id == ctx.run_id and digest == ctx.trigger.digest

      assert [event] = report_events(ctx.run_id)

      assert %{
               status: "published",
               reason: nil,
               head_sha: "sha-1",
               comment_id: ^id,
               superseded: nil,
               pr_url: pr_url
             } = event

      assert pr_url == ctx.pr_url
      assert event.comment_url == ctx.pr_url <> "#issuecomment-#{id}"
      assert event.digest == ctx.trigger.digest

      assert %{head_sha: "sha-1", status: "published", comment_id: ^id} = report(ctx.run_id)
    end

    test "the post is the keyed pr_comment effect: its key settles completed", ctx do
      assert {:published, _} = Publisher.publish(ctx.trigger, ctx.opts)

      assert {:ok, %{status: :completed, metadata: metadata}} = KeyStore.get(key_of(ctx.trigger))
      assert metadata["effect_class"] == "pr_comment"
      assert metadata["head_sha"] == "sha-1"
      assert metadata["digest"] == ctx.trigger.digest
      assert metadata["pr_url"] == ctx.pr_url
    end

    test "the same trigger delivered again posts nothing and records nothing", ctx do
      assert {:published, _} = Publisher.publish(ctx.trigger, ctx.opts)
      assert {:skipped, :already_reported} = Publisher.publish(ctx.trigger, ctx.opts)

      assert [{:create, _, _}] = FakeGh.writes(ctx.gh)
      assert [_one] = FakeGh.comments(ctx.gh)
      assert [_one] = report_events(ctx.run_id)
    end
  end

  describe "supersede" do
    test "a new head edits the run's earlier comment: one comment, naming the new head", ctx do
      assert {:published, %{comment_id: id}} = Publisher.publish(ctx.trigger, ctx.opts)
      trigger2 = move_head!(ctx, "sha-2")
      refute trigger2.digest == ctx.trigger.digest

      assert {:published, %{action: :edited, comment_id: ^id, superseded: "sha-1"}} =
               Publisher.publish(trigger2, ctx.opts)

      assert [{:create, nil, _}, {:update, ^id, new_body}] = FakeGh.writes(ctx.gh)
      assert [%{body: body}] = FakeGh.comments(ctx.gh)
      assert body == new_body
      assert {:ok, %{head_sha: "sha-2", digest: digest}} = marker_of(body)
      assert digest == trigger2.digest

      assert [_first, second] = report_events(ctx.run_id)

      assert %{status: "published", head_sha: "sha-2", superseded: "sha-1", comment_id: ^id} =
               second

      # the report keeps naming the head it was published for, not the PR's current one
      assert %{head_sha: "sha-2", status: "published"} = report(ctx.run_id)
    end

    test "after a push, evidence.report keeps the old head until the new report is published",
         ctx do
      assert {:published, %{comment_id: id}} = Publisher.publish(ctx.trigger, ctx.opts)
      _trigger2 = move_head!(ctx, "sha-2")

      assert %{head_sha: "sha-2"} = record(ctx.run_id)
      assert %{head_sha: "sha-1", comment_id: ^id, status: "published"} = report(ctx.run_id)
    end

    test "only the token user's comments of this run are edited", ctx do
      other_run = PrReport.marker("run-other", "sha-0", "d0") <> "\n\nanother run's report"
      someone_else = PrReport.marker(ctx.run_id, "sha-0", "d0") <> "\n\ntyped by a person"
      FakeGh.seed(ctx.gh, other_run)
      FakeGh.seed(ctx.gh, someone_else, false)
      FakeGh.seed(ctx.gh, "an ordinary comment")

      assert {:published, %{action: :created}} = Publisher.publish(ctx.trigger, ctx.opts)

      assert [{:create, nil, _}] = FakeGh.writes(ctx.gh)

      assert [^other_run, ^someone_else, "an ordinary comment", _new] =
               Enum.map(FakeGh.comments(ctx.gh), & &1.body)
    end

    test "the latest of several comments of this run is the one edited", ctx do
      FakeGh.seed(ctx.gh, PrReport.marker(ctx.run_id, "sha-0", "d0") <> "\n\nold")
      FakeGh.seed(ctx.gh, PrReport.marker(ctx.run_id, "sha-00", "d00") <> "\n\nnewer")

      assert {:published, %{action: :edited, comment_id: 2, superseded: "sha-00"}} =
               Publisher.publish(ctx.trigger, ctx.opts)

      assert [{:update, 2, _}] = FakeGh.writes(ctx.gh)
    end
  end

  describe "adopt" do
    test "a comment of this run with the same head and digest is the result; nothing is written",
         ctx do
      body =
        PrReport.marker(ctx.run_id, "sha-1", ctx.trigger.digest) <> "\n\nwritten before a crash"

      FakeGh.seed(ctx.gh, body)

      assert {:published, %{action: :adopted, comment_id: 1}} =
               Publisher.publish(ctx.trigger, ctx.opts)

      assert [] = FakeGh.writes(ctx.gh)
      assert [%{body: ^body}] = FakeGh.comments(ctx.gh)

      assert [%{status: "published", comment_id: 1, superseded: nil}] = report_events(ctx.run_id)
      assert %{comment_id: 1} = report(ctx.run_id)
    end

    test "a marker typed by someone else is not adopted: the report is created", ctx do
      FakeGh.seed(ctx.gh, PrReport.marker(ctx.run_id, "sha-1", ctx.trigger.digest), false)

      assert {:published, %{action: :created, comment_id: 2}} =
               Publisher.publish(ctx.trigger, ctx.opts)

      assert [{:create, nil, _}] = FakeGh.writes(ctx.gh)
    end

    test "a settled (completed) key does not repost: the comment is found by its marker", ctx do
      assert {:published, %{comment_id: id}} = Publisher.publish(ctx.trigger, ctx.opts)
      assert {:ok, %{status: :completed}} = KeyStore.get(key_of(ctx.trigger))

      # the outcome was lost (nothing in the folded record names the report), the key is done
      assert {:published, %{action: :adopted, comment_id: ^id}} =
               Publisher.post(ctx.trigger, ctx.opts)

      assert [{:create, _, _}] = FakeGh.writes(ctx.gh)
      assert [_one] = FakeGh.comments(ctx.gh)
    end

    test "after an ambiguous create (the write happened, the answer was lost) nothing is posted twice",
         ctx do
      FakeGh.lose_answer(ctx.gh)

      assert {:refused, :gh_failed, detail} = Publisher.publish(ctx.trigger, ctx.opts)
      assert detail =~ "gh failed"
      assert [{:create, _, _}] = FakeGh.writes(ctx.gh)
      assert [%{body: body}] = FakeGh.comments(ctx.gh)
      assert {:ok, %{head_sha: "sha-1"}} = marker_of(body)

      # the refusal is recorded and not retried by the publisher
      assert {:skipped, :already_reported} = Publisher.publish(ctx.trigger, ctx.opts)
      assert [{:create, _, _}] = FakeGh.writes(ctx.gh)

      # an interrupted key left started/ambiguous is run again (the class is repeatable) and
      # finds its own comment by the marker before it writes
      key = key_of(ctx.trigger)
      meta = CommentEffect.intent(ctx.run_id, ctx.pr_url, "sha-1", ctx.trigger.digest)

      :ok =
        KeyStore.mark_started(key, Map.merge(%{"effect_class" => "pr_comment"}, stringify(meta)))

      :ok = KeyStore.mark_ambiguous(key)

      assert {:published, %{action: :adopted, comment_id: 1}} =
               Publisher.post(ctx.trigger, ctx.opts)

      assert [{:create, _, _}] = FakeGh.writes(ctx.gh)
      assert [_one] = FakeGh.comments(ctx.gh)
      assert {:ok, %{status: :completed}} = KeyStore.get(key)
    end
  end

  describe "when nothing is published" do
    defp assert_untouched(ctx) do
      assert [] = FakeGh.writes(ctx.gh)
      assert [] = FakeGh.comments(ctx.gh)
      assert [] = report_events(ctx.run_id)
    end

    test "a project with required_checks unset is ungated", ctx do
      ungated = register_project!(%{})
      other = Support.start_run!(project_id: ungated, complete: true)
      {:ok, _} = PrAssociate.store(other.run_id, other.pr_url)
      {:ok, _} = PrWatcher.refresh_now(other.pr_url)

      trigger = risk_trigger(other.run_id, "sha-1")
      assert {:skipped, :ungated} = Publisher.publish(trigger, ctx.opts)
      assert [] = FakeGh.writes(ctx.gh)
      assert [] = report_events(other.run_id)
    end

    test "a project whose policy cannot be read publishes nothing", ctx do
      # `project_policy/1` answers an error for a project the projection does not know; the
      # Observer then observes with no policy, and the risk it still records is not published
      stranger =
        Support.start_run!(
          project_id: "p-unknown-#{System.unique_integer([:positive])}",
          complete: true
        )

      {:ok, _} = PrAssociate.store(stranger.run_id, stranger.pr_url)
      {:ok, _} = PrWatcher.refresh_now(stranger.pr_url)

      assert {:error, {:policy_unavailable, :project_not_found}} =
               PrEvidence.project_policy(stranger.project_id)

      trigger = risk_trigger(stranger.run_id, "sha-1")
      assert {:skipped, :policy_unavailable} = Publisher.publish(trigger, ctx.opts)
      assert [] = FakeGh.writes(ctx.gh)
      assert [] = report_events(stranger.run_id)
    end

    test "a PR that is no longer open is not published", ctx do
      Agent.update(ctx.github, fn _ ->
        {:ok, Support.status(status: :closed, head_sha: "sha-1")}
      end)

      {:ok, _} = PrWatcher.refresh_now(ctx.pr_url)
      refute record(ctx.run_id).status == "open"

      assert {:skipped, :not_open_or_not_watched} = Publisher.publish(ctx.trigger, ctx.opts)
      assert_untouched(ctx)
    end

    test "a PR the run no longer watches is not published", ctx do
      {:ok, _} =
        ForemanServer.CommandGateway.dispatch_system(%{
          type: "run.pr.watch_stop",
          command_id: "stop-#{ctx.run_id}",
          aggregate_id: "run:#{ctx.run_id}",
          payload: %{run_id: ctx.run_id, pr_url: ctx.pr_url, reason: "operator"}
        })

      refute record(ctx.run_id).watching

      assert {:skipped, :not_open_or_not_watched} = Publisher.publish(ctx.trigger, ctx.opts)
      assert_untouched(ctx)
    end

    test "a risk record for another head than the record's current head is not published", ctx do
      _trigger2 = move_head!(ctx, "sha-2")

      assert {:skipped, :risk_not_current} = Publisher.publish(ctx.trigger, ctx.opts)
      assert_untouched(ctx)
    end

    test "a risk digest that is not the folded one is not published", ctx do
      assert {:skipped, :risk_not_current} =
               Publisher.publish(%{ctx.trigger | digest: "0000000000000000"}, ctx.opts)

      assert_untouched(ctx)
    end

    test "a PR the run does not watch, and a trigger without identity, are not published", ctx do
      assert {:skipped, :not_watched} =
               Publisher.publish(
                 %{ctx.trigger | pr_url: "https://github.com/acme/x/pull/9"},
                 ctx.opts
               )

      assert {:skipped, :invalid_trigger} = Publisher.publish(%{run_id: ctx.run_id}, ctx.opts)
      assert_untouched(ctx)
    end

    test "a report already published for the head and digest is not published again", ctx do
      assert {:published, _} = Publisher.publish(ctx.trigger, ctx.opts)
      assert {:skipped, :already_reported} = Publisher.publish(ctx.trigger, ctx.opts)
      assert [_] = report_events(ctx.run_id)
    end
  end

  describe "refusals" do
    test "a redaction list that cannot be resolved posts nothing and records redaction_failed",
         ctx do
      opts =
        Keyword.put(ctx.opts, :secrets_fun, fn _project ->
          {:error, {:reserved_project_env_keys, ["FOREMAN_SECRET_NAME"]}}
        end)

      assert {:refused, :redaction_failed, detail} = Publisher.publish(ctx.trigger, opts)
      assert detail =~ "reserved_project_env_keys"
      refute detail =~ "FOREMAN_SECRET_NAME"

      assert [] = FakeGh.writes(ctx.gh)
      assert [] = FakeGh.comments(ctx.gh)

      assert [%{status: "refused", reason: "redaction_failed", comment_id: nil} = event] =
               report_events(ctx.run_id)

      assert event.detail == detail
      assert %{status: "refused", reason: "redaction_failed"} = report(ctx.run_id)
    end

    test "a secret value that survives redaction posts nothing; the detail never holds it", ctx do
      opts = Keyword.put(ctx.opts, :secrets_fun, fn _project -> {:ok, ["sha-1"]} end)

      assert {:refused, :redaction_failed, detail} = Publisher.publish(ctx.trigger, opts)
      refute detail =~ "sha-1"

      assert [] = FakeGh.writes(ctx.gh)
      assert [%{reason: "redaction_failed", detail: stored}] = report_events(ctx.run_id)
      refute stored =~ "sha-1"
    end

    test "a failed gh write is recorded gh_failed, redacted, and not retried", ctx do
      secret = "ghp_SECRETVALUE1234567"
      FakeGh.fail_write(ctx.gh, "HTTP 403: token #{secret} rejected")
      opts = Keyword.put(ctx.opts, :secrets_fun, fn _project -> {:ok, [secret]} end)

      assert {:refused, :gh_failed, detail} = Publisher.publish(ctx.trigger, opts)
      assert detail =~ "gh failed"
      refute detail =~ secret

      assert [{:create, nil, _}] = FakeGh.writes(ctx.gh)

      assert [%{status: "refused", reason: "gh_failed", detail: stored}] =
               report_events(ctx.run_id)

      refute stored =~ secret
      assert String.length(stored) <= 500

      assert {:ok, %{status: :failed}} = KeyStore.get(key_of(ctx.trigger))

      # nothing is retried automatically for that head and digest
      assert {:skipped, :already_reported} = Publisher.publish(ctx.trigger, opts)
      assert [{:create, _, _}] = FakeGh.writes(ctx.gh)
    end

    test "a failed edit is gh_failed too and leaves the earlier comment as it was", ctx do
      assert {:published, _} = Publisher.publish(ctx.trigger, ctx.opts)
      trigger2 = move_head!(ctx, "sha-2")
      before = FakeGh.comments(ctx.gh)
      FakeGh.fail_write(ctx.gh, "HTTP 500")

      assert {:refused, :gh_failed, _detail} = Publisher.publish(trigger2, ctx.opts)
      assert FakeGh.comments(ctx.gh) == before
      assert %{head_sha: "sha-2", status: "refused", reason: "gh_failed"} = report(ctx.run_id)
    end

    test "a key recovery could not resolve refuses the effect: recorded effect_refused", ctx do
      key = key_of(ctx.trigger)
      meta = CommentEffect.intent(ctx.run_id, ctx.pr_url, "sha-1", ctx.trigger.digest)

      :ok =
        KeyStore.mark_started(key, Map.merge(%{"effect_class" => "pr_comment"}, stringify(meta)))

      :ok = KeyStore.mark_unresolved(key, 1_000_000, "recovery could not tell")

      assert {:refused, :effect_refused, detail} = Publisher.publish(ctx.trigger, ctx.opts)
      assert detail =~ "effect_unresolved"
      assert [] = FakeGh.writes(ctx.gh)
      assert [] = FakeGh.comments(ctx.gh)
      assert [%{status: "refused", reason: "effect_refused"}] = report_events(ctx.run_id)
    end

    test "a record that cannot be rendered is recorded effect_refused", ctx do
      assert {:refused, :effect_refused, detail} =
               Publisher.publish(Map.put(ctx.trigger, :level, "BOGUS"), ctx.opts)

      assert detail =~ "invalid_record"
      assert [] = FakeGh.writes(ctx.gh)
      assert [%{reason: "effect_refused"}] = report_events(ctx.run_id)
    end

    test "each refused attempt is its own event; the gate and the run are unaffected", ctx do
      eligibility = fn ->
        ctx.run_id
        |> record()
        |> PrEvidence.evaluate(%{
          head_sha: "sha-1",
          policy: %{required: @required, version: PrEvidence.policy_version(@required)},
          now_ms: 10,
          checks_ref: nil
        })
        |> Map.take([:status, :reasons, :waived, :inputs])
      end

      before = eligibility.()
      types_before = Support.run_event_types(ctx.run_id)
      FakeGh.fail_write(ctx.gh, "HTTP 500")

      assert {:refused, :gh_failed, _} = Publisher.publish(ctx.trigger, ctx.opts)
      assert eligibility.() == before

      # the operator's retry (TRD-030) is a new attempt with another `recorded_at`
      assert {:refused, :gh_failed, _} =
               Publisher.post(ctx.trigger, [{:now_fun, fn -> 1 end} | ctx.opts])

      assert {:refused, :gh_failed, _} =
               Publisher.post(ctx.trigger, [{:now_fun, fn -> 2 end} | ctx.opts])

      assert [_, %{recorded_at: 1}, %{recorded_at: 2}] = report_events(ctx.run_id)

      added = Support.run_event_types(ctx.run_id) -- types_before
      assert Enum.uniq(added) == ["PrCommentPublished"]
      assert eligibility.() == before
    end
  end

  describe "head round trips, hidden comments and raises" do
    test "a push back to an already reported head records that report again", ctx do
      assert {:published, %{comment_id: id}} = Publisher.publish(ctx.trigger, ctx.opts)
      trigger2 = move_head!(ctx, "sha-2")
      assert {:published, %{action: :edited}} = Publisher.publish(trigger2, ctx.opts)
      assert %{head_sha: "sha-2"} = report(ctx.run_id)

      # H1 again: the same risk digest, so the same report body; the outcome must not be
      # deduplicated against the first H1 outcome
      trigger3 = move_head!(ctx, "sha-1")
      assert trigger3.digest == ctx.trigger.digest

      assert {:published, %{comment_id: ^id}} = Publisher.publish(trigger3, ctx.opts)

      assert [%{head_sha: "sha-1"}, %{head_sha: "sha-2"}, %{head_sha: "sha-1"}] =
               report_events(ctx.run_id)

      assert %{head_sha: "sha-1", status: "published", comment_id: ^id} = report(ctx.run_id)
      assert [_one] = FakeGh.comments(ctx.gh)
    end

    test "a hidden own comment of the same head and digest is adopted, not reposted", ctx do
      FakeGh.seed(
        ctx.gh,
        PrReport.marker(ctx.run_id, "sha-1", ctx.trigger.digest) <> "\n\nhidden",
        true,
        true
      )

      assert {:published, %{action: :adopted, comment_id: 1}} =
               Publisher.publish(ctx.trigger, ctx.opts)

      assert [] = FakeGh.writes(ctx.gh)
    end

    test "a new head never edits a hidden comment: a visible one is edited, else one is created",
         ctx do
      visible = PrReport.marker(ctx.run_id, "sha-0", "d0") <> "\n\nvisible"
      hidden = PrReport.marker(ctx.run_id, "sha-00", "d00") <> "\n\nhidden"
      FakeGh.seed(ctx.gh, visible)
      FakeGh.seed(ctx.gh, hidden, true, true)

      assert {:published, %{action: :edited, comment_id: 1, superseded: "sha-0"}} =
               Publisher.publish(ctx.trigger, ctx.opts)

      assert [{:update, 1, _}] = FakeGh.writes(ctx.gh)
    end

    test "when every own comment is hidden a new one is created", ctx do
      FakeGh.seed(ctx.gh, PrReport.marker(ctx.run_id, "sha-0", "d0") <> "\n\nhidden", true, true)

      assert {:published, %{action: :created, comment_id: 2, superseded: nil}} =
               Publisher.publish(ctx.trigger, ctx.opts)

      assert [{:create, nil, _}] = FakeGh.writes(ctx.gh)
    end

    test "a raise in the publication is a typed refusal that names no message", ctx do
      opts =
        Keyword.put(ctx.opts, :secrets_fun, fn _project ->
          raise "the store said ghp_SECRETVALUE1234567"
        end)

      assert {:refused, :publisher_error, detail} = Publisher.publish(ctx.trigger, opts)
      assert detail =~ "RuntimeError"
      refute detail =~ "ghp_SECRETVALUE1234567"

      assert [] = FakeGh.writes(ctx.gh)

      assert [%{status: "refused", reason: "publisher_error", detail: ^detail}] =
               report_events(ctx.run_id)

      assert {:skipped, :already_reported} = Publisher.publish(ctx.trigger, opts)
    end

    test "a throw in the publication is a typed refusal too", ctx do
      opts = Keyword.put(ctx.opts, :secrets_fun, fn _project -> throw(:nope) end)

      assert {:refused, :publisher_error, "the publication throw"} =
               Publisher.publish(ctx.trigger, opts)
    end

    test "a refused head stays refused on redelivery; a new digest is attempted", ctx do
      FakeGh.fail_write(ctx.gh, "HTTP 500")
      assert {:refused, :gh_failed, _} = Publisher.publish(ctx.trigger, ctx.opts)
      assert {:skipped, :already_reported} = Publisher.publish(ctx.trigger, ctx.opts)

      FakeGh.fail_write(ctx.gh, nil)
      trigger2 = move_head!(ctx, "sha-2")

      assert {:published, %{action: :created}} = Publisher.publish(trigger2, ctx.opts)

      assert [%{status: "refused"}, %{status: "published", head_sha: "sha-2"}] =
               report_events(ctx.run_id)
    end

    test "a reconciled done key with the comment on the PR writes nothing", ctx do
      FakeGh.seed(
        ctx.gh,
        PrReport.marker(ctx.run_id, "sha-1", ctx.trigger.digest) <> "\n\nreport"
      )

      key = key_of(ctx.trigger)
      meta = CommentEffect.intent(ctx.run_id, ctx.pr_url, "sha-1", ctx.trigger.digest)

      :ok =
        KeyStore.mark_started(key, Map.merge(%{"effect_class" => "pr_comment"}, stringify(meta)))

      :ok = KeyStore.mark_completed(key)

      assert {:published, %{action: :adopted, comment_id: 1, superseded: nil}} =
               Publisher.publish(ctx.trigger, ctx.opts)

      assert [] = FakeGh.writes(ctx.gh)
      assert [%{comment_id: 1, superseded: nil}] = report_events(ctx.run_id)
    end
  end

  describe "the subscriber" do
    defp start_publisher(ctx, extra \\ []) do
      start_supervised!({Publisher, Keyword.merge(ctx.opts, extra)})
    end

    defp deliver(pid, trigger),
      do: send(pid, {:projection_event, %{event_type: "PrRiskRecorded", data: trigger}})

    test "a burst for one PR publishes once and the waiting slot keeps only the newest trigger",
         ctx do
      test_pid = self()
      base = ctx.runner

      # the list is read BEFORE the task parks, so a second concurrent task would see an empty
      # PR and create again
      blocking = fn "gh", args, opts ->
        result = base.("gh", args, opts)

        if match?(["pr", "view" | _], args) do
          send(test_pid, {:listed, self()})

          receive do
            :go -> :ok
          after
            5_000 -> :ok
          end
        end

        result
      end

      pid = start_publisher(ctx, command_runner: blocking)

      deliver(pid, ctx.trigger)
      assert_receive {:listed, first}, 2_000
      older = %{ctx.trigger | digest: "older"}
      newest = %{ctx.trigger | digest: "newest"}
      deliver(pid, older)
      deliver(pid, newest)
      assert Publisher.inflight(pid) == 1

      Eventually.await(fn -> :sys.get_state(pid).pending |> map_size() == 1 end)
      assert [^newest] = Map.values(:sys.get_state(pid).pending)

      send(first, :go)
      Eventually.await(fn -> Publisher.inflight(pid) == 0 end, message: "publisher idle")

      assert [{:create, nil, _}] = FakeGh.writes(ctx.gh)
      assert [_one] = FakeGh.comments(ctx.gh)
      assert [%{status: "published", digest: digest}] = report_events(ctx.run_id)
      assert digest == ctx.trigger.digest
    end

    test "a task killed after the create and before the outcome is recorded posts nothing twice",
         ctx do
      test_pid = self()
      base = ctx.runner

      stuck = fn "gh", args, opts ->
        result = base.("gh", args, opts)

        if match?(["api", "repos/" <> _, "-f" | _], args) do
          send(test_pid, :created)
          Process.sleep(:infinity)
        end

        result
      end

      {:ok, pid} = GenServer.start(Publisher, Keyword.put(ctx.opts, :command_runner, stuck))
      deliver(pid, ctx.trigger)
      assert_receive :created, 2_000
      Process.exit(pid, :kill)

      assert [{:create, _, _}] = FakeGh.writes(ctx.gh)
      assert [] = report_events(ctx.run_id)

      # the next publication finds its own comment by the marker
      assert {:published, %{action: :adopted, comment_id: 1}} =
               Publisher.publish(ctx.trigger, ctx.opts)

      assert [{:create, _, _}] = FakeGh.writes(ctx.gh)
      assert [%{status: "published", comment_id: 1}] = report_events(ctx.run_id)
    end

    test "only PrRiskRecorded triggers it", ctx do
      pid = start_publisher(ctx)

      for type <- ~w(PrChecksChanged PrReviewChanged PrCommentPublished PrReady PrUpdated) do
        send(pid, {:projection_event, %{event_type: type, data: ctx.trigger}})
      end

      send(pid, {:projection_event, %{event_type: "PrRiskRecorded", data: %{}}})
      send(pid, :noise)

      assert Publisher.inflight(pid) == 0
      assert [] = FakeGh.writes(ctx.gh)
      assert [] = report_events(ctx.run_id)
    end

    test "a publication that raises is recorded as publisher_error and the publisher survives",
         ctx do
      pid =
        start_publisher(ctx,
          secrets_fun: fn _project -> raise "the secret store is gone" end
        )

      deliver(pid, ctx.trigger)

      Eventually.await(fn -> match?([_], report_events(ctx.run_id)) end,
        message: "a refused outcome is recorded"
      )

      assert Process.alive?(pid)
      assert [%{status: "refused", reason: "publisher_error"}] = report_events(ctx.run_id)
      assert [] = FakeGh.writes(ctx.gh)
    end
  end

  describe "through the production path" do
    # A poll, a webhook or the watcher's own subscription observes the PR; the Observer appends
    # `run.pr.risk` and the publisher, subscribed to the projection, reacts to PrRiskRecorded.
    test "an observation records the risk; the publisher posts it, then edits it on a new head",
         ctx do
      publisher = start_publisher(ctx)
      assert Process.alive?(publisher)

      # a head the first observation (in setup) did not see: its risk event is delivered live
      trigger2 = move_head!(ctx, "sha-2")

      Eventually.await(
        fn -> match?([_ | _], report_events(ctx.run_id)) end,
        message: "the publisher records an outcome for the observed head"
      )

      assert [%{head_sha: "sha-2", status: "published", comment_id: id, superseded: nil}] =
               report_events(ctx.run_id)

      assert [%{body: body}] = FakeGh.comments(ctx.gh)
      assert {:ok, %{head_sha: "sha-2", digest: digest}} = marker_of(body)
      assert digest == trigger2.digest

      # the PR moves again: the same comment is edited
      trigger3 = move_head!(ctx, "sha-3")

      Eventually.await(
        fn -> length(report_events(ctx.run_id)) == 2 end,
        message: "the publisher supersedes the report"
      )

      assert [_, %{head_sha: "sha-3", status: "published", comment_id: ^id, superseded: "sha-2"}] =
               report_events(ctx.run_id)

      assert [{:create, nil, _}, {:update, ^id, _}] = FakeGh.writes(ctx.gh)
      assert [%{body: body3}] = FakeGh.comments(ctx.gh)
      assert {:ok, %{head_sha: "sha-3", digest: digest3}} = marker_of(body3)
      assert digest3 == trigger3.digest
      assert %{head_sha: "sha-3", comment_id: ^id} = report(ctx.run_id)
    end

    test "a project with the gate off gets no comment from the same path", ctx do
      ungated = register_project!(%{})
      other = Support.start_run!(project_id: ungated, complete: true)
      {:ok, _} = PrAssociate.store(other.run_id, other.pr_url)
      publisher = start_publisher(ctx)

      {:ok, _} = PrWatcher.refresh_now(other.pr_url)
      assert [_ | _] = risk_events(other.run_id)

      Eventually.await(fn -> Publisher.inflight(publisher) == 0 end)
      assert [] = FakeGh.writes(ctx.gh)
      assert [] = report_events(other.run_id)
    end
  end

  defp risk_events(run_id),
    do: Enum.filter(Support.run_events(run_id), &(&1.event_type == "PrRiskRecorded"))

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
