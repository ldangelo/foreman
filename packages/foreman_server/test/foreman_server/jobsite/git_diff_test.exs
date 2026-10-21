defmodule ForemanServer.Jobsite.GitDiffTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias ForemanServer.Jobsite.Error
  alias ForemanServer.Jobsite.Git

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    String.trim(out)
  end

  setup %{tmp_dir: tmp} do
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q"])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "a.txt"), "one\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "first"])
    base = git!(repo, ["rev-parse", "HEAD"])

    File.write!(Path.join(repo, "a.txt"), "one\ntwo\n")
    File.write!(Path.join(repo, "b.txt"), "new\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "second"])

    {:ok, repo: repo, base: base}
  end

  test "diff/3 returns the unified diff of base..head", %{repo: repo, base: base} do
    assert {:ok, diff} = Git.diff(repo, base, "HEAD")
    assert diff =~ "+two"
    assert diff =~ "b/b.txt"
  end

  test "changed_files/3 returns name-status lines", %{repo: repo, base: base} do
    assert {:ok, out} = Git.changed_files(repo, base, "HEAD")
    assert String.split(out, "\n", trim: true) |> Enum.sort() == ["A\tb.txt", "M\ta.txt"]
  end

  test "an empty range yields an empty diff", %{repo: repo} do
    assert {:ok, ""} = Git.diff(repo, "HEAD", "HEAD")
  end

  test "a git failure is an error, not empty output", %{repo: repo} do
    assert {:error, %Error{code: :git_failed}} = Git.diff(repo, "no-such-ref", "HEAD")
  end

  test "option-like and malformed refs are rejected before git runs", %{repo: repo, tmp_dir: tmp} do
    target = Path.join(tmp, "pwned")

    for bad <- ["--upload-pack=evil", "--output=" <> target, "", "a b", "a\nb", "a\0b"] do
      assert {:error, %Error{code: :git_failed, message: "unsafe git ref rejected"}} =
               Git.diff(repo, bad, "HEAD")

      assert {:error, %Error{message: "unsafe git ref rejected"}} =
               Git.changed_files(repo, "HEAD", bad)
    end

    refute File.exists?(target)
  end

  describe ":worktree head" do
    setup %{repo: repo} do
      File.write!(Path.join(repo, "a.txt"), "one\ntwo\nuncommitted edit\n")
      File.write!(Path.join(repo, "untracked.txt"), "never added\n")
      :ok
    end

    test "diff/3 includes uncommitted tracked changes and, once marked, new untracked files",
         %{repo: repo, base: base} do
      assert :ok = Git.mark_intent_to_add(repo)
      assert {:ok, diff} = Git.diff(repo, base, :worktree)
      assert diff =~ "+uncommitted edit"
      assert diff =~ "b/untracked.txt"
      assert diff =~ "+never added"
      # Committed work after the base is part of the working-tree diff too.
      assert diff =~ "+two"
      assert diff =~ "b/b.txt"
    end

    test "changed_files/3 includes uncommitted tracked changes and, once marked, new untracked files",
         %{repo: repo, base: base} do
      assert :ok = Git.mark_intent_to_add(repo)
      assert {:ok, out} = Git.changed_files(repo, base, :worktree)

      assert String.split(out, "\n", trim: true) |> Enum.sort() ==
               ["A\tb.txt", "A\tuntracked.txt", "M\ta.txt"]

      # Without the uncommitted edit the committed-head diff cannot show it.
      assert {:ok, committed} = Git.diff(repo, base, "HEAD")
      refute committed =~ "uncommitted edit"
      refute committed =~ "untracked.txt"
    end

    test "diff/3 and changed_files/3 only read: a new file stays out until it is marked",
         %{repo: repo, base: base} do
      assert {:ok, diff} = Git.diff(repo, base, :worktree)
      assert diff =~ "+uncommitted edit"
      refute diff =~ "untracked.txt"

      assert {:ok, out} = Git.changed_files(repo, base, :worktree)
      refute out =~ "untracked.txt"

      # Neither call touched the index: the file is still plainly untracked.
      assert git!(repo, ["status", "--porcelain"]) =~ "?? untracked.txt"

      assert :ok = Git.mark_intent_to_add(repo)
      assert git!(repo, ["status", "--porcelain"]) =~ "A untracked.txt"
      assert {:ok, marked} = Git.diff(repo, base, :worktree)
      assert marked =~ "+never added"
    end

    test "gitignored files are not included", %{repo: repo, base: base} do
      File.write!(Path.join(repo, ".gitignore"), "*.log\n")
      File.write!(Path.join(repo, "build-noise.log"), "build noise\n")

      assert :ok = Git.mark_intent_to_add(repo)
      assert {:ok, diff} = Git.diff(repo, base, :worktree)
      assert diff =~ "+never added"
      refute diff =~ "build-noise.log"
      refute diff =~ "build noise"

      assert {:ok, out} = Git.changed_files(repo, base, :worktree)
      refute out =~ "build-noise.log"
    end

    test "mark_intent_to_add/1 is a typed error when the index cannot be written; the diff still reads tracked changes",
         %{repo: repo, base: base} do
      lock = Path.join([repo, ".git", "index.lock"])
      File.write!(lock, "")

      assert {:error, %Error{code: :git_failed, details: %{reason: reason}}} =
               Git.mark_intent_to_add(repo)

      assert reason =~ "index.lock"

      # Tracked changes stay readable while the index is locked; only new files are missing.
      assert {:ok, diff} = Git.diff(repo, base, :worktree)
      assert diff =~ "+uncommitted edit"
      refute diff =~ "untracked.txt"

      File.rm!(lock)
      assert :ok = Git.mark_intent_to_add(repo)
    end

    test "a git failure is an error, not empty output", %{repo: repo} do
      assert {:error, %Error{code: :git_failed}} = Git.diff(repo, "no-such-ref", :worktree)
    end

    test "an option-like base is rejected before git runs", %{repo: repo, tmp_dir: tmp} do
      target = Path.join(tmp, "pwned-worktree")

      for bad <- ["--upload-pack=evil", "--output=" <> target, "", "a b"] do
        assert {:error, %Error{code: :git_failed, message: "unsafe git ref rejected"}} =
                 Git.diff(repo, bad, :worktree)

        assert {:error, %Error{message: "unsafe git ref rejected"}} =
                 Git.changed_files(repo, bad, :worktree)
      end

      refute File.exists?(target)
    end
  end
end
