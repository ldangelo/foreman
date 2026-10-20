defmodule ForemanServer.Review.AnalyzerTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Aggregates.Review, as: ReviewAggregate
  alias ForemanServer.EventStore
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Review.Analyzer
  alias ForemanServer.Review.Archive
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
        "project_id" => s.project_id
      })
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
      def evaluate(_subject), do: exit({:noproc, {GenServer, :call, [:no_such_supervisor, :start, 5000]}})
    end

    test "an evaluator that exits is recorded as undetermined, not lost", %{repo: repo} do
      review_env = Application.get_env(:foreman_server, :review)
      Application.put_env(:foreman_server, :review, Keyword.put(review_env, :evaluator, ExitingEvaluator))

      s = subject(:jobsite, uid("js"), repo)
      init_archive(s)

      assert :ok = Analyzer.analyze(s)

      review = await(fn -> ProjectionStore.review("jobsite", s.subject_id) end)
      assert review.verdict == "undetermined"
      assert review.error_code == "evaluator_failed"
      assert review.summary =~ "noproc"
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
      Application.put_env(:foreman_server, :review_stub_verdict, {:error, Error.new(:evaluator_failed, "boom")})
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

      assert {:ok, %Subject{} = s} = Analyzer.subject_from_event("RunFailed", %{"run_id" => run_id})
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
               Analyzer.subject_from_event("JobsiteCompleted", %{"jobsite_id" => id})

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
                   payload: %{jobsite_id: id, repo_path: repo, project_id: "proj", strategy: "head"}
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

      assert :ok = Task.await(task, 5_000)
      assert {:ok, %{"status" => "cancelled", "diff_status" => "captured"}} = Archive.read_manifest(dir)
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
  end
end
