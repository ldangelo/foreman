defmodule ForemanServer.Workflow.PhasePRTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.PhasePR

  defp request(overrides \\ %{}) do
    struct!(
      PhasePR.Request,
      Map.merge(
        %{
          run_id: "run-1",
          phase_id: "phase-1",
          phase_index: 1,
          phase_name: "implement",
          base_branch: "main",
          head_branch: "foreman/run-1",
          cwd: "/repo",
          now: ~U[2026-09-01 00:00:00Z],
          command_runner: &runner/3
        },
        overrides
      )
    )
  end

  test "returns noop when head has no commits beyond base" do
    assert {:ok, record} = PhasePR.maybe_create(request(%{command_runner: runner_with_ahead(0)}))
    assert record.status == "noop"
    assert record.reason == "no_commits_ahead"
    assert record.pr_url == nil
  end

  test "created path pushes and opens a GitHub PR" do
    assert {:ok, record} = PhasePR.maybe_create(request())
    assert record.status == "created"
    assert record.pr_url == "https://github.com/acme/repo/pull/42"
    assert record.pr_number == 42
    assert record.base_branch == "main"
    assert record.head_branch == "foreman/run-1"
  end

  test "reuses an existing open head/base PR after pushing head" do
    open_json = ~s([{"url":"https://github.com/acme/repo/pull/7","number":7}])
    {:ok, calls} = Agent.start_link(fn -> [] end)

    runner = fn
      executable, args, _opts ->
        Agent.update(calls, &[{executable, args} | &1])

        case {executable, args} do
          {"git", ["rev-list", "--count", _]} -> {"1\n", 0}
          {"git", ["push", "-u", "origin", "foreman/run-1"]} -> {"Everything up-to-date\n", 0}
          {"gh", ["pr", "list", "--state", "open" | _]} -> {open_json, 0}
        end
    end

    assert {:ok, record} = PhasePR.maybe_create(request(%{command_runner: runner}))
    assert record.status == "existing"
    assert record.pr_url == "https://github.com/acme/repo/pull/7"

    assert [{"git", ["push", "-u", "origin", "foreman/run-1"]}] =
             calls
             |> Agent.get(&Enum.reverse/1)
             |> Enum.filter(fn {executable, args} ->
               executable == "git" and Enum.take(args, 1) == ["push"]
             end)
  end

  test "three sequential stack PR phases push cumulative branch state" do
    {repo, remote} = git_fixture!()
    {:ok, gh_state} = Agent.start_link(fn -> %{open?: false} end)
    {:ok, pushes} = Agent.start_link(fn -> [] end)
    runner = git_runner_with_fake_gh(gh_state, pushes)

    Enum.each(1..3, fn index ->
      write_phase_commit!(repo, index)

      assert {:ok, record} =
               PhasePR.maybe_create(
                 request(%{
                   phase_id: "phase-#{index}",
                   phase_index: index,
                   phase_name: "phase-#{index}",
                   cwd: repo,
                   command_runner: runner
                 })
               )

      assert record.status in ["created", "existing"]
    end)

    assert Agent.get(pushes, &Enum.reverse/1) == [
             ["push", "-u", "origin", "foreman/run-1"],
             ["push", "-u", "origin", "foreman/run-1"],
             ["push", "-u", "origin", "foreman/run-1"]
           ]

    assert {"3\n", 0} =
             System.cmd("git", [
               "--git-dir",
               remote,
               "rev-list",
               "--count",
               "main..refs/heads/foreman/run-1"
             ])
  end

  test "closed matching PR is a typed error" do
    closed_json = ~s([{"url":"https://github.com/acme/repo/pull/8","number":8}])

    runner = fn
      "git", ["rev-list", "--count", _], _opts -> {"1\n", 0}
      "git", ["push", "-u", "origin", "foreman/run-1"], _opts -> {"", 0}
      "gh", ["pr", "list", "--state", "open" | _], _opts -> {"[]", 0}
      "gh", ["pr", "list", "--state", "closed" | _], _opts -> {closed_json, 0}
    end

    assert {:error, %PhasePR.Error{reason: :matching_pr_closed}} =
             PhasePR.maybe_create(request(%{command_runner: runner}))
  end

  test "missing head branch is typed" do
    assert {:error, %PhasePR.Error{reason: :phase_pr_head_branch_unresolved}} =
             PhasePR.maybe_create(request(%{head_branch: ""}))
  end

  defp runner_with_ahead(count) do
    fn
      "git", ["rev-list", "--count", _], _opts -> {"#{count}\n", 0}
    end
  end

  defp git_fixture! do
    root = Path.join(System.tmp_dir!(), "foreman-phase-pr-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    remote = Path.join(root, "remote.git")

    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    git!(root, ["init", "--bare", remote])
    git!(root, ["init", repo])
    git!(repo, ["config", "user.email", "foreman@example.com"])
    git!(repo, ["config", "user.name", "Foreman Test"])
    git!(repo, ["checkout", "-b", "main"])
    File.write!(Path.join(repo, "README.md"), "base\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "base"])
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["push", "-u", "origin", "main"])
    git!(repo, ["checkout", "-b", "foreman/run-1"])

    {repo, remote}
  end

  defp write_phase_commit!(repo, index) do
    path = Path.join(repo, "phase-#{index}.txt")
    File.write!(path, "phase #{index}\n")
    git!(repo, ["add", Path.basename(path)])
    git!(repo, ["commit", "-m", "phase #{index}"])
  end

  defp git_runner_with_fake_gh(gh_state, pushes) do
    fn
      "git", ["push" | _] = args, opts ->
        Agent.update(pushes, &[args | &1])
        System.cmd("git", args, opts)

      "git", args, opts ->
        System.cmd("git", args, opts)

      "gh", ["pr", "list", "--state", "open" | _], _opts ->
        if Agent.get(gh_state, & &1.open?) do
          {~s([{"url":"https://github.com/acme/repo/pull/7","number":7}]), 0}
        else
          {"[]", 0}
        end

      "gh", ["pr", "list", "--state", "closed" | _], _opts ->
        {"[]", 0}

      "gh", ["pr", "create" | _], _opts ->
        Agent.update(gh_state, &%{&1 | open?: true})
        {"https://github.com/acme/repo/pull/7\n", 0}
    end
  end

  defp git!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, exit_code} -> flunk("git #{Enum.join(args, " ")} failed (#{exit_code}): #{output}")
    end
  end

  defp runner("git", ["rev-list", "--count", _], _opts), do: {"1\n", 0}
  defp runner("gh", ["pr", "list", _state_flag, _state | _], _opts), do: {"[]", 0}
  defp runner("git", ["push", "-u", "origin", "foreman/run-1"], _opts), do: {"", 0}

  defp runner("gh", ["pr", "create" | _], _opts),
    do: {"https://github.com/acme/repo/pull/42\n", 0}
end
