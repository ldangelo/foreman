defmodule ForemanServer.RunArtifactsArchiveTest do
  @moduledoc """
  The report archive of `ForemanServer.RunArtifacts`: the one path it lives at, the writer
  (`archive/5`) that keeps only bytes matching the recorded digest, the warning every caller of
  the writer shares, and the traversal guard on the run id.

  Scratch space only: `HOME` points at a per-test directory, so the root the server's own reader
  resolves (`RunExecutor.artifact_base/0`) is under it too and nothing touches `~/.foreman`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.RunArtifacts
  alias ForemanServer.RunArtifacts.UnsafeRunId
  alias ForemanServer.Workflow.RunExecutor

  @moduletag :tmp_dir

  @run_id "run-archive-0123456789abcdef"

  setup %{tmp_dir: dir} do
    previous = System.get_env("HOME")
    System.put_env("HOME", Path.join(dir, "home"))

    on_exit(fn ->
      if previous == nil, do: System.delete_env("HOME"), else: System.put_env("HOME", previous)
    end)

    %{base: RunExecutor.artifact_base()}
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp report!(dir, name, bytes) do
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end

  # Every name the archive directory holds, temporary files included.
  defp archive_files(base, run_id, index) do
    dir = Path.dirname(RunArtifacts.archive_path(base, run_id, index))

    case File.ls(dir) do
      {:ok, names} -> Enum.sort(names)
      {:error, :enoent} -> []
    end
  end

  describe "archive_path/3" do
    test "is <artifact_base>/<run_id>/archive/phase-<index>.md", %{base: base, tmp_dir: dir} do
      assert RunArtifacts.archive_path("/runs", "run-1", 3) == "/runs/run-1/archive/phase-3.md"

      assert RunArtifacts.archive_path(base, @run_id, 1) ==
               Path.join([base, @run_id, "archive", "phase-1.md"])

      # The server's own root: what the executor's state and the HTTP reader both start from.
      assert base == Path.join([dir, "home", ".foreman", "runs"])
    end

    test "only an integer index names the file", %{base: base} do
      for index <- ["../x", "1", nil, 1.0] do
        assert_raise FunctionClauseError, fn ->
          RunArtifacts.archive_path(base, @run_id, index)
        end
      end
    end

    test "a run id that cannot be a directory name raises and builds no path", %{base: base} do
      for id <- ["", ".", "..", "../x", "a/b", "a\\b", "/abs", "..\\x", "x\0y", "x\ny", "x\x7Fy"] do
        assert_raise UnsafeRunId, ~r/cannot name an archive directory/, fn ->
          RunArtifacts.archive_path(base, id, 1)
        end
      end
    end

    test "a run id that merely contains dots is a directory name like any other", %{base: base} do
      assert RunArtifacts.archive_path(base, "run..x", 1) ==
               Path.join([base, "run..x", "archive", "phase-1.md"])
    end
  end

  describe "archive/5" do
    test "keeps exactly the recorded bytes, in one file, whatever their shape", ctx do
      %{base: base, tmp_dir: dir} = ctx
      # Not UTF-8, not line-oriented, and longer than three read chunks.
      bytes = for i <- 0..200_000, into: <<>>, do: <<rem(i * 31, 256)>>
      recorded = report!(dir, "report.md", bytes)

      assert {:ok, dest} = RunArtifacts.archive(base, @run_id, 2, recorded, sha(bytes))

      assert dest == RunArtifacts.archive_path(base, @run_id, 2)
      assert File.read!(dest) == bytes
      assert archive_files(base, @run_id, 2) == ["phase-2.md"]
      # The recorded file is only read.
      assert File.read!(recorded) == bytes
    end

    test "keeps an empty report as an empty file", %{base: base, tmp_dir: dir} do
      recorded = report!(dir, "empty.md", "")

      assert {:ok, dest} = RunArtifacts.archive(base, @run_id, 1, recorded, sha(""))
      assert File.read!(dest) == ""
    end

    test "compares the recorded digest case-insensitively", %{base: base, tmp_dir: dir} do
      recorded = report!(dir, "report.md", "report")

      assert {:ok, _} =
               RunArtifacts.archive(base, @run_id, 1, recorded, String.upcase(sha("report")))
    end

    test "a retry of the same phase replaces the earlier copy whole", %{base: base, tmp_dir: dir} do
      first = report!(dir, "first.md", "attempt one")
      assert {:ok, dest} = RunArtifacts.archive(base, @run_id, 1, first, sha("attempt one"))

      second_bytes = "attempt two, a longer report"
      second = report!(dir, "second.md", second_bytes)
      assert {:ok, ^dest} = RunArtifacts.archive(base, @run_id, 1, second, sha(second_bytes))

      assert File.read!(dest) == second_bytes
      assert archive_files(base, @run_id, 1) == ["phase-1.md"]
    end

    test "bytes that do not hash to the recorded digest are not archived", ctx do
      %{base: base, tmp_dir: dir} = ctx
      recorded = report!(dir, "report.md", "edited after the phase finished")
      expected = sha("what the phase wrote")
      actual = sha("edited after the phase finished")

      assert {:error, {:sha_mismatch, ^expected, ^actual}} =
               RunArtifacts.archive(base, @run_id, 1, recorded, expected)

      refute File.exists?(RunArtifacts.archive_path(base, @run_id, 1))
      assert archive_files(base, @run_id, 1) == []
    end

    test "a mismatch leaves the copy of an earlier attempt untouched", %{base: base, tmp_dir: dir} do
      good = report!(dir, "good.md", "the good report")
      assert {:ok, dest} = RunArtifacts.archive(base, @run_id, 1, good, sha("the good report"))

      drifted = report!(dir, "drifted.md", "something else")

      assert {:error, {:sha_mismatch, _, _}} =
               RunArtifacts.archive(base, @run_id, 1, drifted, sha("the next report"))

      assert File.read!(dest) == "the good report"
      assert archive_files(base, @run_id, 1) == ["phase-1.md"]
    end

    test "a recorded file that is gone is :recorded_missing and creates nothing", ctx do
      %{base: base, tmp_dir: dir} = ctx

      assert {:error, :recorded_missing} =
               RunArtifacts.archive(base, @run_id, 1, Path.join(dir, "gone.md"), sha("x"))

      refute File.exists?(Path.join(base, @run_id))
    end

    test "a recorded path that cannot be read is :recorded_unreadable with the posix reason",
         ctx do
      %{base: base, tmp_dir: dir} = ctx

      # A directory is not a report.
      assert {:error, {:recorded_unreadable, :eisdir}} =
               RunArtifacts.archive(base, @run_id, 1, dir, sha("x"))

      refute File.exists?(Path.join(base, @run_id))
    end

    test "an artifact base that cannot hold the archive is :archive_unwritable", ctx do
      %{tmp_dir: dir} = ctx
      # A regular file where the artifact base should be a directory.
      blocker = report!(dir, "not-a-directory", "a file")
      recorded = report!(dir, "report.md", "report")

      assert {:error, {:archive_unwritable, reason}} =
               RunArtifacts.archive(blocker, @run_id, 1, recorded, sha("report"))

      assert reason in [:enotdir, :eexist]
      assert File.read!(recorded) == "report"
    end

    test "a copy that cannot be put in place leaves no temporary file behind", ctx do
      %{base: base, tmp_dir: dir} = ctx
      # A directory where the archive file belongs: the rename over it fails.
      File.mkdir_p!(RunArtifacts.archive_path(base, @run_id, 1))
      recorded = report!(dir, "report.md", "report")

      assert {:error, {:archive_unwritable, _}} =
               RunArtifacts.archive(base, @run_id, 1, recorded, sha("report"))

      assert archive_files(base, @run_id, 1) == ["phase-1.md"]
      assert File.dir?(RunArtifacts.archive_path(base, @run_id, 1))
    end

    test "a report already inside the archive directory is not copied onto itself", ctx do
      %{base: base} = ctx
      dest = RunArtifacts.archive_path(base, @run_id, 1)
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, "kept")
      sibling = Path.join(Path.dirname(dest), "phase-9.md")
      File.write!(sibling, "also kept")

      assert :in_archive = RunArtifacts.archive(base, @run_id, 1, dest, sha("kept"))
      assert :in_archive = RunArtifacts.archive(base, @run_id, 1, sibling, sha("also kept"))

      # The same place under another spelling.
      detour = Path.join([Path.dirname(dest), "..", "archive", "phase-1.md"])
      assert :in_archive = RunArtifacts.archive(base, @run_id, 1, detour, sha("kept"))

      assert File.read!(dest) == "kept"
      assert archive_files(base, @run_id, 1) == ["phase-1.md", "phase-9.md"]
    end

    test "a directory that only shares the archive's name prefix is not the archive", ctx do
      %{base: base} = ctx
      lookalike = Path.join([base, @run_id, "archive-notes"])
      File.mkdir_p!(lookalike)
      recorded = report!(lookalike, "phase-1.md", "report")

      assert {:ok, dest} = RunArtifacts.archive(base, @run_id, 1, recorded, sha("report"))
      assert File.read!(dest) == "report"
    end

    test "a hostile run id cannot make the writer touch anything outside the run's directory",
         %{base: base, tmp_dir: dir} do
      recorded = report!(dir, "report.md", "report")

      # `base` is <dir>/home/.foreman/runs: three levels up is the scratch directory itself.
      for id <- ["../../../outside", "../../../outside/x", "..", "a/../../../../outside"] do
        assert_raise UnsafeRunId, fn ->
          RunArtifacts.archive(base, id, 1, recorded, sha("report"))
        end
      end

      refute File.exists?(Path.join(dir, "outside"))
      assert File.ls!(dir) == ["report.md"]
    end
  end

  describe "warn_not_archived/4" do
    defp warning(reason) do
      capture_log([level: :warning], fn ->
        assert :ok = RunArtifacts.warn_not_archived("run-a", 3, "/w/docs/report.md", reason)
      end)
    end

    test "names the run, the phase, the path and the reason" do
      log = warning({:archive_unwritable, :enotdir})

      assert log =~ "run run-a phase 3"
      assert log =~ "/w/docs/report.md"
      assert log =~ "was not archived"
      assert log =~ "enotdir"
    end

    test "names both hashes of a digest mismatch" do
      expected = sha("what the phase wrote")
      actual = sha("what is there now")
      log = warning({:sha_mismatch, expected, actual})

      assert log =~ expected
      assert log =~ actual
    end

    test "says why for every other reason archive/5 returns" do
      assert warning(:recorded_missing) =~ "does not exist"
      assert warning({:recorded_unreadable, :eacces}) =~ "eacces"
    end
  end

  describe "read/3" do
    defp phase(run_id, path, sha256) do
      %{
        phase_id: "#{run_id}-p001",
        index: 1,
        name: "fix",
        attempt: 1,
        status: "completed",
        artifact: %{path: path, sha256: sha256, bytes: 1}
      }
    end

    test "a run id that cannot be a directory name raises instead of looking outside the archive",
         %{tmp_dir: dir} do
      # What a traversal out of <dir>/home/.foreman/runs would reach: <dir>/outside/archive/phase-1.md
      secret = Path.join([dir, "outside", "archive", "phase-1.md"])
      File.mkdir_p!(Path.dirname(secret))
      File.write!(secret, "do not serve")

      hostile = "../../../outside"
      p = phase(hostile, Path.join(dir, "gone.md"), sha("do not serve"))

      assert_raise UnsafeRunId, fn -> RunArtifacts.read(hostile, p.phase_id, [p]) end
    end
  end
end
