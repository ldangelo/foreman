defmodule ForemanServer.TestSupport.Tmp do
  @moduledoc """
  Scratch-directory helpers for the test VM (`test/test_helper.exs`).

  `claim_vm_dir!/1` creates the private directory a VM points `TMPDIR` at, `release_vm_dir/1`
  removes it when the suite ends, and `remove_tree/1` is the deletion both use. Tests that
  build trees holding read-only directories can call it as their cleanup.

  ## Why the VM directory is created, never cleared

  The directory used to be `<tmp>/fm-test-<os pid>`, cleared with `File.rm_rf!/1` at boot. An
  OS pid is reused within minutes on a busy host, so that path often already existed as the
  leftover of an earlier VM, and clearing it raised

      could not remove files and directories recursively from ".../fm-test-<pid>": file already exists

  in `test_helper.exs`, before a single test ran. Every full suite left such a leftover: the
  Library publishes entries read-only (directories 0555, files 0444), and `File.rm_rf/1`
  cannot delete those. It swallows each child's `:eacces` and reports only that the final
  `rmdir` of the root found it non-empty, which Erlang names `:eexist` ("file already
  exists"). Neither the test that created the entry nor the `after_suite` cleanup looked at
  that result, so the tree stayed behind.

  `claim_vm_dir!/1` therefore never inspects an existing path: the name carries a random
  suffix and the directory is made with an exclusive `File.mkdir!/1`, so a leftover of any
  origin (read-only tree, killed VM, reused pid) cannot collide with it. `remove_tree/1`
  makes every directory it enters writable first and returns whatever it still cannot remove.
  """

  @typedoc "An entry that could not be removed: the posix reason and the path it concerns."
  @type failure :: {File.posix(), Path.t()}

  @doc """
  Creates a new, empty directory directly under `base` and returns its path.

  The name is `fm-test-<os pid>-<random>`. The pid tells whoever finds a leftover which VM it
  belonged to; the suffix makes the name unique even when the pid is reused. The directory is
  created exclusively, so it can never be a pre-existing path, and any failure (`base` missing
  or unwritable, or the impossible name clash) raises `File.Error`.
  """
  @spec claim_vm_dir!(Path.t()) :: Path.t()
  def claim_vm_dir!(base) do
    path = Path.join(base, "fm-test-#{System.pid()}-#{random_suffix()}")
    File.mkdir!(path)
    path
  end

  @doc """
  Removes a VM directory for `ExUnit.after_suite/1` and returns `:ok`.

  A suite that passed must not crash at exit over its scratch space, so this never raises. It
  is not silent either: every entry `remove_tree/1` could not remove is written to stderr with
  its path and errno.
  """
  @spec release_vm_dir(Path.t()) :: :ok
  def release_vm_dir(path) do
    case remove_tree(path) do
      :ok ->
        :ok

      {:error, failures} ->
        lines = Enum.map(failures, fn {reason, file} -> "  #{reason}  #{file}" end)

        IO.puts(
          :stderr,
          Enum.join(["could not remove the test VM directory #{path}:" | lines], "\n")
        )
    end
  end

  @doc """
  Removes the file or directory tree at `path`, including trees `File.rm_rf/1` cannot delete.

  Every directory is made owner-accessible (`0700`) before it is read, so read-only
  directories (the Library's 0555 entries) do not stop the walk. Symlinks are removed, never
  followed. An entry that is already gone is not a failure: something else removed it first and
  the goal is met, so `:enoent` is the one errno tolerated. Every other error is returned with
  its path and reason, and the rest of the tree is still removed.
  """
  @spec remove_tree(Path.t()) :: :ok | {:error, [failure(), ...]}
  def remove_tree(path) do
    case remove_entry(path) do
      [] -> :ok
      failures -> {:error, failures}
    end
  end

  defp remove_entry(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> remove_dir(path)
      {:ok, _file_or_symlink} -> settle(File.rm(path), path)
      {:error, _reason} = error -> settle(error, path)
    end
  end

  defp remove_dir(path) do
    with :ok <- File.chmod(path, 0o700),
         {:ok, names} <- :file.list_dir_all(path) do
      case Enum.flat_map(names, &remove_entry(Path.join(path, &1))) do
        # `rmdir` of a directory that still holds an entry we failed to remove would only add a
        # derived `:eexist` for it; the failure that matters is the child's.
        [] -> settle(File.rmdir(path), path)
        failures -> failures
      end
    else
      {:error, _reason} = error -> settle(error, path)
    end
  end

  defp settle(:ok, _path), do: []
  defp settle({:error, :enoent}, _path), do: []
  defp settle({:error, reason}, path), do: [{reason, path}]

  defp random_suffix, do: 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
