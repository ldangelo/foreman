defmodule ForemanServer.Review.CaptureRunTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Review.Archive
  alias ForemanServer.Review.Capture
  alias ForemanServer.Review.Error
  alias ForemanServer.Review.Subject
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup %{tmp_dir: tmp} do
    ProjectionStoreReset.reset!()
    original = Application.get_env(:foreman_server, :review, [])

    on_exit(fn ->
      Application.put_env(:foreman_server, :review, original)
      ProjectionStoreReset.reset!()
    end)

    root = Path.join(tmp, "archive")

    Application.put_env(
      :foreman_server,
      :review,
      Keyword.merge(original, capture: true, archive_root: root)
    )

    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q"])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "a.txt"), "one\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "first"])
    base = git!(repo, ["rev-parse", "HEAD"])
    File.write!(Path.join(repo, "b.txt"), "two\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "second"])

    {:ok, repo: repo, base: base, root: root, original: original}
  end

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    String.trim(out)
  end

  defp seed(run_id, repo, opts \\ []) do
    task_id = Keyword.get(opts, :task_id, "beads:proj:bd-7")

    events = [
      %{
        event_type: "TaskCreated",
        payload: %{
          task_id: task_id,
          project_id: "proj",
          title: "Add healthz",
          description: "desc text",
          prompt: Keyword.get(opts, :prompt, "Add a /healthz route"),
          status: "open",
          task_type: "task",
          external_id: Keyword.get(opts, :external_id, "bd-7")
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
      },
      %{
        event_type: "WorktreeCreated",
        payload: %{
          operation_id: "op-#{run_id}",
          project_id: "proj",
          run_id: run_id,
          phase_id: "ph",
          repo_path: repo,
          worktree_path: repo,
          branch: "agent/x",
          base_ref: "ignored"
        }
      }
    ]

    assert :ok = ProjectionStore.apply_events(events)
  end

  defp state(run_id, repo, base) do
    %{run_id: run_id, run_worktree: %{worktree_path: repo, base_ref: base, branch: "agent/x"}}
  end

  test "close_run writes request, manifest with bead id, and the diff", %{repo: repo, base: base} do
    seed("run-1", repo)
    assert :ok = Capture.close_run(state("run-1", repo, base), :success)

    dir = Archive.dir(:run, "run-1", repo)
    assert File.read!(Path.join(dir, "request.md")) == "Add a /healthz route"
    assert File.read!(Path.join(dir, "diff.patch")) =~ "+two"
    assert File.read!(Path.join(dir, "changed-files.txt")) =~ "b.txt"

    assert {:ok, m} = Archive.read_manifest(dir)
    assert m["kind"] == "run"
    assert m["bead_id"] == "bd-7"
    assert m["project_id"] == "proj"
    assert m["status"] == "completed"
    assert m["base_ref"] == base
    assert m["branch"] == "agent/x"
    assert m["diff_status"] == "captured"
    assert m["request"]["workflow_name"] == "implement"
    assert m["request"]["source"] == "task"
    assert m["transcript_source"] == "run_logs"
    assert m["capture_errors"] == []
  end

  test "manifest lists every provider session id seen across phases, de-duplicated in order",
       %{repo: repo, base: base} do
    seed("run-sess", repo)

    bound = fn worker_id, session_id ->
      %{
        event_type: "WorkerSessionBound",
        payload: %{
          run_id: "run-sess",
          worker_id: worker_id,
          provider: "claude",
          provider_session_id: session_id
        }
      }
    end

    assert :ok =
             ProjectionStore.apply_events([
               bound.("w1", "sess-1"),
               bound.("w2", "sess-2"),
               bound.("w3", "sess-1")
             ])

    assert :ok = Capture.close_run(state("run-sess", repo, base), :success)

    assert {:ok, m} = Archive.read_manifest(Archive.dir(:run, "run-sess", repo))
    assert m["provider_session_ids"] == ["sess-1", "sess-2"]
  end

  test "a run whose providers reported no session keeps an empty list", %{
    repo: repo,
    base: base
  } do
    seed("run-nosess", repo)
    assert :ok = Capture.close_run(state("run-nosess", repo, base), :success)

    assert {:ok, m} = Archive.read_manifest(Archive.dir(:run, "run-nosess", repo))
    assert m["provider_session_ids"] == []
    assert m["capture_errors"] == []
  end

  test "a non-bead external_id is not treated as a bead id", %{repo: repo, base: base} do
    seed("run-2", repo, task_id: "github:acme/x#9", external_id: "9")
    assert :ok = Capture.close_run(state("run-2", repo, base), :failure)

    assert {:ok, m} = Archive.read_manifest(Archive.dir(:run, "run-2", repo))
    assert m["bead_id"] == nil
    assert m["status"] == "failed"
  end

  test "an unreachable base ref records diff unavailable, never a clean empty archive", %{
    repo: repo
  } do
    seed("run-3", repo)

    assert :ok =
             Capture.close_run(state("run-3", repo, String.duplicate("0", 40)), :failure)

    assert {:ok, m} = Archive.read_manifest(Archive.dir(:run, "run-3", repo))
    assert m["diff_status"] == "unavailable"
    assert [%{"stage" => "diff", "code" => "diff_failed"} | _] = m["capture_errors"]
  end

  test "a run with no worktree base records the missing diff", %{repo: repo} do
    seed("run-4", repo)
    assert :ok = Capture.close_run(%{run_id: "run-4", run_worktree: nil}, :failure)

    assert {:ok, m} = Archive.read_manifest(Archive.dir(:run, "run-4", repo))
    assert m["diff_status"] == "unavailable"
    assert Enum.any?(m["capture_errors"], &(&1["stage"] == "diff"))
  end

  test "close_run writes nothing when capture is disabled", %{
    repo: repo,
    base: base,
    root: root,
    original: original
  } do
    Application.put_env(
      :foreman_server,
      :review,
      Keyword.merge(original, capture: false, archive_root: root)
    )

    seed("run-5", repo)

    assert :ok = Capture.close_run(state("run-5", repo, base), :success)
    refute File.exists?(root)
  end

  test "close_run never raises on garbage state" do
    assert :ok = Capture.close_run(%{}, :success)
    assert :ok = Capture.close_run(%{run_id: 42}, :failure)
    assert :ok = Capture.close_run(nil, :success)
    assert :ok = Capture.close_run(%{run_id: "unknown-run", run_worktree: :nope}, :failure)
  end

  test "run_repo_path is typed-error when no worktree is projected, never a guess" do
    assert {:error, %Error{code: :archive_missing}} = Capture.run_repo_path("no-such-run")
  end

  test "bead_id_for_task requires the beads task id shape" do
    ok = %{task_id: "beads:p:bd-1", project_id: "p", external_id: "bd-1"}
    assert Capture.bead_id_for_task(ok) == "bd-1"
    assert Capture.bead_id_for_task(%{ok | project_id: "q"}) == nil
    assert Capture.bead_id_for_task(%{ok | external_id: ""}) == nil
    assert Capture.bead_id_for_task(nil) == nil
  end

  describe "finalize/1" do
    defp subject(run_id, repo) do
      %Subject{
        kind: :run,
        subject_id: run_id,
        project_id: "proj",
        repo_path: repo,
        archive_dir: Archive.dir(:run, run_id, repo),
        status: "completed"
      }
    end

    defp log_events(run_id, count) do
      for i <- 1..count do
        %{
          event_type: "WorkerStdout",
          payload: %{
            run_id: run_id,
            worker_id: "w",
            sequence: i,
            line: "line #{i}",
            timestamp: "2026-01-01T00:00:00Z"
          }
        }
      end
    end

    test "materialises the transcript from run logs", %{repo: repo, base: base} do
      seed("run-6", repo)
      assert :ok = ProjectionStore.apply_events(log_events("run-6", 3))
      assert :ok = Capture.close_run(state("run-6", repo, base), :success)

      s = subject("run-6", repo)
      assert :ok = Capture.finalize(s)

      lines =
        s.archive_dir
        |> Path.join("transcript.jsonl")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert Enum.map(lines, & &1["text"]) == ["line 1", "line 2", "line 3"]
      assert Enum.all?(lines, &(&1["type"] == "stdout" and is_binary(&1["timestamp"])))

      assert {:ok, m} = Archive.read_manifest(s.archive_dir)
      assert m["transcript_source"] == "run_logs"
      assert m["transcript_truncated"] == false
      assert m["omitted_entries"] == 0
      assert m["status"] == "completed"
      assert is_binary(m["finished_at"])
    end

    test "marks a bounded log visibly truncated", %{repo: repo, base: base} do
      seed("run-7", repo)
      assert :ok = ProjectionStore.apply_events(log_events("run-7", 505))
      assert :ok = Capture.close_run(state("run-7", repo, base), :success)

      s = subject("run-7", repo)
      assert :ok = Capture.finalize(s)

      assert {:ok, m} = Archive.read_manifest(s.archive_dir)
      assert m["transcript_truncated"] == true
      assert m["omitted_entries"] == 5
      assert is_integer(m["omitted_bytes"])
    end

    test "unknown run is a typed error recorded in capture_errors", %{repo: repo, base: base} do
      seed("run-8", repo)
      assert :ok = Capture.close_run(state("run-8", repo, base), :success)

      s = subject("run-8", repo)

      assert {:error, %Error{code: :archive_missing}} =
               Capture.transcript_from_run_logs(s.archive_dir, "ghost-run")

      assert {:ok, m} = Archive.read_manifest(s.archive_dir)
      assert Enum.any?(m["capture_errors"], &(&1["stage"] == "transcript"))
    end

    test "missing archive is an error, not a silent ok", %{repo: repo} do
      assert {:error, %Error{code: :archive_missing}} =
               Capture.finalize(subject("never-captured", repo))
    end

    test "jobsite finalize only merges status and finished_at", %{repo: repo} do
      dir = Archive.dir(:jobsite, "js-1", repo)

      assert :ok =
               Archive.init(dir, %{
                 "kind" => "jobsite",
                 "subject_id" => "js-1",
                 "transcript_source" => "harness_events"
               })

      s = %Subject{subject("js-1", repo) | kind: :jobsite, archive_dir: dir, status: :failed}
      assert :ok = Capture.finalize(s)

      assert {:ok, m} = Archive.read_manifest(dir)
      assert m["status"] == "failed"
      assert m["transcript_source"] == "harness_events"
      assert is_binary(m["finished_at"])
      refute File.exists?(Path.join(dir, "transcript.jsonl"))
    end
  end
end
