defmodule ForemanServer.ForemanDirTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias ForemanServer.ForemanDir

  defp git!(dir, args), do: {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  defp ignored?(dir, path) do
    {_, status} = System.cmd("git", ["check-ignore", "-q", path], cd: dir, stderr_to_stdout: true)
    status == 0
  end

  test "creates .foreman/.gitignore with exactly the entry; memory is ignored, tracked files are not",
       %{tmp_dir: dir} do
    git!(dir, ["init", "-q"])
    File.mkdir_p!(Path.join(dir, ".foreman/memory"))

    for f <- ["Dockerfile", "bead.exs", "pi-models.json"],
        do: File.write!(Path.join(dir, ".foreman/#{f}"), "x")

    File.write!(Path.join(dir, ".foreman/memory/x.md"), "x")

    assert :ok = ForemanDir.ensure_ignored(dir, "memory/")

    assert File.read!(Path.join(dir, ".foreman/.gitignore")) == "memory/\n"
    assert ignored?(dir, ".foreman/memory/x.md")
    refute ignored?(dir, ".foreman/Dockerfile")
    refute ignored?(dir, ".foreman/bead.exs")
    refute ignored?(dir, ".foreman/pi-models.json")
  end

  test "is idempotent and preserves existing lines in order (also without trailing newline)",
       %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, ".foreman"))
    path = Path.join(dir, ".foreman/.gitignore")
    File.write!(path, "logs/\nstate/\nworktrees/\nruns/")

    assert :ok = ForemanDir.ensure_ignored(dir, "memory")
    first = File.read!(path)
    assert first == "logs/\nstate/\nworktrees/\nruns/\nmemory/\n"

    assert :ok = ForemanDir.ensure_ignored(dir, "memory/")
    assert File.read!(path) == first
  end

  test "unwritable location returns the typed error instead of raising", %{tmp_dir: dir} do
    File.write!(Path.join(dir, ".foreman"), "a file, not a directory")

    assert {:error, %ForemanDir.Error{code: :gitignore_write_failed}} =
             ForemanDir.ensure_ignored(dir, "memory/")
  end
end
