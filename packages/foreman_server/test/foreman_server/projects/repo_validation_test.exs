defmodule ForemanServer.Projects.RepoValidationTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias ForemanServer.Projects.RepoValidation

  describe "pure" do
    test "validate_id/1" do
      assert :ok = RepoValidation.validate_id("a")
      assert :ok = RepoValidation.validate_id("api-2")
      assert :ok = RepoValidation.validate_id(String.duplicate("a", 32))
      assert {:error, {:invalid_repo_id, "A"}} = RepoValidation.validate_id("A")
      assert {:error, {:invalid_repo_id, "a_b"}} = RepoValidation.validate_id("a_b")

      assert {:error, {:invalid_repo_id, _}} =
               RepoValidation.validate_id(String.duplicate("a", 33))
    end

    test "id_from_name/1 reduces a name to the id syntax, the same way every time" do
      assert {:ok, "api"} = RepoValidation.id_from_name("api")
      assert {:ok, "web-app"} = RepoValidation.id_from_name("Web_App")
      assert {:ok, "my-repo-2"} = RepoValidation.id_from_name("  My Repo 2!! ")
      assert {:ok, "a-b"} = RepoValidation.id_from_name("a..b")
      assert {:ok, "9lives"} = RepoValidation.id_from_name("9lives")

      # Long names are cut at 32 characters and never end in a dash.
      long = String.duplicate("a", 31) <> "-bbbb"
      assert {:ok, id} = RepoValidation.id_from_name(long)
      assert String.length(id) <= 32 and not String.ends_with?(id, "-")
      assert :ok = RepoValidation.validate_id(id)

      assert RepoValidation.id_from_name("same name") == RepoValidation.id_from_name("same name")
    end

    test "id_from_name/1 refuses a name with nothing usable in it, naming it" do
      assert {:error, {:invalid_repo_name, ""}} = RepoValidation.id_from_name("")
      assert {:error, {:invalid_repo_name, "---"}} = RepoValidation.id_from_name("---")
      assert {:error, {:invalid_repo_name, "!!!"}} = RepoValidation.id_from_name("!!!")
    end

    test "validate_path/1 and reject_duplicate_path/2" do
      assert :ok = RepoValidation.validate_path("/a/b")
      assert {:error, {:repo_path_not_absolute, "a/b"}} = RepoValidation.validate_path("a/b")
      assert {:error, {:repo_path_not_absolute, nil}} = RepoValidation.validate_path(nil)
      assert :ok = RepoValidation.reject_duplicate_path("/a/b", ["/a/c", nil])

      assert {:error, {:repo_path_duplicate, "/a/b/../b"}} =
               RepoValidation.reject_duplicate_path("/a/b/../b", ["/a/b"])
    end

    test "normalize_remote/1 equates scp, https and ssh forms" do
      forms = [
        "git@github.com:Org/Repo.git\n",
        "https://github.com/org/repo",
        "https://user@github.com/org/repo.git/",
        "ssh://git@github.com/org/repo.git"
      ]

      assert forms |> Enum.map(&RepoValidation.normalize_remote/1) |> Enum.uniq() ==
               ["github.com/org/repo"]

      refute RepoValidation.normalize_remote("git@github.com:org/other.git") ==
               RepoValidation.normalize_remote("git@github.com:org/repo.git")
    end
  end

  describe "impure checks against real checkouts" do
    defp git!(dir, args),
      do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

    defp repo!(root, name, remote \\ nil) do
      dir = Path.join(root, name)
      File.mkdir_p!(dir)
      {_, 0} = System.cmd("git", ["init", "-q", dir], stderr_to_stdout: true)
      if remote, do: git!(dir, ["remote", "add", "origin", remote])
      dir
    end

    test "inspect_checkout canonicalises symlinks and reads origin", %{tmp_dir: root} do
      real = repo!(root, "real", "git@example.com:org/a.git")
      link = Path.join(root, "link")
      File.ln_s!(real, link)

      assert {:ok, %{path: path, remote: "example.com/org/a"}} =
               RepoValidation.inspect_checkout(link)

      assert path == canonical(real)
    end

    test "missing path and non-git directory", %{tmp_dir: root} do
      plain = Path.join(root, "plain")
      File.mkdir_p!(plain)

      assert {:error, {:repo_path_not_found, _}} =
               RepoValidation.inspect_checkout(Path.join(root, "nope"))

      assert {:error, {:repo_not_git_work_tree, ^plain}} = RepoValidation.inspect_checkout(plain)
    end

    test "check_candidate rejects a symlink alias of an existing repo", %{tmp_dir: root} do
      primary = repo!(root, "primary")
      alias_path = Path.join(root, "alias")
      File.ln_s!(primary, alias_path)
      repos = [%{id: "main", path: primary}]

      assert {:error, {:repo_path_duplicate, _}} =
               RepoValidation.check_candidate(alias_path, repos)
    end

    test "check_candidate rejects a second checkout of the same remote", %{tmp_dir: root} do
      primary = repo!(root, "primary", "https://example.com/org/a.git")
      clone = repo!(root, "clone", "git@example.com:org/a.git")
      other = repo!(root, "other", "https://example.com/org/b.git")
      repos = [%{id: "main", path: primary}]

      assert {:error, {:repo_remote_duplicate, "main"}} =
               RepoValidation.check_candidate(clone, repos)

      assert {:ok, %{path: path}} = RepoValidation.check_candidate(other, repos)
      assert path == canonical(other)
    end

    test "replacing: \"main\" lets project.update re-point the primary at its own remote",
         %{tmp_dir: root} do
      primary = repo!(root, "primary", "https://example.com/org/a.git")
      moved = repo!(root, "moved", "https://example.com/org/a.git")
      repos = [%{id: "main", path: primary}]

      assert {:error, {:repo_remote_duplicate, "main"}} =
               RepoValidation.check_candidate(moved, repos)

      assert {:ok, _} = RepoValidation.check_candidate(moved, repos, replacing: "main")
    end

    test "replacing still checks the remaining extras", %{tmp_dir: root} do
      primary = repo!(root, "primary", "https://example.com/org/a.git")
      extra = repo!(root, "extra", "https://example.com/org/b.git")
      moved = repo!(root, "moved", "https://example.com/org/b.git")
      repos = [%{id: "main", path: primary}, %{id: "api", path: extra}]

      assert {:error, {:repo_remote_duplicate, "api"}} =
               RepoValidation.check_candidate(moved, repos, replacing: "main")
    end

    defp canonical(path) do
      {out, 0} = System.cmd("git", ["-C", path, "rev-parse", "--show-toplevel"])
      String.trim(out)
    end
  end
end
