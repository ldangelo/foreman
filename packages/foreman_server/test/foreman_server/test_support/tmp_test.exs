defmodule ForemanServer.TestSupport.TmpTest do
  # Not async: `capture_io(:stderr, ...)` swaps the global stderr device.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ForemanServer.TestSupport.Tmp

  @moduletag :tmp_dir

  # Trees holding read-only directories cannot be removed by ExUnit's own `tmp_dir` cleanup.
  setup %{tmp_dir: tmp_dir} do
    on_exit(fn -> System.cmd("chmod", ["-R", "u+rwx", tmp_dir]) end)
    :ok
  end

  # What a finished suite leaves in a VM directory: a Library entry exactly as
  # `ForemanServer.Library.Store` publishes it, files 0444 under directories 0555.
  defp read_only_entry!(root) do
    entry = Path.join([root, "overview-library-1", ".foreman", "library", "facts-abc"])
    files = Path.join(entry, "files")
    File.mkdir_p!(files)
    File.write!(Path.join(files, "facts.txt"), "the number is 7319")
    File.write!(Path.join(entry, "entry.json"), "{}")

    Enum.each(
      [Path.join(files, "facts.txt"), Path.join(entry, "entry.json")],
      &File.chmod!(&1, 0o444)
    )

    Enum.each([files, entry], &File.chmod!(&1, 0o555))
    entry
  end

  describe "claim_vm_dir!/1" do
    test "creates a new empty directory under base, named after this VM's pid", %{tmp_dir: base} do
      dir = Tmp.claim_vm_dir!(base)

      assert Path.dirname(dir) == base
      assert Path.basename(dir) =~ ~r/\Afm-test-#{System.pid()}-[0-9a-f]{8}\z/
      assert File.ls!(dir) == []
    end

    test "never returns the same directory twice", %{tmp_dir: base} do
      assert Tmp.claim_vm_dir!(base) != Tmp.claim_vm_dir!(base)
    end

    # The reported crash: an earlier VM with the same OS pid had left `fm-test-<pid>` behind
    # holding a read-only Library tree, and the old boot sequence's `File.rm_rf!/1` of that path
    # raised "file already exists" in test_helper.exs before any test ran.
    test "is not defeated by a leftover at the bare pid path", %{tmp_dir: base} do
      leftover = Path.join(base, "fm-test-#{System.pid()}")
      entry = read_only_entry!(leftover)

      # The premise: the old boot sequence cannot clear this path.
      assert_raise File.Error,
                   ~r/could not remove files and directories recursively.*file already exists/,
                   fn ->
                     File.rm_rf!(leftover)
                   end

      dir = Tmp.claim_vm_dir!(base)

      refute dir == leftover
      assert File.ls!(dir) == []
      assert File.dir?(entry), "the leftover is not this VM's to touch"
    end
  end

  describe "remove_tree/1" do
    test "deletes a tree with read-only directories that File.rm_rf/1 cannot", %{tmp_dir: base} do
      tree = Path.join(base, "leaked")
      read_only_entry!(tree)

      # The premise: plain rm_rf swallows the per-child :eacces and reports the root as :eexist.
      assert {:error, :eexist, ^tree} = File.rm_rf(tree)
      assert File.dir?(tree)

      assert Tmp.remove_tree(tree) == :ok
      refute File.exists?(tree)
    end

    test "deletes a plain file and an ordinary tree", %{tmp_dir: base} do
      file = Path.join(base, "file.txt")
      File.write!(file, "x")
      tree = Path.join([base, "tree", "nested"])
      File.mkdir_p!(tree)
      File.write!(Path.join(tree, "leaf"), "y")

      assert Tmp.remove_tree(file) == :ok
      assert Tmp.remove_tree(Path.join(base, "tree")) == :ok
      refute File.exists?(file)
      refute File.exists?(Path.join(base, "tree"))
    end

    test "a path that is already gone is not a failure", %{tmp_dir: base} do
      assert Tmp.remove_tree(Path.join(base, "never-existed")) == :ok
    end

    test "removes symlinks without following them", %{tmp_dir: base} do
      outside = Path.join(base, "outside")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "keep"), "precious")
      File.chmod!(outside, 0o555)

      tree = Path.join(base, "tree")
      File.mkdir_p!(tree)
      :ok = File.ln_s(outside, Path.join(tree, "link"))

      assert Tmp.remove_tree(tree) == :ok

      refute File.exists?(tree)
      assert File.read!(Path.join(outside, "keep")) == "precious"

      assert Bitwise.band(File.stat!(outside).mode, 0o777) == 0o555,
             "chmod must not follow the link"
    end

    test "returns any errno other than :enoent with its path instead of swallowing it", %{
      tmp_dir: base
    } do
      file = Path.join(base, "plain-file")
      File.write!(file, "x")
      below_a_file = Path.join(file, "child")

      assert Tmp.remove_tree(below_a_file) == {:error, [{:enotdir, below_a_file}]}
      assert File.read!(file) == "x"
    end
  end

  describe "release_vm_dir/1" do
    test "removes the directory, read-only entries included, and prints nothing", %{tmp_dir: base} do
      dir = Tmp.claim_vm_dir!(base)
      read_only_entry!(dir)

      stderr = capture_io(:stderr, fn -> assert Tmp.release_vm_dir(dir) == :ok end)

      refute File.exists?(dir)
      assert stderr == ""
    end

    test "does not raise when something cannot be removed, but names it on stderr", %{
      tmp_dir: base
    } do
      file = Path.join(base, "plain-file")
      File.write!(file, "x")
      below_a_file = Path.join(file, "child")

      stderr = capture_io(:stderr, fn -> assert Tmp.release_vm_dir(below_a_file) == :ok end)

      assert stderr =~ "could not remove the test VM directory #{below_a_file}"
      assert stderr =~ "enotdir  #{below_a_file}"
    end
  end
end
