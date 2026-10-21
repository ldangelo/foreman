defmodule ForemanServer.Library.StoreTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias ForemanServer.Library.{Error, Ingest, Store}

  setup %{tmp_dir: dir} do
    # Read-only trees cannot be removed by ExUnit's tmp_dir cleanup.
    on_exit(fn -> System.cmd("chmod", ["-R", "u+w", dir]) end)
    root = Store.root(Path.join(dir, "repo"))
    File.mkdir_p!(root)
    src = Path.join(dir, "src")
    File.mkdir_p!(Path.join(src, "sub"))
    File.write!(Path.join(src, "a.txt"), "alpha")
    File.write!(Path.join(src, "sub/b.txt"), "bravo")
    {:ok, root: root, src: src, dir: dir}
  end

  defp plan!(src, opts \\ []) do
    {:ok, plan} = Ingest.plan({:folder, src}, [name: "docs"] ++ opts)
    plan
  end

  test "write copies files, records sha256/bytes and a stable manifest digest", %{
    root: root,
    src: src
  } do
    {:ok, entry, pending} = Store.write(root, "docs-1", plan!(src))
    :ok = Store.commit(pending)

    expected = :crypto.hash(:sha256, "alpha") |> Base.encode16(case: :lower)
    assert %{path: "a.txt", bytes: 5, sha256: ^expected} = hd(entry.files)
    assert File.read!(Path.join(Store.files_dir(root, "docs-1"), "sub/b.txt")) == "bravo"

    assert {:ok, read_back} = Store.read_entry(root, "docs-1")
    assert read_back.manifest_sha256 == entry.manifest_sha256
    assert read_back.files == entry.files
  end

  test "files are 0444 and directories 0555 after write", %{root: root, src: src} do
    {:ok, _entry, pending} = Store.write(root, "docs-1", plan!(src))
    :ok = Store.commit(pending)

    mode = fn path -> Bitwise.band(File.stat!(path).mode, 0o777) end
    files = Store.files_dir(root, "docs-1")
    assert mode.(Path.join(files, "a.txt")) == 0o444
    assert mode.(Path.join(files, "sub")) == 0o555
    assert mode.(Path.join(root, "docs-1")) == 0o555
  end

  test "replace swaps atomically: a reader sees the old or the new entry, and commit removes the trash",
       %{root: root, src: src, dir: dir} do
    {:ok, first, p1} = Store.write(root, "docs-1", plan!(src))
    :ok = Store.commit(p1)

    File.write!(Path.join(src, "a.txt"), "changed")
    {:ok, second, p2} = Store.write(root, "docs-1", plan!(src), replace?: true)

    assert second.created_at == first.created_at
    assert second.replaced_at
    assert second.manifest_sha256 != first.manifest_sha256
    assert {:ok, "changed"} = Store.read_file(root, "docs-1", "a.txt", 100)
    assert [trash] = Enum.filter(File.ls!(root), &String.starts_with?(&1, ".trash-"))

    :ok = Store.commit(p2)
    assert File.ls!(root) == ["docs-1"]
    refute File.exists?(Path.join(root, trash))
    _ = dir
  end

  test "rollback of a replace restores the old entry and removes the new one", %{
    root: root,
    src: src
  } do
    {:ok, first, p1} = Store.write(root, "docs-1", plan!(src))
    :ok = Store.commit(p1)

    File.write!(Path.join(src, "a.txt"), "changed")
    {:ok, _second, p2} = Store.write(root, "docs-1", plan!(src), replace?: true)
    :ok = Store.rollback(p2)

    assert {:ok, restored} = Store.read_entry(root, "docs-1")
    assert restored.manifest_sha256 == first.manifest_sha256
    assert {:ok, "alpha"} = Store.read_file(root, "docs-1", "a.txt", 100)
    assert File.ls!(root) == ["docs-1"]
  end

  test "rollback of a first write leaves nothing behind", %{root: root, src: src} do
    {:ok, _entry, pending} = Store.write(root, "docs-1", plan!(src))
    :ok = Store.rollback(pending)
    assert File.ls!(root) == []
    assert {:ok, []} = Store.list(root)
  end

  test "remove moves the entry aside; commit deletes it, rollback restores it", %{
    root: root,
    src: src
  } do
    {:ok, _e, p} = Store.write(root, "docs-1", plan!(src))
    :ok = Store.commit(p)

    {:ok, _entry, rm} = Store.remove(root, "docs-1")
    assert {:ok, []} = Store.list(root)
    :ok = Store.rollback(rm)
    assert {:ok, [%{entry_id: "docs-1"}]} = Store.list(root)

    {:ok, _entry, rm2} = Store.remove(root, "docs-1")
    :ok = Store.commit(rm2)
    assert File.ls!(root) == []
    assert {:error, %Error{code: :not_found}} = Store.remove(root, "docs-1")
  end

  test "a failed copy leaves no staging directory and no entry", %{root: root, src: src} do
    plan = plan!(src)
    File.rm!(Path.join(src, "sub/b.txt"))

    assert {:error, %Error{code: :write_failed}} = Store.write(root, "docs-1", plan)
    assert File.ls!(root) == []
  end

  test "list ignores staging/trash directories and sorts by name", %{root: root, src: src} do
    for {id, name} <- [{"z-1", "zeta"}, {"a-1", "alpha"}] do
      {:ok, plan} = Ingest.plan({:folder, src}, name: name)
      {:ok, _e, p} = Store.write(root, id, plan)
      :ok = Store.commit(p)
    end

    File.mkdir_p!(Path.join(root, ".staging-abc"))
    assert {:ok, entries} = Store.list(root)
    assert Enum.map(entries, & &1.name) == ["alpha", "zeta"]
  end

  test "sweep deletes only orphans older than the cutoff", %{root: root} do
    old = Path.join(root, ".staging-old")
    fresh = Path.join(root, ".trash-fresh")
    File.mkdir_p!(Path.join(old, "files"))
    File.mkdir_p!(fresh)
    File.write!(Path.join(old, "files/x"), "x")
    File.chmod!(Path.join(old, "files"), 0o555)
    past = System.os_time(:second) - 7_200
    {{y, m, d}, {h, mi, s}} = :calendar.system_time_to_universal_time(past, :second)
    File.touch!(old, {{y, m, d}, {h, mi, s}})

    :ok = Store.sweep(root, 3_600)
    refute File.exists?(old)
    assert File.exists?(fresh)
  end

  test "a symlink inside an entry that points outside is never readable", %{
    root: root,
    src: src,
    dir: dir
  } do
    {:ok, _e, p} = Store.write(root, "docs-1", plan!(src))
    :ok = Store.commit(p)

    secret = Path.join(dir, "secret.txt")
    File.write!(secret, "TOP-SECRET")
    files = Store.files_dir(root, "docs-1")
    File.chmod!(files, 0o755)
    File.ln_s!(secret, Path.join(files, "escape.txt"))

    assert {:error, %Error{code: :not_found}} = Store.read_file(root, "docs-1", "escape.txt", 100)
  end

  test "read_file enforces the byte cap and refuses traversal and unknown ids", %{
    root: root,
    src: src
  } do
    {:ok, _e, p} = Store.write(root, "docs-1", plan!(src))
    :ok = Store.commit(p)

    assert {:error, %Error{code: :too_large, details: %{bytes: 5, max: 4}}} =
             Store.read_file(root, "docs-1", "a.txt", 4)

    assert {:error, %Error{code: :path_invalid}} =
             Store.read_file(root, "docs-1", "../entry.json", 100)

    assert {:error, %Error{code: :not_found}} = Store.read_file(root, "../docs-1", "a.txt", 100)

    assert {:error, %Error{code: :not_found}} =
             Store.read_file(root, "docs-1", "missing.txt", 100)

    assert {:error, %Error{code: :not_found}} = Store.read_file(root, "docs-1", "sub", 100)
  end

  describe "gitignore" do
    test "ignores .foreman/library/ and nothing else under .foreman", %{dir: dir} do
      repo = Path.join(dir, "gitrepo")
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "-q", repo])
      :ok = Store.ensure_ready(repo)
      :ok = Store.ensure_ready(repo)

      ignored? = fn path ->
        {_out, code} = System.cmd("git", ["-C", repo, "check-ignore", "-q", path])
        code == 0
      end

      assert ignored?.(".foreman/library/x/entry.json")
      assert ignored?.(".foreman/library/")

      for tracked <- [".foreman/Dockerfile", ".foreman/bead.exs", ".foreman/pi-models.json"] do
        refute ignored?.(tracked), "#{tracked} must stay tracked"
      end

      lines = File.read!(Path.join(repo, ".foreman/.gitignore")) |> String.split("\n", trim: true)
      assert Enum.count(lines, &(&1 == "library/")) == 1
    end
  end
end
