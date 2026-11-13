defmodule ForemanServer.Workflow.RunExecutorFindingsTest do
  # TRD-034: a finalising run records the review findings of its completion artifact for the PR
  # it just associated, against the local tip taken before the push. These tests reach
  # `run.pr.findings` through the real finalisation path (`finalize_repo_prs`), with real git,
  # the real event store and aggregate, and the hermetic `gh` fake of `PrReadyGithub`. The PR is
  # the run's phase PR so no push is needed.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.TestSupport.PrReadyGithub
  alias ForemanServer.Workflow.MergeGate
  alias ForemanServer.Workflow.RunExecutor

  @pr_url "https://github.com/acme/repo/pull/42"
  @start "<!-- FOREMAN_REVIEW_FINDINGS_START -->"
  @end_ "<!-- FOREMAN_REVIEW_FINDINGS_END -->"

  setup do
    MergeGate.clear()

    repo = Path.join(System.tmp_dir!(), "findings-#{System.unique_integer([:positive])}")
    File.rm_rf!(repo)
    File.mkdir_p!(repo)
    git!(repo, ["init", "--initial-branch=main", "--quiet"])
    git!(repo, ["config", "user.email", "t@x"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "seed")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-m", "seed", "--quiet"])
    git!(repo, ["checkout", "--quiet", "-b", "foreman/run-branch"])
    File.write!(Path.join(repo, "work.txt"), "work")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-m", "work", "--quiet"])
    local_tip = git!(repo, ["rev-parse", "foreman/run-branch"])
    git!(repo, ["checkout", "--quiet", "main"])

    PrReadyGithub.install!(%{@pr_url => PrReadyGithub.sha("github head")})

    run_id = "run-findings-#{System.unique_integer([:positive])}"
    started = %{run_id: run_id, project_id: "project-findings"}

    :ok =
      ForemanServer.EventStore.append_to_stream("run:#{run_id}", 0, [
        %EventStore.EventData{event_type: "RunStarted", data: started, metadata: %{}}
      ])

    :ok =
      ForemanServer.ProjectionStore.apply_events([%{event_type: "RunStarted", payload: started}])

    record_phase_pr!(run_id)

    on_exit(fn -> File.rm_rf(repo) end)

    %{repo: repo, run_id: run_id, local_tip: local_tip}
  end

  describe "the recorded outcomes" do
    test "one valid block is recorded for the local tip with the findings and the artifact digest",
         ctx do
      contents = "# Review\n" <> block(doc([finding()]))
      artifact = artifact!(ctx, contents)

      assert [{_, {:ok, @pr_url}}] = finalize(ctx, artifact)

      assert [rec] = recorded(ctx.run_id)
      assert rec["pr_url"] == @pr_url
      # The reviewed head is the run branch's local tip, never the head GitHub names.
      assert rec["head_sha"] == ctx.local_tip
      refute rec["head_sha"] == PrReadyGithub.sha("github head")
      assert rec["status"] == "recorded"
      assert [%{"severity" => "major", "path" => "lib/foo.ex", "line" => 12}] = rec["findings"]

      assert rec["artifact_sha256"] ==
               :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

      assert rec["artifact_path"] == artifact
      assert is_binary(rec["digest"])

      # The aggregate's fold and the projection hold the same record.
      assert [%{pr_url: @pr_url, evidence: %{findings: findings}}] =
               ForemanServer.ProjectionStore.pr_watch(ctx.run_id)

      assert findings.head_sha == ctx.local_tip
      assert findings.digest == rec["digest"]
      assert MergeGate.pending_for_key?("run:#{ctx.run_id}")
    end

    test "a failed ready signal does not stop the findings, and is still loud", ctx do
      PrReadyGithub.install!(fn _url -> {:error, 13} end)
      artifact = artifact!(ctx, block(doc([finding()])))

      log = capture_log([level: :error], fn -> finalize(ctx, artifact) end)

      assert log =~ "run.pr.ready was NOT signalled"
      refute Enum.any?(events(ctx.run_id), &(&1.event_type == "PrReady"))
      assert [%{"status" => "recorded", "head_sha" => head}] = recorded(ctx.run_id)
      assert head == ctx.local_tip
    end

    test "an artifact with no block records absent, never a clean record", ctx do
      artifact = artifact!(ctx, "# Review\nlooks fine\n")
      finalize(ctx, artifact)

      assert [%{"status" => "absent", "findings" => []}] = recorded(ctx.run_id)
    end

    for {name, contents, defect} <- [
          {"two blocks", "dup", "multiple_blocks"},
          {"invalid JSON", "bad", "invalid_json"},
          {"an unterminated block", "open", "unterminated_block"},
          {"an unknown schema", "schema", "unknown_schema"}
        ] do
      test "#{name} records malformed with the typed defect", ctx do
        body =
          case unquote(contents) do
            "dup" -> block(doc()) <> block(doc())
            "bad" -> block("{not json")
            "open" -> "#{@start}\n" <> Jason.encode!(doc())
            "schema" -> block(doc([], %{"schema" => "foreman.review_findings/2"}))
          end

        finalize(ctx, artifact!(ctx, body))

        assert [%{"status" => "malformed", "defect" => defect, "findings" => []}] =
                 recorded(ctx.run_id)

        assert defect == unquote(defect)
      end
    end

    test "a path that cannot be read records malformed unreadable", ctx do
      missing = Path.join(ctx.repo, "never-written.md")
      finalize(ctx, missing)

      assert [%{"status" => "malformed", "defect" => "unreadable"}] = recorded(ctx.run_id)
    end
  end

  describe "failures and repeats" do
    test "a local tip that cannot be resolved appends nothing and is logged at error level",
         ctx do
      artifact = artifact!(ctx, block(doc()))
      st = state(ctx, artifact) |> put_in([:last_worktree, :branch], "no/such/branch")

      log =
        capture_log([level: :error], fn ->
          assert [{_, {:ok, @pr_url}}] = RunExecutor.__finalize_repo_prs_for_test__(st)
        end)

      assert log =~ "findings of PR #{@pr_url} NOT recorded"
      assert recorded(ctx.run_id) == []
    end

    test "a refused dispatch is logged at error level and finalise still completes", ctx do
      artifact = artifact!(ctx, block(doc()))
      # The aggregate refuses a payload that names another project than the run's.
      st = put_in(state(ctx, artifact), [:task, :project_id], "another-project")

      log =
        capture_log([level: :error], fn ->
          assert [{_, {:ok, @pr_url}}] = RunExecutor.__finalize_repo_prs_for_test__(st)
        end)

      assert log =~ "run.pr.findings"
      assert log =~ "findings of PR #{@pr_url} NOT recorded"
      assert recorded(ctx.run_id) == []
    end

    test "finalising twice appends exactly one record", ctx do
      artifact = artifact!(ctx, block(doc()))
      st = state(ctx, artifact)

      RunExecutor.__finalize_repo_prs_for_test__(st)
      Process.sleep(2)
      RunExecutor.__finalize_repo_prs_for_test__(st)

      assert [_one] = recorded(ctx.run_id)
    end

    test "a run reset and finalised again appends a new record while the old event stays", ctx do
      artifact = artifact!(ctx, block(doc()))
      st = state(ctx, artifact)
      RunExecutor.__finalize_repo_prs_for_test__(st)
      assert [first] = recorded(ctx.run_id)

      # The run is blocked, then reset: the aggregate returns to its initial state (the stream
      # keeps the old event), so the same head and digest must be recorded again.
      for {type, id} <- [{"run.block", "block"}, {"run.reset", "reset"}] do
        {:ok, _} =
          ForemanServer.CommandGateway.dispatch_system(%{
            type: type,
            command_id: "#{id}-#{ctx.run_id}",
            aggregate_id: "run:#{ctx.run_id}",
            payload: %{"run_id" => ctx.run_id}
          })
      end

      # The reset run starts again (a new attempt re-creates it in the aggregate), runs its
      # phases and has its phase PR on record again.
      :ok = ForemanServer.TestSupport.EffectWorld.register_project!("project-findings", ctx.repo)

      {:ok, _} =
        ForemanServer.CommandRouter.dispatch_run_start("project-findings", %{
          run_id: ctx.run_id,
          task_id: "task-findings",
          workflow_snapshot: %{phases: [], attempt: 2}
        })

      record_phase_pr!(ctx.run_id)
      Process.sleep(2)
      RunExecutor.__finalize_repo_prs_for_test__(st)

      assert [^first, second] = recorded(ctx.run_id)
      assert second["head_sha"] == first["head_sha"]
      assert second["digest"] == first["digest"]
      assert second["recorded_at"] > first["recorded_at"]

      assert [%{evidence: %{findings: %{head_sha: head}}}] =
               ForemanServer.ProjectionStore.pr_watch(ctx.run_id)

      assert head == ctx.local_tip
    end

    test "a new head with the same findings is recorded again", ctx do
      artifact = artifact!(ctx, block(doc()))
      st = state(ctx, artifact)
      RunExecutor.__finalize_repo_prs_for_test__(st)

      git!(ctx.repo, ["checkout", "--quiet", "foreman/run-branch"])
      File.write!(Path.join(ctx.repo, "more.txt"), "more")
      git!(ctx.repo, ["add", "."])
      git!(ctx.repo, ["commit", "--no-gpg-sign", "-m", "more", "--quiet"])
      git!(ctx.repo, ["checkout", "--quiet", "main"])
      Process.sleep(2)
      RunExecutor.__finalize_repo_prs_for_test__(st)

      assert [a, b] = recorded(ctx.run_id)
      refute a["head_sha"] == b["head_sha"]
    end
  end

  defp record_phase_pr!(run_id) do
    :ok =
      ForemanServer.ProjectionStore.apply_events([
        %{
          event_type: "PhasePrRecorded",
          payload: %{
            run_id: run_id,
            phase_id: "#{run_id}-p001",
            phase_index: 1,
            phase_name: "review",
            status: "existing",
            pr_url: @pr_url,
            pr_number: 42,
            base_branch: "main",
            head_branch: "foreman/run-branch",
            provider: "github",
            recorded_at: "2026-01-01T00:00:01Z"
          }
        }
      ])
  end

  defp finalize(ctx, artifact),
    do: RunExecutor.__finalize_repo_prs_for_test__(state(ctx, artifact))

  defp state(ctx, artifact) do
    %{
      run_id: ctx.run_id,
      task: %{task_id: "task-findings", project_id: "project-findings"},
      plan_context: %{"project_root" => ctx.repo},
      run_base_branch: {:ok, "main"},
      last_worktree: %{branch: "foreman/run-branch"},
      current_phase: 0,
      phase_specs: [%{artifact_template: artifact}]
    }
  end

  defp artifact!(ctx, contents) do
    path = Path.join(ctx.repo, "artifact-#{System.unique_integer([:positive])}.md")
    File.write!(path, contents)
    path
  end

  defp events(run_id) do
    {:ok, events} = ForemanServer.EventStore.read_stream_forward("run:#{run_id}", 0, 1_000)
    events
  end

  defp recorded(run_id) do
    for e <- events(run_id), e.event_type == "ReviewFindingsRecorded" do
      e.data |> Jason.encode!() |> Jason.decode!()
    end
  end

  defp finding do
    %{
      "severity" => "major",
      "path" => "lib/foo.ex",
      "line" => 12,
      "description" => "unchecked nil",
      "disposition" => "open",
      "source" => "repo-rules"
    }
  end

  defp doc(findings \\ [finding()], overrides \\ %{}) do
    Map.merge(
      %{"schema" => "foreman.review_findings/1", "reviewed" => true, "findings" => findings},
      overrides
    )
  end

  defp block(json) when is_map(json), do: block(Jason.encode!(json))
  defp block(text), do: "#{@start}\n#{text}\n#{@end_}\n"

  defp git!(root, args) do
    {out, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    String.trim(out)
  end
end
