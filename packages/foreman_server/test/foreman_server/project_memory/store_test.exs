defmodule ForemanServer.ProjectMemory.StoreTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias ForemanServer.Identity
  alias ForemanServer.ProjectMemory.{Error, Store}

  defp write(dir, name, content, description \\ "hook"),
    do: Store.write(dir, [], %{name: name, description: description, content: content})

  defp mem(dir), do: Path.join(dir, ".foreman/memory")

  # Bring a project to `count` topics (`<prefix>1..count`) with one real `Store.write` plus
  # byte-for-byte copies of the file it produced, so the on-disk format is the store's own.
  # Filling the caps through `count` real writes is quadratic (each write re-reads every
  # topic) and ran past the 60 s test timeout on a CPU-starved machine; the caps are checked
  # against what is on disk, so this exercises them identically. The index is regenerated
  # from the files by the next real write.
  defp seed_topics(dir, prefix, count, content, description) do
    first = "#{prefix}1"
    assert {:ok, _} = write(dir, first, content, description)
    raw = File.read!(Path.join(mem(dir), "#{first}.md"))
    for i <- 2..count, do: File.write!(Path.join(mem(dir), "#{prefix}#{i}.md"), raw)
    :ok
  end

  defp snapshot(dir) do
    case File.ls(mem(dir)) do
      {:ok, files} -> Map.new(files, &{&1, File.read!(Path.join(mem(dir), &1))})
      {:error, :enoent} -> %{}
    end
  end

  test "invalid names are rejected with :name_invalid and nothing is written", %{tmp_dir: dir} do
    for name <- [
          "../x.md",
          "MEMORY.md",
          "a/b.md",
          "UPPER.md",
          "x.txt",
          String.duplicate("a", 65),
          "memory",
          ""
        ] do
      assert {:error, %Error{code: :name_invalid}} = write(dir, name, "x")
    end

    assert snapshot(dir) == %{}
    assert {:ok, _} = write(dir, String.duplicate("a", 64), "ok")
  end

  test "content over 64 KiB is :content_too_large and leaves no file", %{tmp_dir: dir} do
    assert {:error, %Error{code: :content_too_large}} =
             write(dir, "big", String.duplicate("a", 65_537))

    assert snapshot(dir) == %{}
    assert {:ok, _} = write(dir, "big", String.duplicate("a", 65_536))
  end

  test "the 201st topic is :too_many_topics but overwriting an existing one still works", %{
    tmp_dir: dir
  } do
    # Short descriptions keep the index under its byte cap so only the count cap is exercised.
    seed_topics(dir, "t", 200, "fact", "")
    assert {:error, %Error{code: :too_many_topics}} = write(dir, "t201", "fact", "")
    assert {:ok, _} = write(dir, "t7", "updated fact", "")
  end

  test "index lines are sorted by name, regenerated on write and forget, empty (not missing) at zero",
       %{tmp_dir: dir} do
    {:ok, _} = write(dir, "zeta", "z", "last")
    {:ok, _} = write(dir, "alpha", "a", "first")

    assert {:ok, "- [alpha](alpha.md) - first\n- [zeta](zeta.md) - last\n"} = Store.index(dir)

    {:ok, _} = Store.forget(dir, "alpha")
    assert {:ok, "- [zeta](zeta.md) - last\n"} = Store.index(dir)

    {:ok, _} = Store.forget(dir, "zeta")
    assert File.read!(Path.join(mem(dir), "MEMORY.md")) == ""
    assert {:ok, []} = Store.list(dir)
  end

  test "overwriting a topic keeps exactly one index line and the new description", %{tmp_dir: dir} do
    {:ok, _} = write(dir, "a", "one", "v1")
    {:ok, _} = write(dir, "a", "two", "v2")
    assert {:ok, "- [a](a.md) - v2\n"} = Store.index(dir)
    assert {:ok, %Store.Entry{description: "v2"}, "two"} = Store.read(dir, "a")
  end

  test "a write rejected by :index_full leaves the directory byte-identical", %{tmp_dir: dir} do
    long = String.duplicate("d", 200)

    # ~25 KiB of index at ~235 bytes a line is ~110 topics: start just below the cap.
    seed_topics(dir, "topic-", 100, "c", long)

    filled =
      Enum.find(101..200, fn i ->
        match?({:error, %Error{code: :index_full}}, write(dir, "topic-#{i}", "c", long))
      end)

    assert filled
    before = snapshot(dir)
    assert {:error, %Error{code: :index_full}} = write(dir, "one-more", "c", long)
    assert {:error, %Error{code: :index_full}} = write(dir, "another", "c", long)
    assert snapshot(dir) == before
    refute Map.has_key?(before, "one-more.md")
  end

  test "forget of an unknown topic is :not_found; forget removes file and index line", %{
    tmp_dir: dir
  } do
    assert {:error, %Error{code: :not_found}} = Store.forget(dir, "ghost")
    {:ok, _} = write(dir, "a", "x")
    assert {:ok, %Store.Entry{name: "a"}} = Store.forget(dir, "a")
    assert {:error, %Error{code: :not_found}} = Store.read(dir, "a")
  end

  test "entry sha256 and bytes describe the on-disk file; mode is 0600; no temp files remain",
       %{tmp_dir: dir} do
    {:ok, entry} = write(dir, "a", "hello")
    disk = File.read!(Path.join(mem(dir), "a.md"))
    assert entry.sha256 == Identity.sha256(disk)
    assert entry.bytes == byte_size(disk)
    assert Bitwise.band(File.stat!(Path.join(mem(dir), "a.md")).mode, 0o777) == 0o600
    assert Enum.sort(File.ls!(mem(dir))) == ["MEMORY.md", "a.md"]
  end

  test "writes add memory/ to .foreman/.gitignore", %{tmp_dir: dir} do
    {:ok, _} = write(dir, "a", "x")
    assert File.read!(Path.join(dir, ".foreman/.gitignore")) == "memory/\n"
  end

  test "a hand-created file without a header lists with an empty description", %{tmp_dir: dir} do
    File.mkdir_p!(mem(dir))
    File.write!(Path.join(mem(dir), "hand.md"), "plain\n")
    assert {:ok, [%Store.Entry{name: "hand", description: ""}]} = Store.list(dir)
    assert {:ok, _, "plain\n"} = Store.read(dir, "hand")
  end

  test "an index write failure restores the topic file (write and forget)", %{tmp_dir: dir} do
    {:ok, _} = write(dir, "a", "original")
    before = File.read!(Path.join(mem(dir), "a.md"))

    # A directory in place of MEMORY.md makes the index rename fail.
    File.rm!(Path.join(mem(dir), "MEMORY.md"))
    File.mkdir_p!(Path.join(mem(dir), "MEMORY.md"))

    assert {:error, %Error{code: :write_failed}} = write(dir, "a", "changed")
    assert File.read!(Path.join(mem(dir), "a.md")) == before
    assert {:error, %Error{code: :write_failed}} = write(dir, "fresh", "x")
    refute File.exists?(Path.join(mem(dir), "fresh.md"))
    assert {:error, %Error{code: :write_failed}} = Store.forget(dir, "a")
    assert File.read!(Path.join(mem(dir), "a.md")) == before
  end
end
