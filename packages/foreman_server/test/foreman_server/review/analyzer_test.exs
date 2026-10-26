defmodule ForemanServer.Review.AnalyzerTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Aggregates.Review, as: ReviewAggregate
  alias ForemanServer.EventStore
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Review.Analyzer
  alias ForemanServer.Review.Archive
  alias ForemanServer.Review.Capture
  alias ForemanServer.Review.Error
  alias ForemanServer.Review.Gap
  alias ForemanServer.Review.Subject
  alias ForemanServer.Review.Verdict
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup %{tmp_dir: tmp} do
    ProjectionStoreReset.reset!()
    original_review = Application.get_env(:foreman_server, :review, [])
    original_stub = Application.get_env(:foreman_server, :review_stub_verdict)

    Application.put_env(
      :foreman_server,
      :review,
      Keyword.merge(original_review,
        capture: true,
        archive_root: Path.join(tmp, "archive"),
        evaluator: ForemanServer.Review.Evaluator.Stub
      )
    )

    Application.delete_env(:foreman_server, :review_stub_verdict)

    on_exit(fn ->
      Application.put_env(:foreman_server, :review, original_review)

      if original_stub,
        do: Application.put_env(:foreman_server, :review_stub_verdict, original_stub),
        else: Application.delete_env(:foreman_server, :review_stub_verdict)

      ProjectionStoreReset.reset!()
    end)

    {:ok, repo: Path.join(tmp, "repo")}
  end

  defp uid(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp subject(kind, id, repo, overrides \\ []) do
    struct!(
      Subject,
      Keyword.merge(
        [
          kind: kind,
          subject_id: id,
          project_id: "proj",
          repo_path: repo,
          archive_dir: Archive.dir(kind, id, repo),
          status: "completed"
        ],
        overrides
      )
    )
  end

  defp init_archive(%Subject{} = s) do
    :ok =
      Archive.init(s.archive_dir, %{
        "kind" => Atom.to_string(s.kind),
        "subject_id" => s.subject_id,
        "project_id" => s.project_id,
        "repo_path" => s.repo_path,
        "bead_id" => s.bead_id,
        "status" => to_string(s.status),
        "request" => %{
          "source" => Atom.to_string(s.kind),
          "title" => s.request_title,
          "prompt" => s.request_text,
          "workflow_name" => s.workflow_name
        }
      })
  end

  defp put_review(overrides) do
    review = Application.get_env(:foreman_server, :review)
    Application.put_env(:foreman_server, :review, Keyword.merge(review, overrides))
  end

  defp met(summary \\ "Now it is met."),
    do: %Verdict{
      verdict: :met,
      summary: summary,
      scores: %{correctness: 5, tests: 5, documentation: 5, robustness: 5}
    }

  defp await_verdict(kind, id, verdict) do
    await(fn ->
      case ProjectionStore.review(kind, id) do
        %{verdict: ^verdict} = review -> review
        _other -> nil
      end
    end)
  end

  @rate_limited "reviewer run ended failed: execution: pi: 429 rate_limit_error"

  # Records an `undetermined` review for `s` and waits for it to be projected.
  defp record_undetermined!(%Subject{} = s) do
    Application.put_env(
      :foreman_server,
      :review_stub_verdict,
      {:error, Error.new(:evaluator_failed, @rate_limited)}
    )

    init_archive(s)
    assert :ok = Analyzer.analyze(s)

    assert await_verdict(Atom.to_string(s.kind), s.subject_id, "undetermined")
  end

  defp stream(kind, id), do: ReviewAggregate.stream_id(Atom.to_string(kind), id)

  defp recorded_events(kind, id) do
    case EventStore.read_stream_forward(stream(kind, id), 0, 99_999) do
      {:ok, events} -> events
      {:error, :stream_not_found} -> []
    end
  end

  defp await(fun, tries \\ 100) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(20)
        await(fun, tries - 1)

      other ->
        other
    end
  end

  describe "analyze/1" do
    test "writes analysis files and records exactly one ReviewRecorded; a repeat records none",
         %{repo: repo} do
      Application.put_env(:foreman_server, :review_stub_verdict, %Verdict{
        verdict: :partially_met,
        summary: "stubbed summary",
        scores: %{correctness: 4, tests: 2, documentation: 3, robustness: 5},
        gaps: [%Gap{title: "t", description: "d", dimension: :tests, severity: :minor}]
      })

      s = subject(:jobsite, uid("js"), repo)
      init_archive(s)

      assert :ok = Analyzer.analyze(s)

      json = s.archive_dir |> Path.join("analysis.json") |> File.read!() |> Jason.decode!()
      assert json["verdict"] == "partially_met"
      assert json["scores"]["tests"] == 2
      assert [%{"title" => "t"}] = json["gaps"]
      assert File.read!(Path.join(s.archive_dir, "analysis.md")) =~ "partially_met"

      assert [event] = recorded_events(:jobsite, s.subject_id)
      assert event.event_type == "ReviewRecorded"

      review = await(fn -> ProjectionStore.review("jobsite", s.subject_id) end)
      assert review.verdict == "partially_met"
      assert review.project_id == "proj"
      assert review.bead_id == nil
      assert review.gap_bead_ids == []
      assert review.scores["tests"] == 2
      assert review.summary =~ "stubbed summary"
      assert review.archive_path == s.archive_dir
      assert review.analysis_path == Path.join(s.archive_dir, "analysis.md")
      assert review.evaluator == "ForemanServer.Review.Evaluator.Stub"
      assert review.error_code == nil

      assert {:ok, manifest} = Archive.read_manifest(s.archive_dir)
      assert manifest["status"] == "completed"
      assert is_binary(manifest["finished_at"])

      assert :ok = Analyzer.analyze(s)
      assert [_only] = recorded_events(:jobsite, s.subject_id)
    end

    test "a second analyze whose projection has not caught up still appends nothing (command_id idempotency)",
         %{repo: repo} do
      s = subject(:jobsite, uid("js"), repo)
      init_archive(s)

      assert :ok = Analyzer.analyze(s)
      ProjectionStoreReset.reset!()
      assert ProjectionStore.review("jobsite", s.subject_id) == nil

      assert :ok = Analyzer.analyze(s)
      assert [_only] = recorded_events(:jobsite, s.subject_id)
    end

    test "an evaluator error is still recorded as undetermined with an error code", %{repo: repo} do
      Application.put_env(
        :foreman_server,
        :review_stub_verdict,
        {:error, Error.new(:evaluator_failed, "provider unavailable")}
      )

      s = subject(:jobsite, uid("js"), repo)
      init_archive(s)

      assert :ok = Analyzer.analyze(s)

      json = s.archive_dir |> Path.join("analysis.json") |> File.read!() |> Jason.decode!()
      assert json["verdict"] == "undetermined"
      assert json["error_code"] == "evaluator_failed"

      assert [_] = recorded_events(:jobsite, s.subject_id)
      review = await(fn -> ProjectionStore.review("jobsite", s.subject_id) end)
      assert review.verdict == "undetermined"
      assert review.error_code == "evaluator_failed"
      assert review.summary =~ "provider unavailable"
    end

    test "an evaluator that raises is recorded as undetermined, not lost", %{repo: repo} do
      Application.put_env(:foreman_server, :review_stub_verdict, :not_a_verdict)

      s = subject(:jobsite, uid("js"), repo)
      init_archive(s)

      assert :ok = Analyzer.analyze(s)

      review = await(fn -> ProjectionStore.review("jobsite", s.subject_id) end)
      assert review.verdict == "undetermined"
      assert review.error_code == "evaluator_failed"
    end

    defmodule ExitingEvaluator do
      @behaviour ForemanServer.Review.Evaluator

      # A GenServer.call into a supervisor that is not running exits; it does not raise.
      @impl true
      def evaluate(_subject),
        do: exit({:noproc, {GenServer, :call, [:no_such_supervisor, :start, 5000]}})
    end

    test "an evaluator that exits is recorded as undetermined, not lost", %{repo: repo} do
      review_env = Application.get_env(:foreman_server, :review)

      Application.put_env(
        :foreman_server,
        :review,
        Keyword.put(review_env, :evaluator, ExitingEvaluator)
      )

      s = subject(:jobsite, uid("js"), repo)
      init_archive(s)

      assert :ok = Analyzer.analyze(s)

      review = await(fn -> ProjectionStore.review("jobsite", s.subject_id) end)
      assert review.verdict == "undetermined"
      assert review.error_code == "evaluator_failed"
      assert review.summary =~ "noproc"
    end

    # The record of a review includes what happened around the verdict (foreman-uxfwb):
    # a retried reviewer, a re-run of an earlier failure.
    test "notes on an undetermined verdict reach analysis.json, analysis.md and the recorded summary",
         %{repo: repo} do
      note = "reviewer retried once after 60000 ms: reviewer run ended failed: 429 first try"

      Application.put_env(
        :foreman_server,
        :review_stub_verdict,
        {:error, Error.new(:evaluator_failed, @rate_limited, %{notes: [note]})}
      )

      s = subject(:jobsite, uid("js"), repo)
      init_archive(s)
      assert :ok = Analyzer.analyze(s)

      json = s.archive_dir |> Path.join("analysis.json") |> File.read!() |> Jason.decode!()
      assert json["summary"] =~ "429 rate_limit_error"
      assert json["notes"] == [note]
      assert File.read!(Path.join(s.archive_dir, "analysis.md")) =~ "## Notes"

      review = await(fn -> ProjectionStore.review("jobsite", s.subject_id) end)
      assert review.summary =~ "429 rate_limit_error"
      assert review.summary =~ note
    end

    test "notes on a successful verdict reach the recorded summary", %{repo: repo} do
      note = "reviewer retried once after 60000 ms: 429 first try"

      Application.put_env(:foreman_server, :review_stub_verdict, %{
        met("Looks right.")
        | notes: [note]
      })

      s = subject(:jobsite, uid("js"), repo)
      init_archive(s)
      assert :ok = Analyzer.analyze(s)

      review = await(fn -> ProjectionStore.review("jobsite", s.subject_id) end)
      assert review.verdict == "met"
      assert review.summary =~ "Looks right."
      assert review.summary =~ note
    end

    # A review recorded `undetermined` (a provider rate limit, a killed reviewer) is not
    # the end of the subject: its archive is intact, so the review can be run again.
    test "an undetermined review can be re-run: the new verdict supersedes it and notes the lineage",
         %{repo: repo} do
      s = subject(:jobsite, uid("js"), repo)
      record_undetermined!(s)

      Application.put_env(:foreman_server, :review_stub_verdict, met())
      assert :ok = Analyzer.analyze(s, rerun: true)

      review = await_verdict("jobsite", s.subject_id, "met")
      assert review.summary =~ "Now it is met."
      assert review.summary =~ "re-run of the review recorded undetermined"
      assert review.summary =~ "429 rate_limit_error"

      # Both records stay in the event log; the first is not rewritten.
      assert [_first, _second] = recorded_events(:jobsite, s.subject_id)

      json = s.archive_dir |> Path.join("analysis.json") |> File.read!() |> Jason.decode!()
      assert json["verdict"] == "met"
      assert [lineage] = json["notes"]
      assert lineage =~ "re-run of the review recorded undetermined"
    end

    test "a review that holds a real verdict is never re-run", %{repo: repo} do
      s = subject(:jobsite, uid("js"), repo)
      init_archive(s)
      Application.put_env(:foreman_server, :review_stub_verdict, met("First verdict."))
      assert :ok = Analyzer.analyze(s)
      assert await_verdict("jobsite", s.subject_id, "met")

      Application.put_env(:foreman_server, :review_stub_verdict, met("Second verdict."))
      assert :ok = Analyzer.analyze(s, rerun: true)

      assert [_only] = recorded_events(:jobsite, s.subject_id)
      assert ProjectionStore.review("jobsite", s.subject_id).summary =~ "First verdict."
    end

    test "a re-run with nothing recorded does not review", %{repo: repo} do
      s = subject(:jobsite, uid("js"), repo)
      init_archive(s)

      assert :ok = Analyzer.analyze(s, rerun: true)
      assert [] = recorded_events(:jobsite, s.subject_id)
    end

    # `Capture.finalize/1` rebuilds a run's transcript from its projected run logs, which
    # may no longer exist; the first review already finalized the archive.
    test "a re-run reviews the archive as it is and does not rebuild a run's transcript",
         %{repo: repo} do
      s = subject(:run, uid("run"), repo)
      init_archive(s)
      transcript = Path.join(s.archive_dir, "transcript.jsonl")
      File.write!(transcript, ~s({"type":"output_text_final","text":"original"}\n))

      # No such run is projected, so finalizing fails: the first review is undetermined.
      assert :ok = Analyzer.analyze(s)
      first = await_verdict("run", s.subject_id, "undetermined")
      assert first.error_code == "archive_missing"

      Application.put_env(:foreman_server, :review_stub_verdict, met())
      assert :ok = Analyzer.analyze(s, rerun: true)

      assert await_verdict("run", s.subject_id, "met")
      assert File.read!(transcript) =~ "original"
    end

    test "rerun/2 without a running analyzer says analysis is disabled" do
      assert {:error, :analysis_disabled} = Analyzer.rerun(:run, uid("run"))
    end

    test "a missing archive is recorded as undetermined and the verdict is still archived",
         %{repo: repo} do
      s = subject(:jobsite, uid("js"), repo)

      assert :ok = Analyzer.analyze(s)

      review = await(fn -> ProjectionStore.review("jobsite", s.subject_id) end)
      assert review.verdict == "undetermined"
      assert review.error_code == "archive_missing"
      assert review.analysis_path == Path.join(s.archive_dir, "analysis.md")

      json = s.archive_dir |> Path.join("analysis.json") |> File.read!() |> Jason.decode!()
      assert json["error_code"] == "archive_missing"
    end

    test "an unwritable archive is reported in the summary and leaves analysis_path nil",
         %{repo: repo, tmp_dir: tmp} do
      blocker = Path.join(tmp, "blocker")
      File.write!(blocker, "i am a file")
      s = subject(:jobsite, uid("js"), repo, archive_dir: Path.join(blocker, "nested"))

      assert :ok = Analyzer.analyze(s)

      review = await(fn -> ProjectionStore.review("jobsite", s.subject_id) end)
      assert review.verdict == "undetermined"
      assert review.analysis_path == nil
      assert review.summary =~ "analysis write failed: archive_write_failed"
    end

    test "a bead-less subject never touches the bead sink", %{repo: repo} do
      s = subject(:jobsite, uid("js"), repo, bead_id: nil)
      init_archive(s)

      assert :ok = Analyzer.analyze(s)
      review = await(fn -> ProjectionStore.review("jobsite", s.subject_id) end)
      assert review.gap_bead_ids == []
    end

    test "a jobsite subject with a bead but no project_id is still reviewed; bead step skipped",
         %{repo: repo} do
      s = subject(:jobsite, uid("js"), repo, project_id: nil, bead_id: "bd-1")
      init_archive(s)

      assert :ok = Analyzer.analyze(s)
      review = await(fn -> ProjectionStore.review("jobsite", s.subject_id) end)
      assert review.verdict == "met"
      assert review.project_id == nil
      assert review.gap_bead_ids == []
      assert review.summary =~ "no project_id: bead step skipped"
      assert File.exists?(Path.join(s.archive_dir, "analysis.json"))
    end

    test "a failed evaluation for a project-less subject is recorded as undetermined",
         %{repo: repo} do
      Application.put_env(
        :foreman_server,
        :review_stub_verdict,
        {:error, Error.new(:evaluator_failed, "boom")}
      )

      s = subject(:jobsite, uid("js"), repo, project_id: nil)
      init_archive(s)

      assert :ok = Analyzer.analyze(s)
      review = await(fn -> ProjectionStore.review("jobsite", s.subject_id) end)
      assert review.verdict == "undetermined"
      assert review.error_code == "evaluator_failed"
      assert review.project_id == nil
    end
  end

  describe "subject_from_event/2" do
    defp seed_run(run_id, repo, opts \\ []) do
      task_id = Keyword.get(opts, :task_id, "beads:proj:bd-7")
      external_id = Keyword.get(opts, :external_id, "bd-7")

      events =
        [
          %{
            event_type: "TaskCreated",
            payload: %{
              task_id: task_id,
              project_id: "proj",
              title: "Add healthz",
              description: "desc text",
              prompt: "Add a /healthz route",
              status: "open",
              task_type: "task",
              external_id: external_id
            }
          },
          %{
            event_type: "RunStarted",
            payload: %{
              run_id: run_id,
              task_id: task_id,
              project_id: "proj",
              workflow_name: "implement"
            }
          }
        ] ++
          if Keyword.get(opts, :worktree, true) do
            [
              %{
                event_type: "WorktreeCreated",
                payload: %{
                  operation_id: "op-#{run_id}",
                  project_id: "proj",
                  run_id: run_id,
                  phase_id: "ph",
                  repo_path: repo,
                  worktree_path: Keyword.get(opts, :worktree_path, repo),
                  branch: "agent/x",
                  base_ref: Keyword.get(opts, :base_ref, "abc")
                }
              }
            ]
          else
            []
          end

      assert :ok = ProjectionStore.apply_events(events)
    end

    test "a run resolves request, workflow, repo path and bead id", %{repo: repo} do
      run_id = uid("run")
      seed_run(run_id, repo)

      assert {:ok, %Subject{} = s} =
               Analyzer.subject_from_event("RunFailed", %{run_id: run_id})

      assert s.kind == :run
      assert s.subject_id == run_id
      assert s.project_id == "proj"
      assert s.repo_path == repo
      assert s.archive_dir == Archive.dir(:run, run_id, repo)
      assert s.status == "failed"
      assert s.bead_id == "bd-7"
      assert s.request_title == "Add healthz"
      assert s.request_text == "Add a /healthz route"
      assert s.workflow_name == "implement"
    end

    test "a task whose external_id is not a bead id yields no bead_id", %{repo: repo} do
      run_id = uid("run")
      seed_run(run_id, repo, task_id: "task-1", external_id: "LIN-42")

      assert {:ok, %Subject{bead_id: nil}} =
               Analyzer.subject_from_event("RunCompleted", %{run_id: run_id})
    end

    test "a jobsite resolves repo path, project and bead id from its projection", %{repo: repo} do
      id = uid("js")

      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "JobsiteStarted",
                   payload: %{
                     jobsite_id: id,
                     repo_path: repo,
                     project_id: "proj",
                     bead_id: "bd-9",
                     strategy: "head"
                   }
                 }
               ])

      assert {:ok, %Subject{} = s} =
               Analyzer.subject_from_event("JobsiteCompleted", %{jobsite_id: id})

      assert s.kind == :jobsite
      assert s.project_id == "proj"
      assert s.bead_id == "bd-9"
      assert s.repo_path == repo
      assert s.archive_dir == Archive.dir(:jobsite, id, repo)
      assert s.status == "completed"
    end

    test "unresolvable subjects are typed, carrying the project id when known", %{repo: repo} do
      assert {:unresolved, %{kind: :run, project_id: nil}, %Error{code: :subject_unresolved}} =
               Analyzer.subject_from_event("RunCompleted", %{run_id: "ghost"})

      assert {:unresolved, %{kind: :jobsite, project_id: nil}, %Error{code: :subject_unresolved}} =
               Analyzer.subject_from_event("JobsiteFailed", %{jobsite_id: "ghost"})

      run_id = uid("run")
      seed_run(run_id, repo, worktree: false)

      assert {:unresolved, %{project_id: "proj"}, %Error{code: :archive_missing}} =
               Analyzer.subject_from_event("RunCompleted", %{run_id: run_id})
    end

    test "cancelled terminal events resolve with status cancelled", %{repo: repo} do
      run_id = uid("run")
      seed_run(run_id, repo)

      assert {:ok, %Subject{kind: :run, status: "cancelled", bead_id: "bd-7"} = s} =
               Analyzer.subject_from_event("RunCancelled", %{run_id: run_id})

      assert s.archive_dir == Archive.dir(:run, run_id, repo)

      id = uid("js")

      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "JobsiteStarted",
                   payload: %{
                     jobsite_id: id,
                     repo_path: repo,
                     project_id: "proj",
                     strategy: "head"
                   }
                 }
               ])

      assert {:ok, %Subject{kind: :jobsite, status: "cancelled"}} =
               Analyzer.subject_from_event("JobsiteCancelled", %{jobsite_id: id})
    end
  end

  describe "cancelled runs" do
    defp git!(dir, args) do
      {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
      String.trim(out)
    end

    # A real checkout with a committed base and an uncommitted edit to a tracked
    # file: the state a cancelled run's retained worktree is left in.
    defp cancelled_checkout(repo) do
      File.mkdir_p!(repo)
      git!(repo, ["init", "--initial-branch=main", "--quiet"])
      git!(repo, ["config", "user.email", "t@x"])
      git!(repo, ["config", "user.name", "T"])
      File.write!(Path.join(repo, "README.md"), "seed\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "--no-gpg-sign", "-m", "seed", "--quiet"])
      base = git!(repo, ["rev-parse", "HEAD"])
      File.write!(Path.join(repo, "README.md"), "seed\nhalf finished before cancel\n")
      base
    end

    test "RunCancelled archives the working-tree diff, reviews it, and records a cancelled archive",
         %{repo: repo} do
      base = cancelled_checkout(repo)
      run_id = uid("run")
      seed_run(run_id, repo, worktree_path: repo, base_ref: base)

      # No run executor is registered for this run, so there is nothing to wait for.
      assert [] = Registry.lookup(ForemanServer.RunExecutorRegistry, run_id)
      assert :ok = Analyzer.handle_event("RunCancelled", %{run_id: run_id})

      dir = Archive.dir(:run, run_id, repo)
      assert {:ok, manifest} = Archive.read_manifest(dir)
      assert manifest["status"] == "cancelled"
      assert manifest["diff_status"] == "captured"
      assert File.read!(Path.join(dir, "request.md")) == "Add a /healthz route"
      assert File.read!(Path.join(dir, "diff.patch")) =~ "+half finished before cancel"

      json = dir |> Path.join("analysis.json") |> File.read!() |> Jason.decode!()
      assert json["verdict"] == "met"

      assert [event] = recorded_events(:run, run_id)
      assert event.event_type == "ReviewRecorded"

      review = await(fn -> ProjectionStore.review("run", run_id) end)
      assert review.verdict == "met"
      assert review.archive_path == dir
      assert review.analysis_path == Path.join(dir, "analysis.md")
      assert review.error_code == nil
    end

    test "the archive is taken only after the run's executor has stopped", %{repo: repo} do
      base = cancelled_checkout(repo)
      run_id = uid("run")
      seed_run(run_id, repo, worktree_path: repo, base_ref: base)
      dir = Archive.dir(:run, run_id, repo)

      parent = self()

      executor =
        spawn(fn ->
          {:ok, _} = Registry.register(ForemanServer.RunExecutorRegistry, run_id, nil)
          send(parent, :executor_registered)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :executor_registered, 1_000

      task = Task.async(fn -> Analyzer.handle_event("RunCancelled", %{run_id: run_id}) end)

      # While the executor is alive nothing may be captured.
      Process.sleep(400)
      assert Task.yield(task, 0) == nil
      refute File.exists?(Path.join(dir, "manifest.json"))

      ref = Process.monitor(executor)
      send(executor, :stop)
      assert_receive {:DOWN, ^ref, :process, ^executor, _}, 1_000

      # The Analyzer captures the archive (git subprocesses) once the executor is gone, and how
      # long that takes depends on the host: wait for it, not for a budget.
      assert :ok = Task.await(task, :infinity)

      assert {:ok, %{"status" => "cancelled", "diff_status" => "captured"}} =
               Archive.read_manifest(dir)

      assert await(fn -> ProjectionStore.review("run", run_id) end).verdict == "met"
    end
  end

  describe "failed runs" do
    # `cancelled_checkout/1` with its edit committed: the state a failed run's
    # worktree is in when its executor captures `base..HEAD`.
    defp failed_checkout(repo) do
      base = cancelled_checkout(repo)
      File.write!(Path.join(repo, "README.md"), "seed\ndelivered before the failure\n")
      git!(repo, ["commit", "--no-gpg-sign", "-am", "agent work", "--quiet"])
      base
    end

    # Stands in for a run's `RunExecutor`: holds the run's registry entry until it
    # is sent `:finish`, runs `on_finish` (what the real executor does before it
    # stops) and exits.
    defp start_fake_executor(run_id, on_finish) do
      parent = self()

      executor =
        spawn(fn ->
          {:ok, _} = Registry.register(ForemanServer.RunExecutorRegistry, run_id, nil)
          send(parent, {:executor_registered, run_id})

          receive do
            :finish -> on_finish.()
          end
        end)

      on_exit(fn -> Process.exit(executor, :kill) end)

      receive do
        {:executor_registered, ^run_id} -> :ok
      end

      executor
    end

    # `RunExecutor.emit_phase_failure/4` dispatches `run.fail` first; only then
    # does `finalize_terminal_and_stop/2` write the archive
    # (`cleanup_run_worktree/2` -> `Capture.close_run/2`) and stop the executor.
    # `RunFailed` therefore reaches the Analyzer while the archive does not exist
    # yet, and reviewing it then would record a permanent `archive_missing`.
    test "RunFailed is reviewed only after the executor has written the archive and stopped",
         %{repo: repo} do
      base = failed_checkout(repo)
      run_id = uid("run")
      seed_run(run_id, repo, worktree_path: repo, base_ref: base)
      dir = Archive.dir(:run, run_id, repo)
      worktree = %{worktree_path: repo, base_ref: base, branch: "agent/x"}

      executor =
        start_fake_executor(run_id, fn ->
          :ok = Capture.close_run(%{run_id: run_id, run_worktree: worktree}, :failure)
        end)

      task = Task.async(fn -> Analyzer.handle_event("RunFailed", %{run_id: run_id}) end)

      # While the executor is alive there is no archive and nothing may be
      # recorded against its absence.
      Process.sleep(400)
      assert Task.yield(task, 0) == nil
      refute File.exists?(Path.join(dir, "manifest.json"))
      assert recorded_events(:run, run_id) == []

      ref = Process.monitor(executor)
      send(executor, :finish)

      # `Capture.close_run/2` runs git subprocesses before the executor exits, so how long it
      # takes depends on the host, and a time budget here only moves the load at which the test
      # fails. Wait for the DOWN itself: the executor wrote the archive and stopped normally,
      # and the Analyzer, which polls for exactly that, then reviews it.
      receive do
        {:DOWN, ^ref, :process, ^executor, reason} -> assert reason == :normal
      end

      assert :ok = Task.await(task, :infinity)

      assert {:ok, %{"status" => "failed", "diff_status" => "captured"}} =
               Archive.read_manifest(dir)

      assert File.read!(Path.join(dir, "diff.patch")) =~ "+delivered before the failure"

      assert [event] = recorded_events(:run, run_id)
      assert event.event_type == "ReviewRecorded"

      review = await(fn -> ProjectionStore.review("run", run_id) end)
      assert review.verdict == "met"
      assert review.error_code == nil
      assert review.archive_path == dir
    end

    # `finalize_run/1` captures before `run.complete` and the executor then stays
    # alive, so waiting for it would stall the review of every successful run for
    # the whole timeout.
    test "RunCompleted is reviewed without waiting for the executor to stop", %{repo: repo} do
      run_id = uid("run")
      seed_run(run_id, repo)
      init_archive(subject(:run, run_id, repo))
      start_fake_executor(run_id, fn -> :ok end)

      task = Task.async(fn -> Analyzer.handle_event("RunCompleted", %{run_id: run_id}) end)

      assert {:ok, :ok} = Task.yield(task, 5_000)
      assert await(fn -> ProjectionStore.review("run", run_id) end).verdict == "met"
    end
  end

  describe "subscriber" do
    setup do
      start_supervised!({Task.Supervisor, name: ForemanServer.Review.TaskSupervisor})
      pid = start_supervised!(Analyzer)
      {:ok, analyzer: pid}
    end

    test "subscribes to the projection store without replay", %{analyzer: pid} do
      assert pid in Map.keys(:sys.get_state(ProjectionStore).subscribers)
    end

    test "reacts to RunCompleted and RunFailed, ignoring non-terminal run events", %{repo: repo} do
      for {type, expected_status} <- [{"RunCompleted", "completed"}, {"RunFailed", "failed"}] do
        run_id = uid("run")
        seed_run(run_id, repo, task_id: "task-#{run_id}", external_id: "x")

        s = subject(:run, run_id, repo)
        init_archive(s)

        # Seeding emitted only non-terminal events (RunStarted etc.): no review yet.
        Process.sleep(50)
        assert ProjectionStore.review("run", run_id) == nil

        assert :ok =
                 ProjectionStore.apply_events([
                   %{event_type: type, payload: %{run_id: run_id, task_id: "task-#{run_id}"}}
                 ])

        review = await(fn -> ProjectionStore.review("run", run_id) end)
        assert review.verdict == "met"
        assert review.project_id == "proj"

        assert {:ok, manifest} = Archive.read_manifest(s.archive_dir)
        assert manifest["status"] == expected_status
        assert File.exists?(Path.join(s.archive_dir, "analysis.json"))
      end
    end

    test "reacts to JobsiteCompleted and JobsiteFailed, ignoring JobsiteStarted", %{repo: repo} do
      for type <- ["JobsiteCompleted", "JobsiteFailed"] do
        id = uid("js")

        assert :ok =
                 ProjectionStore.apply_events([
                   %{
                     event_type: "JobsiteStarted",
                     payload: %{
                       jobsite_id: id,
                       repo_path: repo,
                       project_id: "proj",
                       strategy: "head"
                     }
                   }
                 ])

        init_archive(subject(:jobsite, id, repo))
        Process.sleep(50)
        assert ProjectionStore.review("jobsite", id) == nil

        assert :ok =
                 ProjectionStore.apply_events([
                   %{event_type: type, payload: %{jobsite_id: id}}
                 ])

        review = await(fn -> ProjectionStore.review("jobsite", id) end)
        assert review.verdict == "met"
        assert review.subject_kind == "jobsite"
      end
    end

    test "an unresolvable run with a known project is recorded as undetermined", %{repo: repo} do
      run_id = uid("run")
      seed_run(run_id, repo, worktree: false)

      assert :ok =
               ProjectionStore.apply_events([
                 %{event_type: "RunFailed", payload: %{run_id: run_id}}
               ])

      review = await(fn -> ProjectionStore.review("run", run_id) end)
      assert review.verdict == "undetermined"
      assert review.error_code == "archive_missing"
      assert review.archive_path == nil
    end

    test "an unresolvable subject with no project is dropped, not recorded" do
      import ExUnit.CaptureLog

      log =
        capture_log([level: :error], fn ->
          assert :ok =
                   ProjectionStore.apply_events([
                     %{event_type: "RunCompleted", payload: %{run_id: "ghost-run"}}
                   ])

          Process.sleep(200)
        end)

      assert log =~ "dropping run \"ghost-run\""
      assert ProjectionStore.review("run", "ghost-run") == nil
    end

    defmodule GatedEvaluator do
      @behaviour ForemanServer.Review.Evaluator

      # Tells the test it is evaluating and blocks until told to `:release` (return
      # a verdict) or `:crash` (kill its own process), so the test decides how long
      # the analysis stays in flight. The test's pid travels in the application env
      # because the analysis runs in a task under the Analyzer's supervisor.
      @impl true
      def evaluate(%ForemanServer.Review.Subject{subject_id: id}) do
        test = Application.fetch_env!(:foreman_server, :review_gated_evaluator_test)
        send(test, {:evaluating, id, self()})

        receive do
          :release -> {:ok, %ForemanServer.Review.Verdict{verdict: :met, summary: "released"}}
          :crash -> Process.exit(self(), :kill)
        end
      end
    end

    defp gate_evaluator! do
      Application.put_env(:foreman_server, :review_gated_evaluator_test, self())
      on_exit(fn -> Application.delete_env(:foreman_server, :review_gated_evaluator_test) end)

      review = Application.get_env(:foreman_server, :review)

      Application.put_env(
        :foreman_server,
        :review,
        Keyword.put(review, :evaluator, GatedEvaluator)
      )
    end

    defp started_jobsite(repo) do
      id = uid("js")

      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "JobsiteStarted",
                   payload: %{
                     jobsite_id: id,
                     repo_path: repo,
                     project_id: "proj",
                     strategy: "head"
                   }
                 }
               ])

      init_archive(subject(:jobsite, id, repo))
      id
    end

    defp deliver_jobsite_failed(id) do
      assert :ok =
               ProjectionStore.apply_events([
                 %{event_type: "JobsiteFailed", payload: %{jobsite_id: id}}
               ])
    end

    test "a terminal event for a subject whose analysis is still running is dropped",
         %{repo: repo, analyzer: analyzer} do
      gate_evaluator!()
      id = started_jobsite(repo)

      deliver_jobsite_failed(id)
      assert_receive {:evaluating, ^id, evaluating}, 5_000

      # The same event arrives again while the evaluator is still running. The
      # review is not recorded yet, so only the in-flight guard can stop a second
      # evaluation (and, behind it, a second bead comment and second gap beads).
      deliver_jobsite_failed(id)
      _ = :sys.get_state(analyzer)
      refute_receive {:evaluating, ^id, _}, 300

      send(evaluating, :release)
      assert await(fn -> ProjectionStore.review("jobsite", id) end).verdict == "met"
      assert [_only] = recorded_events(:jobsite, id)
    end

    test "a subject whose analysis died without recording is analysed again on its next event",
         %{repo: repo, analyzer: analyzer} do
      gate_evaluator!()
      id = started_jobsite(repo)

      deliver_jobsite_failed(id)
      assert_receive {:evaluating, ^id, doomed}, 5_000
      ref = Process.monitor(doomed)
      send(doomed, :crash)
      assert_receive {:DOWN, ^ref, :process, ^doomed, :killed}, 1_000
      assert ProjectionStore.review("jobsite", id) == nil

      # The Analyzer releases the subject once it sees its task go down.
      assert :released ==
               await(fn -> if :sys.get_state(analyzer).in_flight == %{}, do: :released end)

      deliver_jobsite_failed(id)
      assert_receive {:evaluating, ^id, retry}, 5_000
      send(retry, :release)
      assert await(fn -> ProjectionStore.review("jobsite", id) end).verdict == "met"
    end

    # The event boundary (`unwrap_data/1`) is where both key conventions are read,
    # once; `subject_from_event/2` and `handle_event/2` take the atom-keyed result.
    test "string-keyed events resolve at the boundary and mint no atoms",
         %{repo: repo, analyzer: analyzer} do
      probe = "analyzer_probe_#{System.unique_integer([:positive])}"

      run_id = uid("run")
      seed_run(run_id, repo, task_id: "task-#{run_id}", external_id: "x")
      init_archive(subject(:run, run_id, repo))
      jobsite_id = started_jobsite(repo)

      # A fully string-keyed envelope, and an atom-keyed envelope with a string-keyed payload.
      send(
        analyzer,
        {:projection_event,
         %{"event_type" => "RunFailed", "data" => %{"run_id" => run_id, probe => 1}}}
      )

      send(
        analyzer,
        {:projection_event,
         %{event_type: "JobsiteFailed", payload: %{"jobsite_id" => jobsite_id}}}
      )

      assert await(fn -> ProjectionStore.review("run", run_id) end).verdict == "met"
      assert await(fn -> ProjectionStore.review("jobsite", jobsite_id) end).verdict == "met"

      # Only the fields this module reads are looked up: event data never becomes an atom.
      assert_raise ArgumentError, fn -> String.to_existing_atom(probe) end
    end

    # ----- rerun/2 and the concurrency bound (foreman-uxfwb) -----------------------------

    test "rerun/2 re-reviews an undetermined review from its archive and refuses the rest",
         %{repo: repo} do
      s = subject(:jobsite, uid("js"), repo)
      record_undetermined!(s)

      Application.put_env(:foreman_server, :review_stub_verdict, met())
      assert :ok = Analyzer.rerun(:jobsite, s.subject_id)
      assert await_verdict("jobsite", s.subject_id, "met")

      assert {:error, {:not_rerunnable, "met"}} = Analyzer.rerun(:jobsite, s.subject_id)
      assert {:error, :not_reviewed} = Analyzer.rerun(:jobsite, uid("js"))
      assert [_first, _second] = recorded_events(:jobsite, s.subject_id)
    end

    test "rerun/2 refuses while an analysis of the subject is running", %{repo: repo} do
      s = subject(:jobsite, uid("js"), repo)
      record_undetermined!(s)
      gate_evaluator!()

      assert :ok = Analyzer.rerun(:jobsite, s.subject_id)
      assert_receive {:evaluating, id, evaluating}, 5_000
      assert id == s.subject_id

      assert {:error, :already_running} = Analyzer.rerun(:jobsite, s.subject_id)
      refute_receive {:evaluating, _, _}, 200

      send(evaluating, :release)
      assert await_verdict("jobsite", s.subject_id, "met")
    end

    test "rerun/2 reports an archive that can no longer be read", %{repo: repo} do
      s = subject(:jobsite, uid("js"), repo)
      record_undetermined!(s)
      File.rm_rf!(s.archive_dir)

      assert {:error, {:archive_unusable, %Error{code: :archive_missing}}} =
               Analyzer.rerun(:jobsite, s.subject_id)

      assert [_only] = recorded_events(:jobsite, s.subject_id)
    end

    test "the shipped configuration bounds concurrent analyses" do
      assert is_integer(Application.get_env(:foreman_server, :review)[:max_concurrent_analyses])
      assert Application.get_env(:foreman_server, :review)[:max_concurrent_analyses] > 0
    end

    test "no more than max_concurrent_analyses evaluate at once; the rest start as slots free",
         %{repo: repo, analyzer: analyzer} do
      gate_evaluator!()
      put_review(max_concurrent_analyses: 2)
      ids = for _ <- 1..4, do: started_jobsite(repo)
      Enum.each(ids, &deliver_jobsite_failed/1)

      assert_receive {:evaluating, a, pid_a}, 5_000
      assert_receive {:evaluating, b, pid_b}, 5_000
      refute_receive {:evaluating, _, _}, 300
      assert map_size(:sys.get_state(analyzer).in_flight) == 2

      send(pid_a, :release)
      assert_receive {:evaluating, c, pid_c}, 5_000
      refute_receive {:evaluating, _, _}, 300
      assert map_size(:sys.get_state(analyzer).in_flight) == 2

      send(pid_b, :release)
      assert_receive {:evaluating, d, pid_d}, 5_000
      send(pid_c, :release)
      send(pid_d, :release)

      for id <- ids, do: assert(await_verdict("jobsite", id, "met"))
      assert Enum.sort([a, b, c, d]) == Enum.sort(ids)
      # a task's DOWN is handled after its verdict is projected: wait for the last one
      assert await(fn -> if :sys.get_state(analyzer).in_flight == %{}, do: true end)
    end

    test "a subject that is already queued is not queued again", %{repo: repo, analyzer: analyzer} do
      gate_evaluator!()
      put_review(max_concurrent_analyses: 1)
      running = started_jobsite(repo)
      waiting = started_jobsite(repo)

      deliver_jobsite_failed(running)
      assert_receive {:evaluating, ^running, running_pid}, 5_000
      deliver_jobsite_failed(waiting)
      deliver_jobsite_failed(waiting)
      _ = :sys.get_state(analyzer)
      refute_receive {:evaluating, _, _}, 200

      send(running_pid, :release)
      assert_receive {:evaluating, ^waiting, waiting_pid}, 5_000
      refute_receive {:evaluating, ^waiting, _}, 300

      send(waiting_pid, :release)
      assert await_verdict("jobsite", waiting, "met")
      assert [_only] = recorded_events(:jobsite, waiting)
    end

    test "an analysis that dies frees its slot for the next queued subject",
         %{repo: repo, analyzer: analyzer} do
      gate_evaluator!()
      put_review(max_concurrent_analyses: 1)
      doomed = started_jobsite(repo)
      next = started_jobsite(repo)

      deliver_jobsite_failed(doomed)
      assert_receive {:evaluating, ^doomed, doomed_pid}, 5_000
      deliver_jobsite_failed(next)
      _ = :sys.get_state(analyzer)
      refute_receive {:evaluating, ^next, _}, 200

      send(doomed_pid, :crash)
      assert_receive {:evaluating, ^next, next_pid}, 5_000
      send(next_pid, :release)
      assert await_verdict("jobsite", next, "met")
    end
  end
end
