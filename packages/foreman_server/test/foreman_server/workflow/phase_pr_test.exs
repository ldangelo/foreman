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

  test "reuses an existing open head/base PR" do
    open_json = ~s([{"url":"https://github.com/acme/repo/pull/7","number":7}])

    runner = fn
      "git", ["rev-list", "--count", _], _opts -> {"1\n", 0}
      "gh", ["pr", "list", "--state", "open" | _], _opts -> {open_json, 0}
    end

    assert {:ok, record} = PhasePR.maybe_create(request(%{command_runner: runner}))
    assert record.status == "existing"
    assert record.pr_url == "https://github.com/acme/repo/pull/7"
  end

  test "closed matching PR is a typed error" do
    closed_json = ~s([{"url":"https://github.com/acme/repo/pull/8","number":8}])

    runner = fn
      "git", ["rev-list", "--count", _], _opts -> {"1\n", 0}
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

  defp runner("git", ["rev-list", "--count", _], _opts), do: {"1\n", 0}
  defp runner("gh", ["pr", "list", _state_flag, _state | _], _opts), do: {"[]", 0}
  defp runner("git", ["push", "-u", "origin", "foreman/run-1"], _opts), do: {"", 0}

  defp runner("gh", ["pr", "create" | _], _opts),
    do: {"https://github.com/acme/repo/pull/42\n", 0}
end
