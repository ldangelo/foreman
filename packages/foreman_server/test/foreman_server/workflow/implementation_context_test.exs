defmodule ForemanServer.Workflow.ImplementationContextTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Workflow.ImplementationContext

  setup do
    original_state = :sys.get_state(ProjectionStore)

    ExUnit.Callbacks.on_exit(fn ->
      :sys.replace_state(ProjectionStore, fn _ -> original_state end)
    end)

    :sys.replace_state(ProjectionStore, fn state ->
      %{state | projects: %{}, tasks: %{}}
    end)

    :ok
  end

  describe "beads_workflow?/1" do
    test "true for implement-trd-beads" do
      assert ImplementationContext.beads_workflow?("implement-trd-beads")
    end

    test "false for implement-trd" do
      refute ImplementationContext.beads_workflow?("implement-trd")
    end

    test "false for nil" do
      refute ImplementationContext.beads_workflow?(nil)
    end

    test "false for unrelated task types" do
      refute ImplementationContext.beads_workflow?("plan")
      refute ImplementationContext.beads_workflow?("assess")
    end
  end

  describe "implementation_key/2" do
    test "is deterministic for the same inputs" do
      assert {:ok, k1} = ImplementationContext.implementation_key("p-1", "docs/TRD/x.md")
      assert {:ok, k2} = ImplementationContext.implementation_key("p-1", "docs/TRD/x.md")
      assert k1 == k2
      assert byte_size(k1) == 64
      assert String.match?(k1, ~r/^[0-9a-f]+$/)
    end

    test "differs when project_id differs" do
      assert {:ok, k1} = ImplementationContext.implementation_key("p-1", "docs/TRD/x.md")
      assert {:ok, k2} = ImplementationContext.implementation_key("p-2", "docs/TRD/x.md")
      refute k1 == k2
    end

    test "differs when trd_path differs" do
      assert {:ok, k1} = ImplementationContext.implementation_key("p-1", "docs/TRD/a.md")
      assert {:ok, k2} = ImplementationContext.implementation_key("p-1", "docs/TRD/b.md")
      refute k1 == k2
    end
  end

  describe "build/1 project_id validation" do
    test "rejects nil project_id" do
      assert {:error, {:implementation_context_failed, :project_id_missing}} =
               ImplementationContext.build(%{project_id: nil})
    end

    test "rejects empty project_id" do
      assert {:error, {:implementation_context_failed, :project_id_missing}} =
               ImplementationContext.build(%{project_id: ""})
    end

    test "rejects when project projection is missing" do
      assert {:error, {:implementation_context_failed, :project_not_found}} =
               ImplementationContext.build(%{
                 project_id: "nonexistent",
                 workflow_type: "implement-trd",
                 trd_path: "docs/TRD/x.md"
               })
    end
  end

  describe "build/1 with a real git repo" do
    setup do
      # Crypto-strong suffix prevents stale-dir collisions across runs.
      # File.rm_rf! before mkdir_p handles leftover dirs from crashed runs.
      suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
      repo = Path.join(System.tmp_dir!(), "ic-test-#{suffix}")

      File.rm_rf!(repo)
      File.mkdir_p!(Path.join(repo, "docs/TRD"))
      File.write!(Path.join([repo, "docs", "TRD", "x.md"]), "# TRD\n")

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: repo)
      {_, 0} = System.cmd("git", ["config", "user.email", "t@t"], cd: repo)
      {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: repo)
      {_, 0} = System.cmd("git", ["add", "."], cd: repo)
      {_, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: repo)

      ExUnit.Callbacks.on_exit(fn -> File.rm_rf(repo) end)

      %{repo: repo}
    end

    test "succeeds on a tracked regular blob", %{repo: repo} do
      :sys.replace_state(ProjectionStore, fn state ->
        put_in(state.projects["proj-1"], %{
          project_id: "proj-1",
          path: repo,
          status: "active"
        })
      end)

      assert {:ok, ctx} =
               ImplementationContext.build(%{
                 project_id: "proj-1",
                 workflow_type: "implement-trd",
                 trd_path: "docs/TRD/x.md"
               })

      assert ctx.trd_path == "docs/TRD/x.md"
      assert ctx.project_root == canonical(repo)
      assert String.length(ctx.source_revision) == 40
      assert byte_size(ctx.implementation_key) == 64
      assert ctx.trd_path_argument == ~s("docs/TRD/x.md")
      assert ctx.beads_database_path == nil
    end

    test "succeeds on a tracked regular blob whose path contains spaces", %{repo: repo} do
      File.mkdir_p!(Path.join([repo, "docs", "My TRD Set"]))
      File.write!(Path.join([repo, "docs", "My TRD Set", "alpha bravo.md"]), "# TRD\n")
      {_, 0} = System.cmd("git", ["add", "."], cd: repo)
      {_, 0} = System.cmd("git", ["commit", "-q", "-m", "spaces"], cd: repo)

      :sys.replace_state(ProjectionStore, fn state ->
        put_in(state.projects["proj-spaces"], %{
          project_id: "proj-spaces",
          path: repo,
          status: "active"
        })
      end)

      assert {:ok, ctx} =
               ImplementationContext.build(%{
                 project_id: "proj-spaces",
                 workflow_type: "implement-trd",
                 trd_path: "docs/My TRD Set/alpha bravo.md"
               })

      assert ctx.trd_path == "docs/My TRD Set/alpha bravo.md"
      assert ctx.project_root == canonical(repo)
      assert String.length(ctx.source_revision) in [40, 64]
      assert ctx.trd_path_argument == ~s("docs/My TRD Set/alpha bravo.md")
      assert ctx.beads_database_path == nil
    end

    test "rejects a tracked symlink (mode 120000)", %{repo: repo} do
      {_, 0} = System.cmd("git", ["rm", "-q", "docs/TRD/x.md"], cd: repo)
      File.write!(Path.join(repo, "target.md"), "# t\n")
      # git rm removes empty parent dirs in modern git; recreate before
      # replacing the entry with a symlink.
      File.mkdir_p!(Path.join(repo, "docs/TRD"))

      {_, 0} =
        System.cmd(
          "ln",
          ["-s", Path.join(repo, "target.md"), Path.join([repo, "docs", "TRD", "x.md"])]
        )

      {_, 0} = System.cmd("git", ["add", "."], cd: repo)
      {_, 0} = System.cmd("git", ["commit", "-q", "-m", "link"], cd: repo)

      :sys.replace_state(ProjectionStore, fn state ->
        put_in(state.projects["proj-1"], %{project_id: "proj-1", path: repo, status: "active"})
      end)

      assert {:error, {:implementation_context_failed, :trd_path_is_symlink}} =
               ImplementationContext.build(%{
                 project_id: "proj-1",
                 workflow_type: "implement-trd",
                 trd_path: "docs/TRD/x.md"
               })
    end

    test "rejects `..` traversal", %{repo: repo} do
      :sys.replace_state(ProjectionStore, fn state ->
        put_in(state.projects["proj-1"], %{project_id: "proj-1", path: repo, status: "active"})
      end)

      assert {:error, {:implementation_context_failed, :trd_path_not_project_relative}} =
               ImplementationContext.build(%{
                 project_id: "proj-1",
                 workflow_type: "implement-trd",
                 trd_path: "../escape.md"
               })
    end

    test "rejects absolute path", %{repo: repo} do
      :sys.replace_state(ProjectionStore, fn state ->
        put_in(state.projects["proj-1"], %{project_id: "proj-1", path: repo, status: "active"})
      end)

      assert {:error, {:implementation_context_failed, :trd_path_not_project_relative}} =
               ImplementationContext.build(%{
                 project_id: "proj-1",
                 workflow_type: "implement-trd",
                 trd_path: "/etc/passwd"
               })
    end

    test "rejects missing file", %{repo: repo} do
      :sys.replace_state(ProjectionStore, fn state ->
        put_in(state.projects["proj-1"], %{project_id: "proj-1", path: repo, status: "active"})
      end)

      assert {:error, {:implementation_context_failed, :trd_path_missing}} =
               ImplementationContext.build(%{
                 project_id: "proj-1",
                 workflow_type: "implement-trd",
                 trd_path: "docs/TRD/nonexistent.md"
               })
    end

    test "rejects untracked file", %{repo: repo} do
      File.write!(Path.join([repo, "docs", "TRD", "untracked.md"]), "# u\n")

      :sys.replace_state(ProjectionStore, fn state ->
        put_in(state.projects["proj-1"], %{project_id: "proj-1", path: repo, status: "active"})
      end)

      assert {:error, {:implementation_context_failed, :trd_path_not_tracked_blob}} =
               ImplementationContext.build(%{
                 project_id: "proj-1",
                 workflow_type: "implement-trd",
                 trd_path: "docs/TRD/untracked.md"
               })
    end

    test "rejects when project_root is not a git repo", %{repo: _repo} do
      suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
      nongit = Path.join(System.tmp_dir!(), "ic-nongit-#{suffix}")
      File.rm_rf!(nongit)
      File.mkdir_p!(Path.join(nongit, "docs/TRD"))
      File.write!(Path.join([nongit, "docs", "TRD", "x.md"]), "# t\n")

      ExUnit.Callbacks.on_exit(fn -> File.rm_rf(nongit) end)

      :sys.replace_state(ProjectionStore, fn state ->
        put_in(state.projects["proj-1"], %{project_id: "proj-1", path: nongit, status: "active"})
      end)

      assert {:error, {:implementation_context_failed, :not_a_git_repo}} =
               ImplementationContext.build(%{
                 project_id: "proj-1",
                 workflow_type: "implement-trd",
                 trd_path: "docs/TRD/x.md"
               })
    end

    test "rejects symlinked intermediate directory (parent-dir escape)", %{repo: repo} do
      suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
      outside = Path.join(System.tmp_dir!(), "ic-outside-#{suffix}")
      File.rm_rf!(outside)
      File.mkdir_p!(Path.join(outside, "TRD"))
      File.write!(Path.join([outside, "TRD", "x.md"]), "# outside\n")

      File.rm_rf!(Path.join(repo, "docs"))

      {_, 0} =
        System.cmd("ln", ["-s", outside, Path.join(repo, "docs")])

      ExUnit.Callbacks.on_exit(fn -> File.rm_rf(outside) end)

      :sys.replace_state(ProjectionStore, fn state ->
        put_in(state.projects["proj-1"], %{project_id: "proj-1", path: repo, status: "active"})
      end)

      assert {:error, {:implementation_context_failed, :trd_path_is_symlink}} =
               ImplementationContext.build(%{
                 project_id: "proj-1",
                 workflow_type: "implement-trd",
                 trd_path: "docs/TRD/x.md"
               })
    end

    test "non-beads workflow returns beads_database_path: nil", %{repo: repo} do
      :sys.replace_state(ProjectionStore, fn state ->
        put_in(state.projects["proj-1"], %{project_id: "proj-1", path: repo, status: "active"})
      end)

      assert {:ok, ctx} =
               ImplementationContext.build(%{
                 project_id: "proj-1",
                 workflow_type: "implement-trd",
                 trd_path: "docs/TRD/x.md"
               })

      assert ctx.beads_database_path == nil
      refute Map.has_key?(ImplementationContext.to_payload(ctx), "beads_database_path")
    end
  end

  describe "to_payload/1" do
    test "always includes the five required fields" do
      ctx = %ImplementationContext{
        trd_path: "docs/TRD/x.md",
        trd_path_argument: ~s("docs/TRD/x.md"),
        project_root: "/tmp/proj",
        source_revision: String.duplicate("a", 40),
        implementation_key: String.duplicate("b", 64),
        beads_database_path: nil
      }

      assert ImplementationContext.to_payload(ctx) == %{
               "trd_path" => "docs/TRD/x.md",
               "trd_path_argument" => ~s("docs/TRD/x.md"),
               "project_root" => "/tmp/proj",
               "source_revision" => String.duplicate("a", 40),
               "implementation_key" => String.duplicate("b", 64)
             }
    end

    test "includes beads_database_path only when set" do
      ctx = %ImplementationContext{
        trd_path: "docs/TRD/x.md",
        trd_path_argument: ~s("docs/TRD/x.md"),
        project_root: "/tmp/proj",
        source_revision: String.duplicate("a", 40),
        implementation_key: String.duplicate("b", 64),
        beads_database_path: "/abs/path/adb"
      }

      payload = ImplementationContext.to_payload(ctx)
      assert payload["beads_database_path"] == "/abs/path/adb"
    end
  end

  # Use the OS `realpath` utility — robust against the /var/folders →
  # /private/var/folders symlink on macOS. ImplementationContext walks
  # components using BEAM primitives; this helper only needs to
  # canonicalize the test repo root for assertion equality.
  defp canonical(path) do
    {out, 0} = System.cmd("realpath", [path])
    String.trim(out)
  end
end
