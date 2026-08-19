defmodule ForemanServer.Actions.GitStatusActionE2ETest do
  @moduledoc """
  ADT-T002 — Representative action E2E run for `GitStatusAction`.

  Per TRD-2026-4212be7e / ADT-T002 / TRD-084. Exercises the full
  Jido.Action contract end-to-end against a real (per-test, tmp) git
  working tree: clean → dirty → reset. Mirrors the plan in
  `docs/ADT/representative-action-run.md`.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Actions.GitStatusAction

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "adt_t002_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    {_, 0} = System.cmd("git", ["init", tmp])
    {_, 0} = System.cmd("git", ["-C", tmp, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", tmp, "config", "user.name", "Test User"])
    File.write!(Path.join(tmp, "README.md"), "init")
    {_, 0} = System.cmd("git", ["-C", tmp, "add", "README.md"])
    {_, 0} = System.cmd("git", ["-C", tmp, "commit", "-m", "initial"])

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, path: tmp}
  end

  test "clean repo reports empty porcelain + exit_code 0", %{path: path} do
    assert {:ok, %{porcelain: [], exit_code: 0}} =
             GitStatusAction.run(%{path: path}, %{})
  end

  test "dirty repo (new untracked file) appears in porcelain", %{path: path} do
    File.write!(Path.join(path, "new_file.txt"), "untracked")

    assert {:ok, %{porcelain: porcelain, exit_code: 0}} =
             GitStatusAction.run(%{path: path}, %{})

    assert porcelain != []
    assert Enum.any?(porcelain, &String.contains?(&1, "new_file.txt"))
  end

  test "non-repo path returns :not_a_git_repo error" do
    tmp = Path.join(System.tmp_dir!(), "not_a_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    assert {:error, :not_a_git_repo} = GitStatusAction.run(%{path: tmp}, %{})
  end
end
