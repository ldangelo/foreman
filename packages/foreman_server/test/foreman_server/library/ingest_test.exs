defmodule ForemanServer.Library.IngestTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias ForemanServer.Library.{Error, Ingest, Plan}

  # foreman-83cf1: dumps :file_server_2 state to stderr if a test nears the 60s timeout; silent otherwise.
  setup do
    ForemanServer.TestSupport.FileServerSampler.start()
  end

  defp touch(dir, rel, bytes \\ "x") do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end

  defp small(overrides \\ %{}),
    do:
      Map.merge(%{max_files_per_add: 3, max_file_bytes: 10, folder_skip_file_bytes: 5}, overrides)

  describe "files" do
    test "101 files is :too_many_files with the default limits", %{tmp_dir: dir} do
      # The limit is on the number of entries; the plan only stats each entry's source, so one real
      # file is enough. Creating 101 distinct ones is ~300 serialized file-server calls that a
      # starved host turns into the 60s test timeout, with no extra coverage.
      src = touch(dir, "src/f.txt")
      files = for n <- 1..101, do: %{relative_path: "f#{n}.txt", source_path: src}

      assert {:error, %Error{code: :too_many_files, details: %{max: 100, got: 101}}} =
               Ingest.plan({:files, files})
    end

    test "100 files is accepted", %{tmp_dir: dir} do
      src = touch(dir, "src/f.txt")
      files = for n <- 1..100, do: %{relative_path: "f#{n}.txt", source_path: src}

      assert {:ok, %Plan{kind: :file, files: items}} = Ingest.plan({:files, files})
      assert length(items) == 100
    end

    test "a file over the per-file cap fails the add and names it", %{tmp_dir: dir} do
      ok = touch(dir, "ok.txt", "tiny")
      big = touch(dir, "big.bin", String.duplicate("a", 11))

      assert {:error, %Error{code: :file_too_large, details: %{path: "big.bin", max: 10}}} =
               Ingest.plan(
                 {:files,
                  [
                    %{relative_path: "ok.txt", source_path: ok},
                    %{relative_path: "big.bin", source_path: big}
                  ]},
                 limits: small()
               )
    end

    test "a file exactly at the cap is accepted", %{tmp_dir: dir} do
      f = touch(dir, "edge.bin", String.duplicate("a", 10))

      assert {:ok, %Plan{total_bytes: 10}} =
               Ingest.plan({:files, [%{relative_path: "edge.bin", source_path: f}]},
                 limits: small()
               )
    end

    test "unsafe relative paths are rejected", %{tmp_dir: dir} do
      f = touch(dir, "src.txt")

      for bad <- [
            "../escape",
            "a/../../b",
            "/abs",
            "",
            "a//b",
            "./a",
            "a/./b",
            "nul\0byte",
            "a\\b"
          ] do
        assert {:error, %Error{code: :path_invalid}} =
                 Ingest.plan({:files, [%{relative_path: bad, source_path: f}]}),
               "expected #{inspect(bad)} to be rejected"
      end
    end

    test "duplicate relative paths in one add are rejected", %{tmp_dir: dir} do
      f = touch(dir, "src.txt")
      item = %{relative_path: "same.txt", source_path: f}
      assert {:error, %Error{code: :path_invalid}} = Ingest.plan({:files, [item, item]})
    end

    test "a symlinked source and a missing source are :source_missing", %{tmp_dir: dir} do
      real = touch(dir, "real.txt")
      link = Path.join(dir, "link.txt")
      File.ln_s!(real, link)

      assert {:error, %Error{code: :source_missing}} =
               Ingest.plan({:files, [%{relative_path: "l.txt", source_path: link}]})

      assert {:error, %Error{code: :source_missing}} =
               Ingest.plan(
                 {:files, [%{relative_path: "m.txt", source_path: Path.join(dir, "nope")}]}
               )
    end

    test "names are validated; a derived name is sanitised", %{tmp_dir: dir} do
      f = touch(dir, "src.txt")
      item = %{relative_path: "My Notes (v2).md", source_path: f}

      assert {:error, %Error{code: :name_invalid}} =
               Ingest.plan({:files, [item]}, name: "../etc")

      assert {:ok, %Plan{name: name}} = Ingest.plan({:files, [item]})
      assert Ingest.valid_name?(name)
    end
  end

  describe "uploaded folders" do
    defp uploaded(dir, rels, bytes \\ "x") do
      for rel <- rels, do: %{relative_path: rel, source_path: touch(dir, "up/" <> rel, bytes)}
    end

    test "apply the folder rules to the uploaded relative paths", %{tmp_dir: dir} do
      files =
        uploaded(dir, [
          "kit/a.md",
          "kit/.env",
          "kit/.git/config",
          "kit/node_modules/x/i.js",
          "kit/src/b.md"
        ])

      assert {:ok, %Plan{kind: :folder, files: items, skipped: skipped}} =
               Ingest.plan({:folder_files, files}, name: "kit")

      assert Enum.map(items, & &1.relative_path) == ["kit/a.md", "kit/src/b.md"]

      assert Map.new(skipped, &{&1.path, &1.reason}) == %{
               "kit/.env" => :hidden,
               "kit/.git/config" => :hidden,
               "kit/node_modules/x/i.js" => :node_modules
             }
    end

    test "respect the file cap, byte budget and oversized-file skip", %{tmp_dir: dir} do
      files = uploaded(dir, ["f1", "f2", "f3"], "1234")

      assert {:ok, %Plan{files: [%{relative_path: "f1"}], skipped: skipped}} =
               Ingest.plan({:folder_files, files}, limits: %{folder_max_bytes: 5})

      assert Enum.map(skipped, &{&1.path, &1.reason}) == [
               {"f2", :folder_byte_budget},
               {"f3", :folder_byte_budget}
             ]

      assert {:ok, %Plan{files: capped}} =
               Ingest.plan({:folder_files, files}, limits: %{folder_max_files: 2})

      assert length(capped) == 2

      assert {:error, %Error{code: :folder_empty, details: %{skipped: %{"over_30mb" => 3}}}} =
               Ingest.plan({:folder_files, files}, limits: %{folder_skip_file_bytes: 3})
    end

    test "unsafe or duplicate paths are rejected", %{tmp_dir: dir} do
      assert {:error, %Error{code: :path_invalid}} =
               Ingest.plan({:folder_files, uploaded(dir, ["../escape"])})

      [one] = uploaded(dir, ["same"])
      assert {:error, %Error{code: :path_invalid}} = Ingest.plan({:folder_files, [one, one]})
    end
  end

  describe "folders" do
    test "hidden entries, node_modules, symlinks and oversized files are skipped with reasons",
         %{tmp_dir: dir} do
      root = Path.join(dir, "proj")
      touch(root, "a.txt")
      touch(root, "sub/b.txt")
      touch(root, ".env", "secret")
      touch(root, ".git/config")
      touch(root, "node_modules/dep/index.js")
      touch(root, "big.bin", "123456")
      File.ln_s!(Path.join(root, "a.txt"), Path.join(root, "link.txt"))

      assert {:ok, %Plan{kind: :folder, files: items, skipped: skipped}} =
               Ingest.plan({:folder, root}, limits: small())

      assert Enum.map(items, & &1.relative_path) == ["a.txt", "sub/b.txt"]

      assert Map.new(skipped, &{&1.path, &1.reason}) == %{
               ".env" => :hidden,
               ".git" => :hidden,
               "node_modules" => :node_modules,
               "big.bin" => :over_30mb,
               "link.txt" => :symlink
             }
    end

    test "takes the first N files in sorted order and reports the rest", %{tmp_dir: dir} do
      root = Path.join(dir, "many")
      for n <- 1..5, do: touch(root, "f#{n}.txt")

      assert {:ok, %Plan{files: items, skipped: skipped}} =
               Ingest.plan({:folder, root}, limits: %{folder_max_files: 3})

      assert Enum.map(items, & &1.relative_path) == ["f1.txt", "f2.txt", "f3.txt"]

      assert [
               %{path: "f4.txt", reason: :folder_file_cap},
               %{path: "f5.txt", reason: :folder_file_cap}
             ] =
               Enum.map(skipped, &Map.from_struct/1)
    end

    test "stops at the byte budget: the file that would exceed it and everything after are skipped",
         %{tmp_dir: dir} do
      root = Path.join(dir, "budget")
      touch(root, "a.txt", "1234")
      touch(root, "b.txt", "1234")
      touch(root, "c.txt", "1")

      assert {:ok, %Plan{files: items, skipped: skipped, total_bytes: 4}} =
               Ingest.plan({:folder, root}, limits: %{folder_max_bytes: 5})

      assert Enum.map(items, & &1.relative_path) == ["a.txt"]

      assert Enum.map(skipped, &{&1.path, &1.reason}) == [
               {"b.txt", :folder_byte_budget},
               {"c.txt", :folder_byte_budget}
             ]
    end

    test "the same tree always yields the same plan", %{tmp_dir: dir} do
      root = Path.join(dir, "det")
      for rel <- ["z.txt", "a/y.txt", "a/b/x.txt", "m.txt"], do: touch(root, rel)

      assert Ingest.plan({:folder, root}) == Ingest.plan({:folder, root})
      assert {:ok, %Plan{files: items}} = Ingest.plan({:folder, root})
      assert Enum.map(items, & &1.relative_path) == ["a/b/x.txt", "a/y.txt", "m.txt", "z.txt"]
    end

    test "a folder with nothing eligible is :folder_empty and says why", %{tmp_dir: dir} do
      root = Path.join(dir, "hidden-only")
      touch(root, ".secret")

      assert {:error, %Error{code: :folder_empty, details: %{skipped: %{"hidden" => 1}}}} =
               Ingest.plan({:folder, root})
    end

    test "relative and missing folders are rejected", %{tmp_dir: dir} do
      assert {:error, %Error{code: :path_invalid}} = Ingest.plan({:folder, "relative/dir"})

      assert {:error, %Error{code: :source_missing}} =
               Ingest.plan({:folder, Path.join(dir, "nope")})
    end
  end
end
