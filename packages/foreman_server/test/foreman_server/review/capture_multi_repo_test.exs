defmodule ForemanServer.Review.CaptureMultiRepoTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Review.Archive
  alias ForemanServer.Review.Capture
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @run "run-mr"

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

    {a, a_base} = repo!(Path.join(tmp, "a"), "a-change.txt")
    {b, b_base} = repo!(Path.join(tmp, "b"), "b-change.txt")

    {:ok, a: a, a_base: a_base, b: b, b_base: b_base, root: root, tmp: tmp}
  end

  # A repo with a base commit and a second commit adding `file`.
  defp repo!(path, file) do
    File.mkdir_p!(path)
    git!(path, ["init", "-q"])
    git!(path, ["config", "user.email", "t@example.com"])
    git!(path, ["config", "user.name", "T"])
    File.write!(Path.join(path, "seed.txt"), "seed\n")
    git!(path, ["add", "."])
    git!(path, ["commit", "-q", "-m", "first"])
    base = git!(path, ["rev-parse", "HEAD"])
    File.write!(Path.join(path, file), "#{file} content\n")
    git!(path, ["add", "."])
    git!(path, ["commit", "-q", "-m", "second"])
    {path, base}
  end

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    String.trim(out)
  end

  defp worktree_event(op, repo_id, repo, base, branch) do
    extra = if repo_id, do: %{repo_id: repo_id}, else: %{}

    %{
      event_type: "WorktreeCreated",
      payload:
        Map.merge(
          %{
            operation_id: op,
            project_id: "proj",
            run_id: @run,
            phase_id: "ph",
            repo_path: repo,
            worktree_path: repo,
            branch: branch,
            base_ref: base
          },
          extra
        )
    }
  end

  defp seed(ctx, opts \\ []) do
    b_base = Keyword.get(opts, :b_base, ctx.b_base)
    b_id = Keyword.get(opts, :b_id, "b")

    events =
      [
        %{
          event_type: "TaskCreated",
          payload: %{
            task_id: "t-mr",
            project_id: "proj",
            title: "Two repos",
            prompt: "Change both repos",
            status: "open",
            task_type: "task"
          }
        },
        %{
          event_type: "RunStarted",
          payload: %{
            run_id: @run,
            task_id: "t-mr",
            project_id: "proj",
            workflow_name: "implement",
            repo_ids: [b_id]
          }
        },
        worktree_event("op-a", nil, ctx.a, ctx.a_base, "agent/a"),
        worktree_event("op-b", b_id, ctx.b, b_base, "agent/b")
      ] ++
        if(Keyword.get(opts, :pr, true),
          do: [
            %{
              event_type: "PrAssociated",
              payload: %{run_id: @run, repo_id: b_id, pr_url: "https://x/pull/2", pr_number: 2}
            }
          ],
          else: []
        )

    assert :ok = ProjectionStore.apply_events(events)
  end

  defp dir(ctx), do: Archive.dir(:run, @run, ctx.a)

  defp state(ctx),
    do: %{
      run_id: @run,
      run_worktree: %{worktree_path: ctx.a, base_ref: ctx.a_base, branch: "agent/a"}
    }

  test "primary keeps diff.patch/changed-files.txt; the other repo gets diffs/<id>.patch + .files.txt",
       ctx do
    seed(ctx)
    assert :ok = Capture.close_run(state(ctx), :success)
    dir = dir(ctx)

    primary = File.read!(Path.join(dir, "diff.patch"))
    assert primary =~ "a-change.txt"
    refute primary =~ "b-change.txt"
    assert File.read!(Path.join(dir, "changed-files.txt")) =~ "a-change.txt"

    patch_b = File.read!(Path.join([dir, "diffs", "b.patch"]))
    assert patch_b =~ "+b-change.txt content"
    refute patch_b =~ "a-change.txt"
    files_b = File.read!(Path.join([dir, "diffs", "b.files.txt"]))
    assert files_b =~ "b-change.txt"
    refute files_b =~ "a-change.txt"

    assert Enum.sort(File.ls!(Path.join(dir, "diffs"))) == ["b.files.txt", "b.patch"]
  end

  test "manifest lists every repository (schema stays v1) with pr_url from the PR associations",
       ctx do
    seed(ctx)
    assert :ok = Capture.close_run(state(ctx), :success)
    assert {:ok, m} = Archive.read_manifest(dir(ctx))

    assert m["schema"] == "foreman.review.manifest.v1"
    assert m["capture_errors"] == []
    assert m["diff_status"] == "captured"

    assert [
             %{
               "id" => "main",
               "primary" => true,
               "branch" => "agent/a",
               "base_ref" => a_base,
               "worktree_path" => a_path,
               "diff_status" => "captured",
               "pr_url" => nil
             },
             %{
               "id" => "b",
               "primary" => false,
               "branch" => "agent/b",
               "base_ref" => b_base,
               "worktree_path" => b_path,
               "diff_status" => "captured",
               "pr_url" => "https://x/pull/2"
             }
           ] = m["repositories"]

    assert {a_base, a_path, b_base, b_path} == {ctx.a_base, ctx.a, ctx.b_base, ctx.b}
  end

  test "a single-repo run keeps the legacy layout: no repositories key, no diffs dir", ctx do
    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "RunStarted",
                 payload: %{run_id: @run, project_id: "proj", workflow_name: "implement"}
               },
               worktree_event("op-a", nil, ctx.a, ctx.a_base, "agent/a")
             ])

    assert :ok = Capture.close_run(state(ctx), :success)
    dir = dir(ctx)

    assert {:ok, m} = Archive.read_manifest(dir)
    refute Map.has_key?(m, "repositories")
    refute File.exists?(Path.join(dir, "diffs"))

    assert Enum.sort(File.ls!(dir)) ==
             ["changed-files.txt", "diff.patch", "manifest.json", "request.md"]
  end

  test "a failing git diff for one repo records the error and still archives the rest", ctx do
    seed(ctx, b_base: String.duplicate("0", 40))
    assert :ok = Capture.close_run(state(ctx), :success)
    dir = dir(ctx)

    assert File.read!(Path.join(dir, "diff.patch")) =~ "a-change.txt"
    refute File.exists?(Path.join([dir, "diffs", "b.patch"]))

    assert {:ok, m} = Archive.read_manifest(dir)
    assert m["diff_status"] == "captured"

    assert [%{"diff_status" => "captured"}, %{"id" => "b", "diff_status" => "unavailable"}] =
             m["repositories"]

    assert Enum.any?(m["capture_errors"], &(&1["stage"] == "diff:b"))
  end

  test "an option-shaped base ref is refused by the Git.diff ref guard", ctx do
    seed(ctx, b_base: "--output=#{Path.join(ctx.tmp, "pwned")}")
    assert :ok = Capture.close_run(state(ctx), :success)

    refute File.exists?(Path.join(ctx.tmp, "pwned"))
    assert {:ok, m} = Archive.read_manifest(dir(ctx))
    assert [_, %{"id" => "b", "diff_status" => "unavailable"}] = m["repositories"]
    assert Enum.any?(m["capture_errors"], &(&1["stage"] == "diff:b"))
  end

  test "diffs are truncated at max_diff_bytes and the truncation is recorded", ctx do
    File.write!(Path.join(ctx.b, "big.txt"), String.duplicate("x\n", 5_000))
    git!(ctx.b, ["add", "."])
    git!(ctx.b, ["commit", "-q", "-m", "big"])

    review = Application.get_env(:foreman_server, :review)
    Application.put_env(:foreman_server, :review, Keyword.put(review, :max_diff_bytes, 100))

    seed(ctx)
    assert :ok = Capture.close_run(state(ctx), :success)
    dir = dir(ctx)

    assert byte_size(File.read!(Path.join([dir, "diffs", "b.patch"]))) == 100
    assert {:ok, m} = Archive.read_manifest(dir)

    assert Enum.any?(
             m["capture_errors"],
             &(&1["stage"] == "diff:b" and &1["message"] =~ "truncated")
           )

    assert [_, %{"diff_status" => "captured"}] = m["repositories"]
  end

  test "a repo id that is not a valid id never produces a file", ctx do
    seed(ctx, b_id: "Bad/../x")
    assert :ok = Capture.close_run(state(ctx), :success)
    dir = dir(ctx)

    refute File.exists?(Path.join(dir, "diffs"))
    refute File.exists?(Path.join(ctx.tmp, "x.patch"))
    assert {:ok, m} = Archive.read_manifest(dir)
    assert Enum.any?(m["repositories"], &(&1["diff_status"] == "unavailable"))
  end

  test "write_repo_file refuses traversal and unknown extensions", ctx do
    dir = Path.join(ctx.tmp, "arch")
    File.mkdir_p!(dir)

    assert {:error, %{code: :archive_write_failed}} =
             Archive.write_repo_file(dir, "../evil", "patch", "x")

    assert {:error, %{code: :archive_write_failed}} =
             Archive.write_repo_file(dir, "a/b", "patch", "x")

    assert :ok = Archive.write_repo_file(dir, "ok-1", "patch", "x")
    assert File.read!(Path.join([dir, "diffs", "ok-1.patch"])) == "x"
    refute File.exists?(Path.join(ctx.tmp, "evil.patch"))

    assert_raise FunctionClauseError, fn ->
      apply(Archive, :write_repo_file, [dir, "ok", "sh", ""])
    end
  end

  test "close_cancelled_run iterates every projected worktree, primary first, uncommitted work included",
       ctx do
    seed(ctx)
    File.write!(Path.join(ctx.a, "a-wip.txt"), "wip a\n")
    File.write!(Path.join(ctx.b, "b-wip.txt"), "wip b\n")

    assert :ok = Capture.close_cancelled_run(@run)
    dir = dir(ctx)

    assert File.read!(Path.join(dir, "diff.patch")) =~ "a-wip.txt"
    refute File.read!(Path.join(dir, "diff.patch")) =~ "b-wip.txt"
    assert File.read!(Path.join([dir, "diffs", "b.patch"])) =~ "b-wip.txt"

    assert {:ok, m} = Archive.read_manifest(dir)
    assert m["status"] == "cancelled"
    assert [%{"id" => "main", "primary" => true}, %{"id" => "b"}] = m["repositories"]
  end
end
