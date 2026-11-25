defmodule ForemanServer.Workflow.RunExecutorOriginBaseTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.RunExecutor

  # A run is cut from the REMOTE tip of its base branch, not from whatever the
  # shared checkout happens to hold: a stale checkout yields stale PRs
  # (bead foreman-y2zoc / foreman-ch78x). A remote that answers but cannot be
  # fetched from degrades to the LOCAL tip of the recorded base branch (with a
  # warning), not a failed run; a remote that does not carry the branch, a
  # checkout without the remote, and a recorded branch the checkout does not
  # have are typed failures — never a silent cut from `HEAD`.
  setup do
    tmp =
      Path.join(System.tmp_dir!(), "foreman-origin-base-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    origin = Path.join(tmp, "origin.git")
    repo = Path.join(tmp, "repo")
    peer = Path.join(tmp, "peer")

    git!(tmp, ["init", "--bare", "--quiet", "--initial-branch=main", origin])
    git!(tmp, ["init", "--quiet", "--initial-branch=main", repo])
    git!(repo, ["remote", "add", "origin", origin])
    commit!(repo, "seed.txt", "seed")
    git!(repo, ["push", "--quiet", "--set-upstream", "origin", "main"])

    git!(tmp, ["clone", "--quiet", origin, peer])
    commit!(peer, "ahead.txt", "ahead")
    git!(peer, ["push", "--quiet", "origin", "main"])

    on_exit(fn -> File.rm_rf(tmp) end)

    %{
      tmp: tmp,
      origin: origin,
      repo: repo,
      peer: peer,
      stale_head: git!(repo, ["rev-parse", "HEAD"]),
      origin_tip: git!(peer, ["rev-parse", "HEAD"])
    }
  end

  test "the base is the fetched origin tip, not the stale checkout HEAD", %{
    repo: repo,
    stale_head: stale_head,
    origin_tip: origin_tip
  } do
    assert stale_head != origin_tip

    assert {:ok, ^repo, ^origin_tip, nil, nil} = resolve_base(state(repo))
  end

  test "the fetch leaves the checkout untouched", %{
    repo: repo,
    stale_head: stale_head,
    origin_tip: origin_tip
  } do
    # This case runs the resolver itself: each test has its own checkout, so
    # the fetch this case asserts on has to happen here.
    assert {:ok, ^repo, ^origin_tip, nil, nil} = resolve_base(state(repo))

    assert git!(repo, ["rev-parse", "HEAD"]) == stale_head
    assert git!(repo, ["symbolic-ref", "--short", "HEAD"]) == "main"
    assert git!(repo, ["status", "--porcelain"]) == ""
    assert git!(repo, ["rev-parse", "refs/remotes/origin/main"]) == origin_tip
  end

  test "the run's recorded base branch wins over the checkout's current branch", %{
    repo: repo,
    origin_tip: origin_tip
  } do
    # The shared checkout is switched after the run recorded its base branch:
    # the worktree must still be cut from the RECORDED branch's remote tip,
    # because that is the branch the PR targets.
    git!(repo, ["checkout", "--quiet", "-b", "feat/local-only"])
    commit!(repo, "local.txt", "local")

    assert {:ok, ^repo, ^origin_tip, nil, nil} = resolve_base(state(repo, base_branch: "main"))
  end

  test "a remote that does not carry the recorded branch is a typed error", %{repo: repo} do
    git!(repo, ["checkout", "--quiet", "-b", "feat/local-only"])
    commit!(repo, "local.txt", "local")

    assert {:error, {:origin_base_missing, "origin", "feat/local-only"}} =
             resolve_base(state(repo, base_branch: "feat/local-only"))
  end

  test "a checkout without an origin remote is a typed failure", %{repo: repo} do
    git!(repo, ["remote", "remove", "origin"])

    assert {:error, {:origin_remote_missing, "origin"}} = resolve_base(state(repo))
  end

  test "an unreadable origin degrades to the local base branch", %{
    repo: repo,
    tmp: tmp,
    stale_head: stale_head
  } do
    git!(repo, ["remote", "set-url", "origin", Path.join(tmp, "gone.git")])

    # The remote cannot be read at all: the run still starts, cut from the
    # LOCAL tip of the branch its PR targets.
    assert {:ok, ^repo, ^stale_head, nil, nil} = resolve_base(state(repo))
  end

  test "a fetch that fails against a readable remote degrades to the local base branch", %{
    repo: repo,
    origin: origin,
    peer: peer,
    stale_head: stale_head
  } do
    # The remote advertises the branch (so it is not missing) but cannot serve
    # the objects: the fetch fails while the branch is still readable.
    tree = git!(peer, ["rev-parse", "HEAD^{tree}"])
    object = Path.join(origin, "objects/#{String.slice(tree, 0, 2)}/#{String.slice(tree, 2..-1//1)}")
    assert File.exists?(object)
    File.rm!(object)

    assert {:ok, ^repo, ^stale_head, nil, nil} = resolve_base(state(repo))
  end

  test "a recorded base branch the checkout does not have is a typed failure", %{
    repo: repo,
    tmp: tmp
  } do
    git!(repo, ["remote", "set-url", "origin", Path.join(tmp, "gone.git")])
    git!(repo, ["checkout", "--quiet", "--detach"])
    git!(repo, ["branch", "-D", "main"])

    assert {:error, {:local_base_branch_unresolvable, "main", ^repo, _reason}} =
             resolve_base(state(repo))
  end

  test "a declared base is resolved locally and is never fetched", %{
    repo: repo,
    stale_head: stale_head,
    origin_tip: origin_tip
  } do
    local_main = git!(repo, ["rev-parse", "main^{commit}"])
    assert local_main == stale_head
    assert local_main != origin_tip

    assert {:ok, ^repo, ^local_main, nil, nil} = resolve_base(state(repo), %{base: "main"})
  end

  test "a task source branch is still cut from the local branch", %{repo: repo} do
    git!(repo, ["checkout", "--quiet", "-b", "feat/local-only"])
    commit!(repo, "local.txt", "local")
    local_tip = git!(repo, ["rev-parse", "HEAD"])

    assert {:ok, ^repo, ^local_tip, nil, nil} =
             resolve_base(state(repo, task: %{source_branch: "feat/local-only"}))
  end

  defp state(repo, opts \\ []) do
    %{
      task:
        Map.merge(
          %{
            project_id: "proj-origin-base",
            task_id: "t-origin-base",
            working_directory: repo
          },
          opts[:task] || %{}
        ),
      run_id: "run-" <> String.duplicate("0", 32),
      run_base_branch: {:ok, opts[:base_branch] || "main"},
      plan_context: nil,
      worktree_spec: %{}
    }
  end

  defp resolve_base(state, spec \\ %{}) do
    RunExecutor.__resolve_provisioned_base_for_test__(state, spec)
  end

  defp git!(dir, args) do
    {output, code} = System.cmd("git", args, stderr_to_stdout: true, cd: dir)

    if code == 0 do
      String.trim(output)
    else
      raise "git #{Enum.join(args, " ")} failed (#{code}): #{output}"
    end
  end

  defp commit!(repo, file, message) do
    File.write!(Path.join(repo, file), message <> "\n")
    git!(repo, ["add", file])

    git!(repo, [
      "-c",
      "user.name=Foreman Test",
      "-c",
      "user.email=test@example.com",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "--quiet",
      "-m",
      message
    ])
  end
end
