defmodule ForemanServer.PrObservationTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{PrObservation, ProjectionStore}
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support

  defp types(commands), do: Enum.map(commands, & &1.type)

  # Dispatch what the observer produced and return the stored watch record.
  defp apply!(commands, run_id, pr_url) do
    Enum.each(commands, &Support.dispatch!/1)
    Enum.find(ProjectionStore.pr_watch(run_id), &(&1.pr_url == pr_url))
  end

  setup do
    run = Support.start_run!(complete: true)
    {:ok, run}
  end

  describe "digests" do
    test "checks digest ignores check order and comment churn, but not the head sha" do
      a =
        Support.status(
          checks: [Support.failing_check("a"), Support.failing_check("b")],
          checks_state: :failing
        )

      b = %{
        a
        | checks: Enum.reverse(a.checks),
          comments: [%{id: "IC_1", author: "x", body: "hi", url: nil, created_at: nil}]
      }

      assert PrObservation.checks_digest(a) == PrObservation.checks_digest(b)

      refute PrObservation.checks_digest(a) ==
               PrObservation.checks_digest(%{a | head_sha: "sha-2"})
    end

    test "review digest ignores comment bodies and check state, but sees a new comment id" do
      c = fn id, body -> %{id: id, author: "x", body: body, url: nil, created_at: nil} end
      a = Support.status(comments: [c.("IC_1", "one")])

      assert PrObservation.review_digest(a) ==
               PrObservation.review_digest(%{
                 a
                 | comments: [c.("IC_1", "edited")],
                   checks_state: :failing
               })

      refute PrObservation.review_digest(a) ==
               PrObservation.review_digest(%{
                 a
                 | comments: [c.("IC_1", "one"), c.("IC_2", "two")]
               })
    end

    test "unresolved thread ids drive the review digest; resolved ones do not" do
      thread = fn id, resolved ->
        %{id: id, resolved: resolved, outdated: false, path: "a.ex", line: 1, comments: []}
      end

      none = Support.status(threads: [thread.("T1", true)])
      one = Support.status(threads: [thread.("T1", true), thread.("T2", false)])

      assert PrObservation.thread_ids(one) == ["T2"]

      assert PrObservation.review_digest(none) ==
               PrObservation.review_digest(Support.status(threads: nil))

      refute PrObservation.review_digest(none) == PrObservation.review_digest(one)
    end

    # foreman-v9y3x: a comment GitHub says a Bot wrote (a review bot's walkthrough) is not
    # feedback to address. A comment whose author type is unknown (`bot: nil`) still counts.
    test "a bot's comment is not counted: not in the ids, not in the review digest" do
      c = fn id, bot ->
        %{id: id, author: "x", bot: bot, body: "hi", url: nil, created_at: nil}
      end

      with_bot = Support.status(comments: [c.("IC_bot", true)])

      assert PrObservation.comment_ids(with_bot) == []

      assert PrObservation.review_digest(with_bot) ==
               PrObservation.review_digest(Support.status())

      mixed = Support.status(comments: [c.("IC_b", true), c.("IC_p", false), c.("IC_u", nil)])
      assert PrObservation.comment_ids(mixed) == ["IC_p", "IC_u"]
    end
  end

  # TRD-030: the report comment the publisher posts reaches the watcher as an ordinary comment
  # (the `issue_comment` webhook, a poll). It is Foreman's own words, not feedback.
  describe "the feedback-loop guard (TRD-030)" do
    alias ForemanServer.PrReport

    defp marker_body(extra \\ "report text"),
      do: PrReport.marker("run-1", "sha-1", "d1") <> "\n" <> extra

    defp comment(id, body, viewer_did_author) do
      %{
        id: id,
        author: "x",
        bot: false,
        viewer_did_author: viewer_did_author,
        body: body,
        url: nil,
        created_at: nil
      }
    end

    test "the token's own comment that starts with the marker is not counted, nor does it move the digest" do
      own = Support.status(comments: [comment("IC_own", marker_body(), true)])

      assert PrObservation.comment_ids(own) == []
      assert PrObservation.review_digest(own) == PrObservation.review_digest(Support.status())
    end

    test "a marker comment written by anyone else is counted" do
      foreign = Support.status(comments: [comment("IC_foreign", marker_body(), false)])

      assert PrObservation.comment_ids(foreign) == ["IC_foreign"]
      refute PrObservation.review_digest(foreign) == PrObservation.review_digest(Support.status())
    end

    test "a comment with no author flag at all is counted, even with the marker" do
      bare = %{id: "IC_bare", author: "x", body: marker_body(), url: nil, created_at: nil}

      assert PrObservation.comment_ids(Support.status(comments: [bare])) == ["IC_bare"]
    end

    test "one rule decides what an own report is: the first line must be exactly a marker" do
      lookalikes = [
        "<!-- foreman:pr-report v1 hi",
        PrReport.marker_prefix() <> "run=r head=h digest=d",
        PrReport.marker_prefix() <> "run=r head=h digest=d --> trailing words",
        PrReport.marker_prefix() <> "\nsecond line"
      ]

      for body <- lookalikes do
        assert PrReport.parse_marker(body) == :error, body
        status = Support.status(comments: [comment("IC_human", body, true)])
        assert PrObservation.comment_ids(status) == ["IC_human"], body
      end

      assert {:ok, _} = PrReport.parse_marker(marker_body())

      assert PrObservation.comment_ids(
               Support.status(comments: [comment("IC_own", marker_body(), true)])
             ) == []
    end

    test "the token's own comment is counted unless its body STARTS with the marker prefix" do
      quoting = "I agree with:\n" <> marker_body()
      indented = " " <> marker_body()
      plain = "please fix the nil check"

      status =
        Support.status(
          comments: [
            comment("IC_quote", quoting, true),
            comment("IC_space", indented, true),
            comment("IC_plain", plain, true)
          ]
        )

      assert PrObservation.comment_ids(status) == ["IC_plain", "IC_quote", "IC_space"]
    end

    test "own and foreign marker comments side by side: only the foreign one is feedback" do
      status =
        Support.status(
          comments: [
            comment("IC_own", marker_body(), true),
            comment("IC_f", marker_body(), false)
          ]
        )

      assert PrObservation.comment_ids(status) == ["IC_f"]
    end

    test "from a real `gh pr view` payload: only viewerDidAuthor true hides a marker comment" do
      item = fn id, extra ->
        Map.merge(
          %{
            "id" => id,
            "author" => %{"login" => "foreman-bot"},
            "body" => marker_body(),
            "url" => "https://github.com/acme/repo/pull/7#issuecomment-#{id}",
            "createdAt" => "2026-11-13T00:00:00Z"
          },
          extra
        )
      end

      view =
        Jason.encode!(%{
          "state" => "OPEN",
          "mergeable" => "MERGEABLE",
          "headRefOid" => "abc123def456",
          "headRefName" => "b",
          "baseRefName" => "main",
          "comments" => [
            item.("IC_own", %{"viewerDidAuthor" => true}),
            item.("IC_other", %{"viewerDidAuthor" => false}),
            item.("IC_absent", %{})
          ]
        })

      assert {:ok, status} =
               ForemanServer.GitHub.PrStatus.fetch("https://github.com/acme/repo/pull/7",
                 command_runner: fn "gh", _args, _opts -> {view, 0} end
               )

      assert PrObservation.comment_ids(status) == ["IC_absent", "IC_other"]
    end

    test "observing the publisher's own comment emits no run.pr.review; a foreign one does",
         ctx do
      status = Support.status()
      {:ok, first} = PrObservation.commands(ctx.run_id, ctx.pr_url, status, nil)
      record = apply!(first, ctx.run_id, ctx.pr_url)

      own = %{status | comments: [comment("IC_own", marker_body(), true)]}
      assert {:ok, []} = PrObservation.commands(ctx.run_id, ctx.pr_url, own, record)

      foreign = %{status | comments: [comment("IC_f", marker_body(), false)]}
      assert {:ok, [review]} = PrObservation.commands(ctx.run_id, ctx.pr_url, foreign, record)
      assert review.type == "run.pr.review"
      assert review.payload.comment_ids == ["IC_f"]
    end
  end

  describe "commands/4" do
    test "a first sighting of a PR with nothing to report is just the run.pr.update", %{
      run_id: run_id,
      pr_url: pr_url
    } do
      assert {:ok, commands} = PrObservation.commands(run_id, pr_url, Support.status(), nil)
      assert types(commands) == ["run.pr.update", "run.pr.risk"]
    end

    test "a first sighting whose only comment is a bot's is just the run.pr.update", %{
      run_id: run_id,
      pr_url: pr_url
    } do
      walkthrough = %{
        id: "IC_1",
        author: "coderabbitai",
        bot: true,
        body: "w",
        url: nil,
        created_at: nil
      }

      status = Support.status(comments: [walkthrough])

      assert {:ok, commands} = PrObservation.commands(run_id, pr_url, status, nil)
      assert types(commands) == ["run.pr.update", "run.pr.risk"]
    end

    test "failing checks add run.pr.checks; repeating the identical observation emits nothing",
         ctx do
      status = Support.status(checks: [Support.failing_check("unit")], checks_state: :failing)

      assert {:ok, commands} = PrObservation.commands(ctx.run_id, ctx.pr_url, status, nil)
      assert types(commands) == ["run.pr.update", "run.pr.checks", "run.pr.risk"]
      record = apply!(commands, ctx.run_id, ctx.pr_url)

      assert record.checks_state == "failing"
      assert record.failing == ["unit"]
      assert {:ok, []} = PrObservation.commands(ctx.run_id, ctx.pr_url, status, record)
    end

    test "a new comment changes only the review command, never the checks command", ctx do
      status = Support.status(checks: [Support.failing_check("unit")], checks_state: :failing)
      {:ok, first} = PrObservation.commands(ctx.run_id, ctx.pr_url, status, nil)
      record = apply!(first, ctx.run_id, ctx.pr_url)

      commented = %{
        status
        | comments: [%{id: "IC_9", author: "r", body: "fix this", url: nil, created_at: nil}]
      }

      assert {:ok, [review]} = PrObservation.commands(ctx.run_id, ctx.pr_url, commented, record)
      assert review.type == "run.pr.review"
      assert review.payload.comment_ids == ["IC_9"]
      assert review.payload.new_comment_count == 1
    end

    test "a new head sha changes both the update and the checks command", ctx do
      status = Support.status(checks: [Support.failing_check("unit")], checks_state: :failing)
      {:ok, first} = PrObservation.commands(ctx.run_id, ctx.pr_url, status, nil)
      record = apply!(first, ctx.run_id, ctx.pr_url)

      pushed = %{status | head_sha: "sha-2"}
      assert {:ok, commands} = PrObservation.commands(ctx.run_id, ctx.pr_url, pushed, record)
      assert types(commands) == ["run.pr.update", "run.pr.checks", "run.pr.risk"]
    end

    test "fail -> pass -> fail on the SAME sha yields three distinct events (observation_seq)",
         ctx do
      failing = Support.status(checks: [Support.failing_check("unit")], checks_state: :failing)

      passing =
        Support.status(
          checks: [%{Support.failing_check("unit") | state: :passing, conclusion: "SUCCESS"}],
          checks_state: :passing
        )

      r1 = step(ctx, failing, nil)
      r2 = step(ctx, passing, r1)
      r3 = step(ctx, failing, r2)

      assert [r1.checks_seq, r2.checks_seq, r3.checks_seq] == [1, 2, 3]
      assert r1.checks_digest == r3.checks_digest

      events = Support.run_events(ctx.run_id)
      assert Enum.count(events, &(&1.event_type == "PrChecksChanged")) == 3
    end

    # foreman-i97tz (S4.md, thread-state transition identity): the spike keyed thread signals
    # `thr:<id>:open|resolved`, which would collapse a repeated open -> resolved -> reopened cycle of
    # ONE thread onto its first `open`. The built scheme keys the review event by digest AND a
    # monotonic observation_seq, so the third observation (same digest as the first) still appends.
    test "an unresolved -> resolved -> unresolved thread cycle yields three distinct review events",
         ctx do
      thread = fn resolved ->
        %{id: "PRRT_1", resolved: resolved, outdated: false, path: "a.ex", line: 1, comments: []}
      end

      open = Support.status(threads: [thread.(false)])
      resolved = Support.status(threads: [thread.(true)])

      r1 = step(ctx, open, nil)
      r2 = step(ctx, resolved, r1)
      r3 = step(ctx, open, r2)

      assert [r1.review_seq, r2.review_seq, r3.review_seq] == [1, 2, 3]
      assert r1.review_digest == r3.review_digest
      assert [r1.thread_ids, r2.thread_ids, r3.thread_ids] == [["PRRT_1"], [], ["PRRT_1"]]

      assert Enum.count(Support.run_events(ctx.run_id), &(&1.event_type == "PrReviewChanged")) ==
               3
    end

    test "the command id is deterministic: two observers reading the same previous collapse to one event",
         ctx do
      status = Support.status(checks: [Support.failing_check("unit")], checks_state: :failing)
      {:ok, [_u1, c1, _r1]} = PrObservation.commands(ctx.run_id, ctx.pr_url, status, nil)
      {:ok, [_u2, c2, _r2]} = PrObservation.commands(ctx.run_id, ctx.pr_url, status, nil)

      assert c1.command_id == c2.command_id
      Support.dispatch!(c1)
      Support.dispatch!(c2)

      assert Enum.count(Support.run_events(ctx.run_id), &(&1.event_type == "PrChecksChanged")) ==
               1
    end

    test "an unknown run is a typed error", %{pr_url: pr_url} do
      assert {:error, {:run_not_found, "run-nope"}} =
               PrObservation.commands("run-nope", pr_url, Support.status(), nil)
    end
  end

  defp passing_check(name),
    do: %{Support.failing_check(name) | state: :passing, conclusion: "SUCCESS"}

  # The stored record an observer reads back: the notification digest and the evidence digest
  # of `status`, as the folds record them.
  defp recorded(status) do
    %{
      status: "open",
      head_sha: status.head_sha,
      base_branch: status.base_branch,
      checks_digest: PrObservation.checks_digest(status),
      checks_seq: 1,
      evidence: %{
        checks: %{evidence_digest: PrObservation.evidence_digest(status)},
        risk: %{
          head_sha: status.head_sha,
          rubric_version: ForemanServer.PrRisk.Rubric.version(),
          findings_digest: nil,
          seq: 1
        }
      }
    }
  end

  describe "evidence digest" do
    setup do
      failing = Support.failing_check("unit")

      {:ok,
       failing: failing,
       base: Support.status(checks: [failing, passing_check("lint")], checks_state: :failing)}
    end

    test "the notification digest ignores passing checks; the evidence digest does not", ctx do
      added = %{ctx.base | checks: [passing_check("docs") | ctx.base.checks]}
      removed = %{ctx.base | checks: [ctx.failing]}

      rerun = %{
        ctx.base
        | checks: [ctx.failing, %{passing_check("lint") | completed_at: "2026-11-12T14:00:00Z"}]
      }

      for other <- [added, removed, rerun] do
        assert PrObservation.checks_digest(other) == PrObservation.checks_digest(ctx.base)
        refute PrObservation.evidence_digest(other) == PrObservation.evidence_digest(ctx.base)
      end
    end

    test "the same checks in another order give equal digests", ctx do
      reversed = %{ctx.base | checks: Enum.reverse(ctx.base.checks)}
      assert PrObservation.evidence_digest(reversed) == PrObservation.evidence_digest(ctx.base)
      assert PrObservation.checks_digest(reversed) == PrObservation.checks_digest(ctx.base)
    end

    test "the head, truncation and policy version are part of the evidence digest", ctx do
      refute PrObservation.evidence_digest(%{ctx.base | head_sha: "sha-2"}) ==
               PrObservation.evidence_digest(ctx.base)

      refute PrObservation.evidence_digest(%{ctx.base | checks_truncated: true}) ==
               PrObservation.evidence_digest(ctx.base)

      refute PrObservation.evidence_digest(ctx.base, "p1") ==
               PrObservation.evidence_digest(ctx.base)
    end

    test "a change of the evidence alone emits one run.pr.checks with the unchanged digest",
         ctx do
      previous = recorded(ctx.base)
      added = %{ctx.base | checks: [passing_check("docs") | ctx.base.checks]}

      assert {:ok, [command, %{type: "run.pr.risk"}]} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, added, previous)

      assert command.type == "run.pr.checks"
      assert command.payload.digest == previous.checks_digest
      assert command.payload.evidence_digest == PrObservation.evidence_digest(added)
      refute command.payload.evidence_digest == previous.evidence.checks.evidence_digest

      assert {:ok, []} = PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.base, previous)
    end

    test "the command carries every check of the head and is stamped as the observer's", ctx do
      assert {:ok, [_update, command, _risk]} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.base, nil)

      payload = command.payload
      assert payload.source == "watch"
      assert payload.observation_ref == nil
      assert payload.checks_truncated == false
      assert payload.head_sha == ctx.base.head_sha
      assert payload.evidence_digest == PrObservation.evidence_digest(ctx.base)
      assert Enum.map(payload.checks, & &1.name) == ["unit", "lint"]

      assert %{kind: :check_run, state: :failing, completed_at: "2026-11-12T13:58:49Z"} =
               hd(payload.checks)

      refute Enum.any?(payload.checks, &Map.has_key?(&1, :url))
    end

    test "the evidence reaches the stored event and the watch record, and the repeat is quiet",
         ctx do
      record = step(ctx, ctx.base, nil)

      assert %{checks: %{head_sha: "sha-1", evidence_digest: evidence, items: items}} =
               record.evidence

      assert evidence == PrObservation.evidence_digest(ctx.base)
      assert Enum.map(items, & &1["name"]) == ["unit", "lint"]
      assert {:ok, []} = PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.base, record)
    end
  end

  describe "forced observation" do
    setup do
      status =
        Support.status(checks: [Support.failing_check("unit")], checks_state: :failing)

      {:ok, status: status}
    end

    test "an unchanged PR still yields the update and one forced checks command, no review",
         ctx do
      previous = recorded(ctx.status)
      force = %{nonce: "n-1", now_ms: 1_700_000_000_000}

      assert {:ok, [update, checks, %{type: "run.pr.risk"}]} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.status, previous, nil,
                 force: force
               )

      assert update.type == "run.pr.update"
      assert checks.type == "run.pr.checks"

      assert checks.command_id ==
               "pr_checks:#{ctx.run_id}:#{PrObservation.url_hash(ctx.pr_url)}:forced:n-1"

      assert checks.payload.observed_at == 1_700_000_000_000
      assert checks.payload.observation_ref == "n-1"
      assert checks.payload.source == "gate"
      assert checks.payload.digest == previous.checks_digest
      assert checks.payload.observation_seq == 2

      assert {:ok, [_update, other, _risk]} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.status, previous, nil,
                 force: %{force | nonce: "n-2"}
               )

      refute other.command_id == checks.command_id
    end

    test "a forced observation is stored as a gate event with its nonce and observation time",
         ctx do
      record = step(ctx, ctx.status, nil)
      force = %{nonce: "n-3", now_ms: 42}

      {:ok, commands} =
        PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.status, record, nil, force: force)

      record = apply!(commands, ctx.run_id, ctx.pr_url)
      assert record.evidence.checks.observation_ref == "n-3"
      assert record.evidence.checks.observed_at == 42

      forced =
        ctx.run_id
        |> Support.run_events()
        |> Enum.filter(&(&1.event_type == "PrChecksChanged"))

      assert [%{source: "watch"}, %{source: "gate", observation_ref: "n-3"}] =
               Enum.map(forced, & &1.data)
    end
  end

  describe "what may notify" do
    test "only a change of the notification digest maps to the CI-failed notification", ctx do
      failing = Support.status(checks: [Support.failing_check("unit")], checks_state: :failing)

      # The failing set is the same; a slower passing job finished.
      later = %{failing | checks: failing.checks ++ [passing_check("slow")]}

      {:ok, first} = PrObservation.commands(ctx.run_id, ctx.pr_url, failing, nil)
      record = apply!(first, ctx.run_id, ctx.pr_url)

      {:ok, [evidence_only, _risk]} =
        PrObservation.commands(ctx.run_id, ctx.pr_url, later, record)

      Support.dispatch!(evidence_only)

      assert [%{change: "digest"}, %{change: "evidence"}] =
               ctx.run_id
               |> Support.run_events()
               |> Enum.filter(&(&1.event_type == "PrChecksChanged"))
               |> Enum.map(& &1.data)

      rules = ForemanServer.Notifier.Mapping.rules()

      lookups =
        ctx.run_id
        |> Support.run_events()
        |> Enum.filter(&(&1.event_type == "PrChecksChanged"))
        |> Enum.map(fn event ->
          ForemanServer.Notifier.Mapping.lookup(
            rules,
            "PrChecksChanged",
            ForemanServer.Notifier.Rule.normalize_payload!(event.data)
          )
        end)

      assert [{:ok, %{class: :failure}}, :ignore] = lookups
    end
  end

  describe "an observation that spans a head move" do
    test "an unchanged review is re-recorded in the same batch, not a poll later", ctx do
      commented = [%{id: "IC_9", author: "r", body: "fix this", url: nil, created_at: nil}]
      first = Support.status(comments: commented, review_decision: :changes_requested)

      record = step(ctx, first, nil)
      assert record.review_decision == "changes_requested"

      pushed = %{first | head_sha: "sha-2"}
      assert {:ok, commands} = PrObservation.commands(ctx.run_id, ctx.pr_url, pushed, record)
      assert types(commands) == ["run.pr.update", "run.pr.review", "run.pr.risk"]

      record = apply!(commands, ctx.run_id, ctx.pr_url)
      assert record.head_sha == "sha-2"
      assert record.review_decision == "changes_requested"
      assert record.review_seq == 2
      assert {:ok, []} = PrObservation.commands(ctx.run_id, ctx.pr_url, pushed, record)
    end
  end

  describe "malformed force" do
    test "is a typed error, never a case clause", ctx do
      status = Support.status()

      for bad <- [
            :now,
            %{nonce: "n"},
            %{nonce: "", now_ms: 1},
            %{nonce: 7, now_ms: 1},
            %{nonce: "n", now_ms: "1"}
          ] do
        assert {:error, {:invalid_force, ^bad}} =
                 PrObservation.commands(ctx.run_id, ctx.pr_url, status, nil, nil, force: bad)
      end
    end
  end

  describe "bounds, baselines and replay" do
    setup do
      {:ok, base: Support.status(checks: [Support.failing_check("unit")], checks_state: :failing)}
    end

    test "the command keeps the last 100 checks, cuts text at 200 and carries checks_truncated",
         ctx do
      checks =
        for n <- 1..130,
            do: %{passing_check("c#{n}") | name: String.duplicate("n", 300) <> "#{n}"}

      status = %{ctx.base | checks: checks, checks_state: :passing, checks_truncated: true}

      assert {:ok, [_update, command, _risk]} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, status, nil)

      assert command.payload.checks_truncated == true
      assert length(command.payload.checks) == 100
      assert Enum.all?(command.payload.checks, &(String.length(&1.name) == 200))
      assert command.payload.evidence_digest == PrObservation.evidence_digest(status)
    end

    test "a previous whose evidence was recorded for another head does not suppress the event",
         ctx do
      old_head = %{ctx.base | head_sha: "sha-0"}
      previous = recorded(old_head)

      assert {:ok, commands} = PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.base, previous)
      assert types(commands) == ["run.pr.update", "run.pr.checks", "run.pr.risk"]
    end

    test "the first observation after the deploy (no evidence, checks present) is exactly one event",
         ctx do
      previous = ctx.base |> recorded() |> Map.delete(:evidence)

      assert {:ok, [command, %{type: "run.pr.risk"}]} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.base, previous)

      assert command.type == "run.pr.checks"
      assert command.payload.digest == previous.checks_digest
      assert command.payload.change == "evidence"
      assert command.payload.evidence_digest == PrObservation.evidence_digest(ctx.base)
    end

    test "a forced batch holds no review command even when the review changed", ctx do
      commented = [%{id: "IC_9", author: "r", body: "x", url: nil, created_at: nil}]
      changed = %{ctx.base | comments: commented, review_decision: :changes_requested}

      assert {:ok, commands} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, changed, recorded(ctx.base), nil,
                 force: %{nonce: "n-9", now_ms: 5}
               )

      assert types(commands) == ["run.pr.update", "run.pr.checks", "run.pr.risk"]
      refute "run.pr.review" in types(commands)
    end

    test "the aggregate rebuilt from the stored stream (Aggregate.load/2) holds the projection's evidence",
         ctx do
      record = step(ctx, ctx.base, nil)

      {state, _version} =
        ForemanServer.Aggregate.load(ForemanServer.Aggregates.Run, "run:#{ctx.run_id}")

      loaded = state.pr_watch[ctx.pr_url]
      assert loaded.evidence == record.evidence
      assert loaded.checks_state == record.checks_state
      assert loaded.checks_digest == record.checks_digest
    end
  end

  describe "policy snapshot" do
    setup do
      {:ok, base: Support.status(checks: [passing_check("lint")], checks_state: :passing)}
    end

    defp policy(required),
      do: %{required: required, version: ForemanServer.PrEvidence.policy_version(required)}

    @a %{"name" => "lint", "kind" => "check_run"}
    @b %{"name" => "unit", "kind" => "check_run"}

    test "the checks command records required and policy_version; with no policy both are nil",
         ctx do
      assert {:ok, [_update, command, _risk]} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.base, nil, nil,
                 policy: policy([@a])
               )

      assert command.payload.required == [@a]
      assert command.payload.policy_version == policy([@a]).version

      assert command.payload.evidence_digest ==
               PrObservation.evidence_digest(ctx.base, policy([@a]).version)

      assert {:ok, [_update, bare, _risk]} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.base, nil)

      assert bare.payload.required == nil
      assert bare.payload.policy_version == nil
    end

    test "a policy change with no new check emits one run.pr.checks; the repeat is quiet", ctx do
      first = policy([@a])
      second = policy([@a, @b])

      {:ok, commands} =
        PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.base, nil, nil, policy: first)

      record = apply!(commands, ctx.run_id, ctx.pr_url)
      assert record.evidence.checks.policy_version == first.version

      assert {:ok, []} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.base, record, nil,
                 policy: first
               )

      assert {:ok, [command, %{type: "run.pr.risk"}]} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.base, record, nil,
                 policy: second
               )

      assert command.type == "run.pr.checks"
      assert command.payload.required == [@a, @b]
      assert command.payload.policy_version == second.version
      assert command.payload.digest == record.checks_digest

      record = apply!([command], ctx.run_id, ctx.pr_url)
      assert record.evidence.checks.required == [@a, @b]
      assert record.evidence.checks.policy_version == second.version

      assert {:ok, []} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.base, record, nil,
                 policy: second
               )
    end

    test "clearing the policy and an empty policy are changes too", ctx do
      {:ok, commands} =
        PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.base, nil, nil, policy: policy([@a]))

      record = apply!(commands, ctx.run_id, ctx.pr_url)

      assert {:ok, [%{payload: %{required: nil, policy_version: nil}}, %{type: "run.pr.risk"}]} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.base, record)

      assert {:ok, [%{payload: %{required: [], policy_version: version}}, %{type: "run.pr.risk"}]} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.base, record, nil,
                 policy: policy([])
               )

      assert is_binary(version)
    end

    test "a policy with no previous record and no checks emits nothing (no policy to record)",
         ctx do
      empty = %{ctx.base | checks: [], checks_state: :none}
      status_only = Support.status(checks: [], checks_state: :none)
      assert empty.checks == []

      assert {:ok, commands} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, status_only, nil, nil,
                 policy: policy([@a])
               )

      refute "run.pr.checks" in types(commands)
    end

    test "a forced observation carries the policy", ctx do
      assert {:ok, [_update, forced, _risk]} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.base, nil, nil,
                 force: %{nonce: "n-1", now_ms: 5},
                 policy: policy([@a])
               )

      assert forced.payload.required == [@a]
      assert forced.payload.policy_version == policy([@a]).version
      assert forced.payload.source == "gate"
    end
  end

  describe "run.pr.risk in the batch (TRD-018)" do
    alias ForemanServer.PrRisk.Rubric

    setup do
      files = [%{path: "lib/a.ex", additions: 3, deletions: 1}]

      {:ok,
       status:
         Support.status(
           checks: [passing_check("lint")],
           checks_state: :passing,
           files: files,
           changed_files: 1,
           additions: 3,
           deletions: 1
         )}
    end

    defp risk_cmds(commands), do: Enum.filter(commands, &(&1.type == "run.pr.risk"))

    # A stored record whose checks, risk and findings are current for `status`.
    defp current(status, overrides \\ %{}) do
      previous = recorded(status)

      risk = %{
        head_sha: status.head_sha,
        rubric_version: Rubric.version(),
        findings_digest: "f1",
        seq: 4
      }

      evidence =
        previous.evidence
        |> Map.put(:findings, %{head_sha: status.head_sha, digest: "f1"})
        |> Map.put(:risk, Map.merge(risk, overrides))

      %{previous | evidence: evidence}
    end

    test "the command is the facts of the status and the policy; its id carries the head and the next seq",
         ctx do
      policy = policy([@a])

      {:ok, commands} =
        PrObservation.commands(
          ctx.run_id,
          ctx.pr_url,
          ctx.status,
          current(ctx.status, %{head_sha: "sha-0"}),
          nil,
          policy: policy
        )

      assert [risk] = risk_cmds(commands)
      assert List.last(commands) == risk

      assert risk.command_id ==
               "pr_risk:#{ctx.run_id}:#{PrObservation.url_hash(ctx.pr_url)}:sha-1:5"

      assert risk.aggregate_id == "run:#{ctx.run_id}"
      p = risk.payload
      assert p.head_sha == "sha-1" and p.pr_url == ctx.pr_url and p.run_id == ctx.run_id
      assert p.files == ctx.status.files and p.changed_files == 1
      assert p.additions == 3 and p.deletions == 1 and p.base_branch == "main"
      assert p.required == [@a] and p.policy_version == policy.version
      assert p.repo_id == nil and is_integer(p.observed_at)

      for derived <- ~w(level rationale instructions evidence digest judgement)a,
          do: refute(Map.has_key?(p, derived))
    end

    test "a batch with run.pr.update or run.pr.checks ends with run.pr.risk", ctx do
      previous = current(ctx.status)

      moved = %{ctx.status | head_sha: "sha-2"}
      {:ok, commands} = PrObservation.commands(ctx.run_id, ctx.pr_url, moved, previous)
      assert types(commands) == ["run.pr.update", "run.pr.checks", "run.pr.risk"]

      added = %{ctx.status | checks: [passing_check("docs") | ctx.status.checks]}
      {:ok, commands} = PrObservation.commands(ctx.run_id, ctx.pr_url, added, previous)
      assert types(commands) == ["run.pr.checks", "run.pr.risk"]

      rebased = %{ctx.status | base_branch: "develop"}
      {:ok, commands} = PrObservation.commands(ctx.run_id, ctx.pr_url, rebased, previous)
      assert types(commands) == ["run.pr.update", "run.pr.risk"]
    end

    test "a batch with none of them and a current record carries no risk, a review alone included",
         ctx do
      previous = current(ctx.status)
      assert {:ok, []} = PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.status, previous)

      commented = [%{id: "IC_9", author: "r", body: "x", url: nil, created_at: nil}]
      with_comment = %{ctx.status | comments: commented}

      assert {:ok, [%{type: "run.pr.review"}]} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, with_comment, previous)
    end

    test "a stored risk computed from an older findings record ends the batch; a current one does not",
         ctx do
      stale = current(ctx.status)
      stale = put_in(stale.evidence.findings.digest, "f2")

      assert {:ok, [%{type: "run.pr.risk"} = risk]} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.status, stale)

      assert String.ends_with?(risk.command_id, ":sha-1:5")

      assert {:ok, []} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.status, current(ctx.status))

      # findings that appear after a risk made without any
      none = current(ctx.status, %{findings_digest: nil})

      assert {:ok, [%{type: "run.pr.risk"}]} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.status, none)
    end

    test "a missing risk, one for another head or one from another rubric version ends the batch",
         ctx do
      base = current(ctx.status)

      for previous <- [
            put_in(base.evidence.risk, nil),
            put_in(base.evidence, Map.delete(base.evidence, :risk)),
            current(ctx.status, %{head_sha: "sha-0"}),
            current(ctx.status, %{rubric_version: "0"})
          ] do
        assert {:ok, [%{type: "run.pr.risk"}]} =
                 PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.status, previous)
      end
    end

    test "a secondary repository's PR compares no findings digest: it is classified without one",
         ctx do
      previous = current(ctx.status, %{findings_digest: nil})

      assert {:ok, []} =
               PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.status, previous, "repo-b")

      assert {:ok, [%{type: "run.pr.risk", payload: %{repo_id: "repo-b"}}]} =
               PrObservation.commands(
                 ctx.run_id,
                 ctx.pr_url,
                 ctx.status,
                 put_in(previous.evidence.risk.rubric_version, "0"),
                 "repo-b"
               )
    end

    test "the forced batch always ends with it; its checks_ref is the nonce and its time the forced one",
         ctx do
      assert {:ok, commands} =
               PrObservation.commands(
                 ctx.run_id,
                 ctx.pr_url,
                 ctx.status,
                 current(ctx.status),
                 nil,
                 force: %{nonce: "n-7", now_ms: 77}
               )

      assert types(commands) == ["run.pr.update", "run.pr.checks", "run.pr.risk"]
      assert [%{payload: %{checks_ref: "n-7", observed_at: 77}}] = risk_cmds(commands)
    end

    test "an observer's batch has no checks_ref; without a checks command the stored one is used",
         ctx do
      previous = current(ctx.status)
      added = %{ctx.status | checks: [passing_check("docs") | ctx.status.checks]}
      {:ok, commands} = PrObservation.commands(ctx.run_id, ctx.pr_url, added, previous)
      assert [%{payload: %{checks_ref: nil}}] = risk_cmds(commands)

      stored = put_in(previous.evidence.checks[:observation_ref], "n-3")
      stale_risk = put_in(stored.evidence.risk.findings_digest, "old")
      {:ok, commands} = PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.status, stale_risk)
      assert [%{payload: %{checks_ref: "n-3"}}] = risk_cmds(commands)
    end

    test "a batch applied through the gateway records the risk once; the repeat is quiet", ctx do
      record = step(ctx, ctx.status, nil)

      assert %{head_sha: "sha-1", seq: 1, rubric_version: "1", digest: digest} =
               record.evidence.risk

      assert is_binary(digest)
      assert {:ok, []} = PrObservation.commands(ctx.run_id, ctx.pr_url, ctx.status, record)

      assert [%{event_type: "PrRiskRecorded"} = event] =
               ctx.run_id
               |> Support.run_events()
               |> Enum.filter(&(&1.event_type == "PrRiskRecorded"))

      assert event.data.level == "HIGH"
      assert event.data.evidence["files"]["listed"] == 1
    end

    test "a PR with a path the handler cannot hold still dispatches its risk: HIGH, no refusal",
         ctx do
      long = String.duplicate("p", 2000)

      status = %{
        ctx.status
        | files: [%{path: long, additions: 3, deletions: 1}],
          changed_files: 1
      }

      {:ok, commands} = PrObservation.commands(ctx.run_id, ctx.pr_url, status, nil)
      assert [risk] = risk_cmds(commands)
      assert hd(risk.payload.files).path == long

      for command <- commands,
          do: assert({:ok, _} = ForemanServer.CommandGateway.dispatch_system(command))

      assert [event] =
               ctx.run_id
               |> Support.run_events()
               |> Enum.filter(&(&1.event_type == "PrRiskRecorded"))

      assert event.data.level == "HIGH"
      assert event.data.evidence["files"]["listed"] == nil

      record = Enum.find(ProjectionStore.pr_watch(ctx.run_id), &(&1.pr_url == ctx.pr_url))
      assert record.evidence.risk.head_sha == "sha-1"
      assert {:ok, []} = PrObservation.commands(ctx.run_id, ctx.pr_url, status, record)
    end
  end

  defp step(ctx, status, previous) do
    {:ok, commands} = PrObservation.commands(ctx.run_id, ctx.pr_url, status, previous)
    apply!(commands, ctx.run_id, ctx.pr_url)
  end
end
