defmodule ForemanServer.Library.CollectorTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.{EventStore, Library, ProjectionStore}
  alias ForemanServer.Library.Collector
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup %{tmp_dir: dir} do
    on_exit(fn -> System.cmd("chmod", ["-R", "u+w", dir]) end)
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    original = Application.get_env(:foreman_server, :library, [])
    on_exit(fn -> Application.put_env(:foreman_server, :library, original) end)

    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "docs/reports"))
    id = System.unique_integer([:positive])
    {:ok, dir: dir, repo: repo, project_id: "col-#{id}", run_id: "run-col-#{id}"}
  end

  defp register_project(ctx, config) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: ctx.project_id, path: ctx.repo, config: config}
        },
        %{
          event_type: "RunStarted",
          payload: %{
            run_id: ctx.run_id,
            task_id: "t-1",
            project_id: ctx.project_id,
            workflow_name: "implement",
            workflow_digest: "d",
            workflow_snapshot: %{},
            sequence: 1
          }
        }
      ])
  end

  defp opt_in(ctx), do: register_project(ctx, %{library_collect_produced: true})

  defp artifact(ctx, name \\ "report.md", content \\ "# report") do
    path = Path.join([ctx.repo, "docs/reports", name])
    File.write!(path, content)
    path
  end

  defp phase_completed(ctx, path, index \\ 1) do
    Collector.handle_event("PhaseCompleted", %{
      run_id: ctx.run_id,
      index: index,
      artifact_path: path,
      artifact_sha256: "x",
      artifact_bytes: 1
    })
  end

  defp produced(ctx) do
    {:ok, entries} = Library.list(ctx.project_id)
    Enum.filter(entries, &(&1.kind == :produced))
  end

  defp stream_events(ctx) do
    case EventStore.read_stream_forward("project_library:#{ctx.project_id}", 0, 1000) do
      {:ok, events} -> events
      {:error, :stream_not_found} -> []
    end
  end

  test "a project that did not opt in registers nothing", ctx do
    register_project(ctx, %{})
    phase_completed(ctx, artifact(ctx))
    assert produced(ctx) == []
    assert stream_events(ctx) == []
  end

  test "opted in: the phase artifact lands in the run's produced entry", ctx do
    opt_in(ctx)
    phase_completed(ctx, artifact(ctx), 2)

    assert [%{name: name, files: [%{path: "phase-2/report.md", bytes: 8}], source: source}] =
             produced(ctx)

    assert name == "produced-" <> ctx.run_id
    assert source["kind"] == "thread" and source["run_id"] == ctx.run_id

    assert {:ok, "# report"} =
             Library.read(ctx.project_id, hd(produced(ctx)).entry_id, "phase-2/report.md")
  end

  test "replaying the same event is a no-op; new content at the same path replaces that file",
       ctx do
    opt_in(ctx)
    path = artifact(ctx)

    phase_completed(ctx, path)
    phase_completed(ctx, path)
    assert length(stream_events(ctx)) == 1

    File.write!(path, "# report v2")
    phase_completed(ctx, path)
    assert length(stream_events(ctx)) == 2
    assert [%{files: [%{path: "phase-1/report.md", bytes: 11}]}] = produced(ctx)
  end

  test "later phases accumulate in the same entry", ctx do
    opt_in(ctx)
    phase_completed(ctx, artifact(ctx, "a.md", "a"), 1)
    phase_completed(ctx, artifact(ctx, "b.md", "b"), 2)

    assert [%{files: files}] = produced(ctx)
    assert Enum.map(files, & &1.path) == ["phase-1/a.md", "phase-2/b.md"]
  end

  test "an artifact outside the run's directories is never read", ctx do
    opt_in(ctx)
    outside = Path.join(ctx.dir, "outside-secret.txt")
    File.write!(outside, "TOP-SECRET")

    phase_completed(ctx, outside)
    phase_completed(ctx, "/etc/hosts")
    assert produced(ctx) == []
  end

  test "a symlink that points outside is refused, even from inside the repo", ctx do
    opt_in(ctx)
    outside = Path.join(ctx.dir, "outside-secret.txt")
    File.write!(outside, "TOP-SECRET")
    link = Path.join([ctx.repo, "docs/reports", "link.md"])
    File.ln_s!(outside, link)

    phase_completed(ctx, link)
    assert produced(ctx) == []

    linked_dir = Path.join(ctx.repo, "linked")
    File.ln_s!(ctx.dir, linked_dir)
    phase_completed(ctx, Path.join(linked_dir, "outside-secret.txt"))
    assert produced(ctx) == []
  end

  test "the per-run budget is enforced and the first file survives", ctx do
    opt_in(ctx)

    Application.put_env(
      :foreman_server,
      :library,
      Keyword.put(
        Application.get_env(:foreman_server, :library, []),
        :produced_max_files_per_run,
        1
      )
    )

    phase_completed(ctx, artifact(ctx, "a.md", "a"), 1)

    log =
      ExUnit.CaptureLog.capture_log(fn -> phase_completed(ctx, artifact(ctx, "b.md", "b"), 2) end)

    assert log =~ "produced_over_budget"
    assert [%{files: [%{path: "phase-1/a.md"}]}] = produced(ctx)
  end

  test "ReviewRecorded registers analysis.md and diff.patch from the archive dir only", ctx do
    opt_in(ctx)
    archive = Path.join(ctx.dir, "archive/run/#{ctx.run_id}")
    File.mkdir_p!(archive)
    File.write!(Path.join(archive, "analysis.md"), "verdict")
    File.write!(Path.join(archive, "diff.patch"), "diff --git")
    File.write!(Path.join(archive, "transcript.jsonl"), "{}")

    Collector.handle_event("ReviewRecorded", %{
      subject_kind: "run",
      subject_id: ctx.run_id,
      project_id: ctx.project_id,
      archive_path: archive
    })

    assert [%{files: files}] = produced(ctx)
    assert Enum.map(files, & &1.path) == ["archive/analysis.md", "archive/diff.patch"]
  end

  test "the subscribed process reacts to projection events", ctx do
    opt_in(ctx)
    pid = start_supervised!(Collector)

    send(
      pid,
      {:projection_event,
       %{
         event_type: "PhaseCompleted",
         data: %{run_id: ctx.run_id, index: 1, artifact_path: artifact(ctx)}
       }}
    )

    # A synchronous call returns only after the earlier message was handled.
    _ = :sys.get_state(pid)

    assert [%{files: [%{path: "phase-1/report.md"}]}] = produced(ctx)
  end
end
