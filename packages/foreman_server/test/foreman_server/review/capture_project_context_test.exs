defmodule ForemanServer.Review.CaptureProjectContextTest do
  # The standing context an agent was launched with is archived as
  # `project-context.md` + a manifest block, and survives `close_run/2`
  # rewriting the manifest.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Identity
  alias ForemanServer.ProjectContext
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Review.Archive
  alias ForemanServer.Review.Capture
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup %{tmp_dir: tmp} do
    ProjectionStoreReset.reset!()
    original = Application.get_env(:foreman_server, :review, [])

    on_exit(fn ->
      Application.put_env(:foreman_server, :review, original)
      ProjectionStoreReset.reset!()
    end)

    Application.put_env(
      :foreman_server,
      :review,
      Keyword.merge(original, capture: true, archive_root: Path.join(tmp, "archive"))
    )

    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "ProjectRegistered",
                 payload: %{
                   project_id: "pcx",
                   path: repo,
                   config: %{instructions: "Always use tabs"}
                 }
               },
               %{
                 event_type: "RunStarted",
                 payload: %{
                   run_id: "run-pcx",
                   task_id: "t-pcx",
                   project_id: "pcx",
                   workflow_name: "implement"
                 }
               },
               %{
                 event_type: "WorktreeCreated",
                 payload: %{
                   operation_id: "op-pcx",
                   project_id: "pcx",
                   run_id: "run-pcx",
                   phase_id: "ph",
                   repo_path: repo,
                   worktree_path: repo,
                   branch: "agent/x",
                   base_ref: "x"
                 }
               }
             ])

    {:ok, bundle} = ProjectContext.build("pcx")
    {:ok, repo: repo, bundle: bundle, dir: Archive.dir(:run, "run-pcx", repo)}
  end

  test "writes the launched text verbatim with a matching manifest block", %{
    bundle: bundle,
    dir: dir
  } do
    assert :ok = Capture.put_run_project_context("run-pcx", bundle)

    text = File.read!(Path.join(dir, "project-context.md"))
    assert text == bundle.system_text

    assert {:ok, %{"project_context" => block}} = Archive.read_manifest(dir)
    assert block["sha256"] == Identity.sha256(text)
    assert block["bytes"] == byte_size(text)
    assert block["truncated"] == []
  end

  test "the manifest block survives close_run rewriting the manifest", %{
    bundle: bundle,
    dir: dir
  } do
    :ok = Capture.put_run_project_context("run-pcx", bundle)
    Capture.close_run(%{run_id: "run-pcx"}, :success)

    assert {:ok, manifest} = Archive.read_manifest(dir)
    assert manifest["kind"] == "run"
    assert manifest["status"] == "completed"
    assert manifest["project_context"]["sha256"] == bundle.sha256
  end

  test "only the first launch is archived (the file records what the run started with)", %{
    bundle: bundle,
    dir: dir
  } do
    :ok = Capture.put_run_project_context("run-pcx", bundle)
    later = %{bundle | system_text: "changed later", sha256: "other", bytes: 13}
    :ok = Capture.put_run_project_context("run-pcx", later)

    assert File.read!(Path.join(dir, "project-context.md")) == bundle.system_text
  end

  test "capture off or an empty bundle writes nothing", %{bundle: bundle, dir: dir} do
    empty = %{bundle | system_text: nil}
    assert :ok = Capture.put_run_project_context("run-pcx", empty)
    refute File.exists?(dir)

    original = Application.get_env(:foreman_server, :review)
    Application.put_env(:foreman_server, :review, Keyword.put(original, :capture, false))
    assert :ok = Capture.put_run_project_context("run-pcx", bundle)
    refute File.exists?(dir)
  end
end
