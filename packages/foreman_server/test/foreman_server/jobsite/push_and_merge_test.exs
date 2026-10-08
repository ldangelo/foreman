defmodule ForemanServer.Jobsite.PushAndMergeTest do
  # `push: true` publishes the run's branch to `origin` after the commit, on both the
  # fresh-run path and the resume path, and a failed push fails the jobsite while the
  # commits stay on the local branch. `merge_into/2` merges a completed jobsite's branch
  # only into the branch that is actually checked out. All against real git.
  use ExUnit.Case, async: false

  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    # `Jobsite.list/0` is global; start empty so "the failed jobsite" is unambiguous.
    ProjectionStoreReset.reset!()
    on_exit(fn -> ProjectionStoreReset.reset!() end)
    :ok
  end

  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{Agents, Error, Git, Sandboxes}

  @fake_agent Path.join(__DIR__, "support/fake_agent.sh")

  defp git!(path, args),
    do: {_, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)

  # A repo whose `origin` is a bare repo, so "was it pushed" is a question about
  # the bare repo's refs.
  defp repo_with_origin! do
    base = Path.join(System.tmp_dir!(), "jobsite-push-#{System.unique_integer([:positive])}")
    repo = Path.join(base, "work")
    bare = Path.join(base, "origin.git")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", bare])
    git!(repo, ["init", "-q"])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "hi\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "init"])
    git!(repo, ["remote", "add", "origin", bare])
    on_exit(fn -> File.rm_rf(base) end)
    %{repo: repo, bare: bare}
  end

  defp origin_branch(bare, branch) do
    case System.cmd("git", [
           "-C",
           bare,
           "rev-parse",
           "--verify",
           "--quiet",
           "refs/heads/#{branch}"
         ]) do
      {sha, 0} -> String.trim(sha)
      {_, _} -> nil
    end
  end

  defp local_sha(repo, branch) do
    {sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "refs/heads/#{branch}"])
    String.trim(sha)
  end

  defp run_opts(repo, branch, extra \\ []) do
    [
      repo_path: repo,
      strategy: {:branch, branch},
      sandbox: Sandboxes.host(),
      agent: Agents.pi("x", binary: @fake_agent),
      prompt: "go"
    ]
    |> Keyword.merge(extra)
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("wait_until timed out")
      true -> Process.sleep(25) && wait_until(fun, deadline)
    end
  end

  describe "Git.push/3" do
    test "publishes exactly the named branch" do
      %{repo: repo, bare: bare} = repo_with_origin!()
      git!(repo, ["checkout", "-q", "-b", "feature"])
      File.write!(Path.join(repo, "f.txt"), "x")
      {:ok, :committed} = Git.commit_all(repo, "feature work")
      git!(repo, ["branch", "other"])

      assert :ok = Git.push(repo, "origin", "feature")
      assert origin_branch(bare, "feature") == local_sha(repo, "feature")
      assert origin_branch(bare, "other") == nil
    end

    test "an unreachable remote is a typed :push_failed carrying git's output, never a hang" do
      %{repo: repo} = repo_with_origin!()
      git!(repo, ["remote", "set-url", "origin", "/nonexistent/remote.git"])
      git!(repo, ["checkout", "-q", "-b", "feature"])

      assert {:error,
              %Error{
                code: :push_failed,
                details: %{remote: "origin", branch: "feature", output: output}
              }} =
               Git.push(repo, "origin", "feature")

      assert output != ""
    end
  end

  describe "push: true on a fresh run" do
    test "the branch reaches origin and matches the local commit" do
      %{repo: repo, bare: bare} = repo_with_origin!()

      assert {:ok, result} = Jobsite.run(run_opts(repo, "agent/pushed", push: true))

      assert result.branch == "agent/pushed"
      assert origin_branch(bare, "agent/pushed") == local_sha(repo, "agent/pushed")
      # The commit really is the agent's work, not an empty branch tip.
      {:ok, base_sha} = Git.head_sha(repo)
      assert origin_branch(bare, "agent/pushed") != base_sha
    end

    test "without push nothing is published (the control that makes the case above meaningful)" do
      %{repo: repo, bare: bare} = repo_with_origin!()

      assert {:ok, _result} = Jobsite.run(run_opts(repo, "agent/local-only"))
      assert origin_branch(bare, "agent/local-only") == nil
    end

    test "a failing push fails the jobsite with :push_failed and keeps the commits locally" do
      %{repo: repo} = repo_with_origin!()
      git!(repo, ["remote", "set-url", "origin", "/nonexistent/remote.git"])

      assert {:error, %Error{code: :push_failed}} =
               Jobsite.run(run_opts(repo, "agent/unpushable", push: true))

      assert [%{jobsite_id: id} | _] = Enum.filter(Jobsite.list(), &(&1.status == "failed"))
      assert Jobsite.get(id).status == "failed"

      # The work survives on the local branch, one commit past the base.
      {count, 0} =
        System.cmd("git", ["-C", repo, "rev-list", "--count", "HEAD..agent/unpushable"])

      assert String.trim(count) == "1"
    end
  end

  describe "push: true across a pause/resume" do
    test "a resumed run publishes its branch like a fresh one (push is persisted, not an opt)" do
      %{repo: repo, bare: bare} = repo_with_origin!()

      agent =
        Agents.pi("x",
          binary: @fake_agent,
          env: %{"FAKE_AGENT_SLEEP_ON_RUN" => "1", "FAKE_AGENT_SLEEP_SECS" => "5"}
        )

      {:ok, id} =
        Jobsite.run_async(
          run_opts(repo, "agent/resumed",
            push: true,
            agent: agent,
            max_iterations: 3,
            completion_signal: "NEVER"
          )
        )

      wait_until(fn -> (Jobsite.get(id) || %{})[:iteration_index] == 1 end)
      assert :ok = Jobsite.pause(id, "pause before push")
      wait_until(fn -> (Jobsite.get(id) || %{})[:status] == "paused" end)
      assert origin_branch(bare, "agent/resumed") == nil

      # `resume/1` is given no options at all, so only persisted state can carry `push`.
      assert {:ok, result} = Jobsite.resume(id)

      assert result.branch == "agent/resumed"
      assert origin_branch(bare, "agent/resumed") == local_sha(repo, "agent/resumed")
    end
  end

  describe "merge_into/2" do
    test "merges a completed jobsite's branch into the checked-out branch, then reports it gone" do
      %{repo: repo} = repo_with_origin!()
      {:ok, current} = Git.current_branch(repo)

      {:ok, result} = Jobsite.run(run_opts(repo, "agent/to-merge"))

      assert {:ok, %{branch: "agent/to-merge", merged_into: ^current}} =
               Jobsite.merge_into(result.jobsite_id, current)

      assert File.exists?(Path.join(repo, "agent-log.txt"))
      refute Git.branch_exists?(repo, "agent/to-merge")

      assert {:error, %Error{code: :branch_missing}} =
               Jobsite.merge_into(result.jobsite_id, current)
    end

    test "refuses to merge into a branch that is not the checked-out one, leaving the repo untouched" do
      %{repo: repo} = repo_with_origin!()
      {:ok, current} = Git.current_branch(repo)
      {:ok, result} = Jobsite.run(run_opts(repo, "agent/not-yet"))
      {:ok, head_before} = Git.head_sha(repo)

      assert {:error, %Error{code: :merge_target_mismatch, details: %{checked_out: ^current}}} =
               Jobsite.merge_into(result.jobsite_id, "some-other-branch")

      assert {:ok, ^head_before} = Git.head_sha(repo)
      assert Git.branch_exists?(repo, "agent/not-yet")
    end

    test "a jobsite that did not complete cannot be merged" do
      %{repo: repo} = repo_with_origin!()
      {:ok, current} = Git.current_branch(repo)
      git!(repo, ["remote", "set-url", "origin", "/nonexistent/remote.git"])
      {:error, _} = Jobsite.run(run_opts(repo, "agent/failed", push: true))
      [%{jobsite_id: id} | _] = Enum.filter(Jobsite.list(), &(&1.status == "failed"))

      assert {:error, %Error{code: :not_completed}} = Jobsite.merge_into(id, current)
    end

    test "unknown jobsite" do
      assert {:error, %Error{code: :jobsite_not_found}} = Jobsite.merge_into("js-nope", "main")
    end
  end
end
