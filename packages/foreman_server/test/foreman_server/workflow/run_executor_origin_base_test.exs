defmodule ForemanServer.Workflow.RunExecutorOriginBaseTest do
  @moduledoc """
  A new run worktree is cut from the FETCHED `origin/<branch>` tip, not from the
  operator checkout's possibly-stale local `HEAD`.

  Covers the branches of `RunExecutor.resolve_origin_base/2` (reached through the
  exported `__resolve_provisioned_base_for_test__/2`) plus the never-fetch case
  of `resolve_declared_base/3`, and asserts the operator's working tree and
  branch pointer are untouched by the fetch.

  Real temporary git repos (bare origin + clones), no mocks.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.RunExecutor

  defp sh!(cwd, args) when is_list(args) do
    {out, code} = System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)

    if code != 0 do
      flunk("git #{Enum.join(args, " ")} in #{cwd} failed (#{code}): #{out}")
    end

    String.trim(out)
  end

  defp commit_file(repo, path, body, message) do
    File.write!(Path.join(repo, path), body)
    sh!(repo, ["add", "--", path])

    sh!(repo, [
      "-c",
      "user.name=Foreman Test",
      "-c",
      "user.email=test@foreman.local",
      "commit",
      "-m",
      message
    ])
  end

  defp clone(origin, dest) do
    {out, code} = System.cmd("git", ["clone", origin, dest], stderr_to_stdout: true)
    if code != 0, do: flunk("git clone failed: #{out}")

    sh!(dest, ["config", "user.name", "Foreman Test"])
    sh!(dest, ["config", "user.email", "test@foreman.local"])
    dest
  end

  defp state(repo_path, task_overrides \\ %{}) do
    %{
      task:
        Map.merge(
          %{
            id: "beads:foreman:t-origin-base",
            task_id: "t-origin-base",
            project_id: "proj-origin-base",
            working_directory: repo_path
          },
          task_overrides
        ),
      run_id: "run-" <> String.duplicate("0", 32),
      plan_context: nil,
      worktree_spec: %{}
    }
  end

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "foreman-origin-base-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    origin = Path.join(tmp, "origin.git")

    {out, code} =
      System.cmd("git", ["init", "--bare", "--initial-branch=main", origin],
        stderr_to_stdout: true
      )

    if code != 0, do: flunk("git init --bare failed: #{out}")

    seed = clone(origin, Path.join(tmp, "seed"))
    commit_file(seed, "seed.txt", "seed\n", "seed")
    sh!(seed, ["push", "origin", "HEAD:refs/heads/main"])

    repo = clone(origin, Path.join(tmp, "repo"))
    peer = clone(origin, Path.join(tmp, "peer"))

    # The peer advances origin/main while the operator's checkout stays behind.
    commit_file(peer, "ahead.txt", "ahead\n", "peer advance")
    sh!(peer, ["push", "origin", "HEAD:refs/heads/main"])

    %{
      tmp: tmp,
      origin: origin,
      repo: repo,
      stale_head: sh!(repo, ["rev-parse", "HEAD"]),
      origin_tip: sh!(peer, ["rev-parse", "HEAD"])
    }
  end

  test "bases the worktree on the fetched origin tip, not the stale checkout HEAD", ctx do
    assert {:ok, repo, base_ref, nil, nil} =
             RunExecutor.__resolve_provisioned_base_for_test__(state(ctx.repo), %{})

    assert repo == ctx.repo
    assert base_ref == ctx.origin_tip
    refute base_ref == ctx.stale_head
  end

  test "the fetch leaves the operator's checkout untouched", ctx do
    branch_before = sh!(ctx.repo, ["symbolic-ref", "--short", "HEAD"])
    status_before = sh!(ctx.repo, ["status", "--porcelain"])

    assert {:ok, _repo, _base_ref, nil, nil} =
             RunExecutor.__resolve_provisioned_base_for_test__(state(ctx.repo), %{})

    assert sh!(ctx.repo, ["symbolic-ref", "--short", "HEAD"]) == branch_before
    assert sh!(ctx.repo, ["rev-parse", "HEAD"]) == ctx.stale_head
    assert sh!(ctx.repo, ["status", "--porcelain"]) == status_before
    # Only the remote-tracking ref advanced.
    assert sh!(ctx.repo, ["rev-parse", "refs/remotes/origin/main"]) == ctx.origin_tip
  end

  test "falls back to local HEAD when the remote does not carry the branch", ctx do
    sh!(ctx.repo, ["checkout", "-b", "feature"])
    feature_tip = sh!(ctx.repo, ["rev-parse", "HEAD"])

    assert {:ok, _repo, base_ref, nil, nil} =
             RunExecutor.__resolve_provisioned_base_for_test__(state(ctx.repo), %{})

    assert base_ref == feature_tip
    refute base_ref == ctx.origin_tip
  end

  test "falls back to local HEAD when no origin remote is configured", ctx do
    standalone = clone(ctx.origin, Path.join(ctx.tmp, "standalone"))
    sh!(standalone, ["remote", "remove", "origin"])
    tip = sh!(standalone, ["rev-parse", "HEAD"])

    assert {:ok, _repo, base_ref, nil, nil} =
             RunExecutor.__resolve_provisioned_base_for_test__(state(standalone), %{})

    assert base_ref == tip
  end

  test "a declared base resolves locally and is never fetched", ctx do
    assert {:ok, _repo, base_ref, nil, nil} =
             RunExecutor.__resolve_provisioned_base_for_test__(state(ctx.repo), %{base: "main"})

    assert base_ref == ctx.stale_head
    # No fetch happened: the remote-tracking ref is still at the clone-time tip.
    assert sh!(ctx.repo, ["rev-parse", "refs/remotes/origin/main"]) == ctx.stale_head
  end

  test "a task that names its own source_branch keeps the local base", ctx do
    assert {:ok, _repo, base_ref, nil, nil} =
             RunExecutor.__resolve_provisioned_base_for_test__(
               state(ctx.repo, %{source_branch: "main"}),
               %{}
             )

    assert base_ref == ctx.stale_head
  end
end
