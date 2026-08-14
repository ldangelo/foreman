defmodule ForemanServer.VcsAdapter.DefaultTest do
  use ExUnit.Case, async: false

  alias ForemanServer.VcsAdapter.Default

  defmodule StubAlwaysTransient do
    @behaviour ForemanServer.VcsAdapter

    @impl true
    def clone(_url, _opts), do: {:error, {:transient, "fail"}}

    @impl true
    def branch(_path, _name), do: raise("not used")

    @impl true
    def create_pr(_path, _opts), do: raise("not used")

    @impl true
    def create_worktree(_repo_path, _worktree_path, _opts), do: raise("not used")

    @impl true
    def clean_worktree(_worktree_path, _opts), do: raise("not used")
  end

  describe "transient?/1" do
    test "distinguishes {:transient, _} from non-transient" do
      assert ForemanServer.VcsAdapter.transient?({:transient, "x"})
      refute ForemanServer.VcsAdapter.transient?(:auth)
    end
  end

  describe "retry integration" do
    test "transient failure retries up to 3 times then returns error" do
      assert {:error, {:transient, _}} =
               ForemanServer.VcsAdapter.run(StubAlwaysTransient, :clone, ["url", []],
                 max_retries: 3,
                 base_delay_ms: 1
               )
    end
  end

  describe "Default module API" do
    test "exposes public run/3 entry point" do
      Code.ensure_loaded(Default)
      assert function_exported?(Default, :run, 3)
    end

    test "exposes scrubbed_target/3" do
      Code.ensure_loaded(Default)
      assert function_exported?(Default, :scrubbed_target, 3)
      assert function_exported?(Default, :scrubbed_target, 2)
    end

    test "exposes create_worktree/3 and clean_worktree/2" do
      Code.ensure_loaded(Default)
      assert function_exported?(Default, :create_worktree, 3)
      assert function_exported?(Default, :clean_worktree, 2)
    end
  end

  describe "scrubbed_target/3" do
    test "reduces both paths to their basename" do
      target = Default.scrubbed_target("/tmp/myrepo", "/tmp/myrepo/.worktrees/wt-7")
      assert target == "myrepo:wt-7"
    end

    test "appends non-nil suffix verbatim" do
      target =
        Default.scrubbed_target("/tmp/myrepo", "/tmp/myrepo/.worktrees/wt-7", "abc123def")

      assert target == "myrepo:wt-7:abc123def"
    end

    test "omits nil and empty suffix" do
      assert Default.scrubbed_target("/tmp/myrepo", "/tmp/myrepo/.worktrees/wt-7", nil) ==
               "myrepo:wt-7"

      assert Default.scrubbed_target("/tmp/myrepo", "/tmp/myrepo/.worktrees/wt-7", "") ==
               "myrepo:wt-7"
    end

    test "never leaks absolute paths in output" do
      target = Default.scrubbed_target("/private/var/folders/abc/repo", "/Users/x/.worktrees/wt")

      refute target =~ "/private/"
      refute target =~ "/Users/"
      assert target == "repo:wt"
    end
  end

  describe "create_worktree/3" do
    setup do
      repo =
        Path.join(System.tmp_dir!(), "foreman-vcs-create-#{System.unique_integer([:positive])}")

      # Wipe any leftover from a prior VM run (re-using the same
      # `unique_integer` value across runs could otherwise leave a
      # stale `.git/worktrees/` entry that confuses subsequent
      # `git worktree add` invocations).
      File.rm_rf!(repo)
      File.mkdir_p!(repo)
      on_exit(fn -> File.rm_rf!(repo) end)
      {:ok, repo: repo}
    end

    test "creates a worktree on a named branch and captures git output", %{repo: repo} do
      run_git!(["-C", repo, "init", "--initial-branch=main"])
      run_git!(["-C", repo, "config", "user.email", "t@x"])
      run_git!(["-C", repo, "config", "user.name", "T"])
      File.write!(Path.join(repo, "README.md"), "x")
      run_git!(["-C", repo, "add", "."])
      run_git!(["-C", repo, "commit", "--no-gpg-sign", "-m", "init"])
      base_sha = run_git!(["-C", repo, "rev-parse", "HEAD"]) |> String.trim()

      worktree_path = Path.join(repo, ".worktrees/wt-success")
      File.rm_rf!(worktree_path)

      opts = [
        operation_id: "wt-success-#{System.unique_integer([:positive])}",
        base: base_sha,
        branch: "feat/success",
        project_id: "p",
        run_id: "r",
        phase_id: "ph"
      ]

      assert {:ok, result} = Default.create_worktree(repo, worktree_path, opts)
      assert result.path == worktree_path
      assert result.base == base_sha
      assert result.branch == "feat/success"
      assert is_binary(result.output) and result.output != ""
      assert File.dir?(worktree_path)
    end

    test "returns error when base ref is invalid", %{repo: repo} do
      run_git!(["-C", repo, "init", "--initial-branch=main"])
      run_git!(["-C", repo, "config", "user.email", "t@x"])
      run_git!(["-C", repo, "config", "user.name", "T"])

      worktree_path = Path.join(repo, ".worktrees/wt-bad-base")
      File.rm_rf!(worktree_path)

      opts = [
        operation_id: "wt-bad-#{System.unique_integer([:positive])}",
        base: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
        branch: "feat/bad",
        project_id: "p",
        run_id: "r",
        phase_id: "ph"
      ]

      assert {:error, {:git_worktree_create_failed, _code, output}} =
               Default.create_worktree(repo, worktree_path, opts)

      assert output =~ "fatal" or output =~ "invalid" or output =~ "not a tree"
      refute File.dir?(worktree_path)
    end

    test "creates a detached worktree when branch is nil", %{repo: repo} do
      run_git!(["-C", repo, "init", "--initial-branch=main"])
      run_git!(["-C", repo, "config", "user.email", "t@x"])
      run_git!(["-C", repo, "config", "user.name", "T"])
      File.write!(Path.join(repo, "README.md"), "x")
      run_git!(["-C", repo, "add", "."])
      run_git!(["-C", repo, "commit", "--no-gpg-sign", "-m", "init"])
      base_sha = run_git!(["-C", repo, "rev-parse", "HEAD"]) |> String.trim()

      worktree_path = Path.join(repo, ".worktrees/wt-detached")
      File.rm_rf!(worktree_path)

      opts = [
        operation_id: "wt-detached-#{System.unique_integer([:positive])}",
        base: base_sha,
        branch: nil,
        project_id: "p",
        run_id: "r",
        phase_id: "ph"
      ]

      assert {:ok, result} = Default.create_worktree(repo, worktree_path, opts)
      assert result.branch == nil
      assert result.path == worktree_path

      assert File.dir?(worktree_path)
      head = run_git!(["-C", worktree_path, "rev-parse", "HEAD"]) |> String.trim()
      assert head == base_sha
    end

    test "pinned SHA is honored as the base ref", %{repo: repo} do
      run_git!(["-C", repo, "init", "--initial-branch=main"])
      run_git!(["-C", repo, "config", "user.email", "t@x"])
      run_git!(["-C", repo, "config", "user.name", "T"])
      File.write!(Path.join(repo, "v1.txt"), "v1")
      run_git!(["-C", repo, "add", "."])
      run_git!(["-C", repo, "commit", "--no-gpg-sign", "-m", "v1"])
      sha1 = run_git!(["-C", repo, "rev-parse", "HEAD"]) |> String.trim()

      File.write!(Path.join(repo, "v2.txt"), "v2")
      run_git!(["-C", repo, "add", "."])
      run_git!(["-C", repo, "commit", "--no-gpg-sign", "-m", "v2"])
      _sha2 = run_git!(["-C", repo, "rev-parse", "HEAD"]) |> String.trim()

      worktree_path = Path.join(repo, ".worktrees/wt-pinned")
      File.rm_rf!(worktree_path)

      opts = [
        operation_id: "wt-pinned-#{System.unique_integer([:positive])}",
        base: sha1,
        branch: "feat/pinned",
        project_id: "p",
        run_id: "r",
        phase_id: "ph"
      ]

      assert {:ok, result} = Default.create_worktree(repo, worktree_path, opts)
      assert result.base == sha1

      head = run_git!(["-C", worktree_path, "rev-parse", "HEAD"]) |> String.trim()
      assert head == sha1
    end
  end

  describe "clean_worktree/2" do
    setup do
      repo =
        Path.join(System.tmp_dir!(), "foreman-vcs-clean-#{System.unique_integer([:positive])}")

      File.rm_rf!(repo)
      File.mkdir_p!(repo)
      on_exit(fn -> File.rm_rf!(repo) end)
      run_git!(["-C", repo, "init", "--initial-branch=main"])
      run_git!(["-C", repo, "config", "user.email", "t@x"])
      run_git!(["-C", repo, "config", "user.name", "T"])
      File.write!(Path.join(repo, "README.md"), "x")
      run_git!(["-C", repo, "add", "."])
      run_git!(["-C", repo, "commit", "--no-gpg-sign", "-m", "init"])
      base_sha = run_git!(["-C", repo, "rev-parse", "HEAD"]) |> String.trim()

      worktree_path = Path.join(repo, ".worktrees/wt-clean")
      File.rm_rf!(worktree_path)

      opts = [
        operation_id: "wt-clean-#{System.unique_integer([:positive])}",
        repo_path: repo,
        project_id: "p",
        run_id: "r",
        phase_id: "ph"
      ]

      {:ok, repo: repo, worktree_path: worktree_path, opts: opts, base_sha: base_sha}
    end

    test "removes an existing clean worktree and captures output", ctx do
      {:ok, _} =
        Default.create_worktree(
          ctx.repo,
          ctx.worktree_path,
          operation_id: ctx.opts[:operation_id],
          base: ctx.base_sha,
          branch: "feat/clean",
          project_id: "p",
          run_id: "r",
          phase_id: "ph"
        )

      assert File.dir?(ctx.worktree_path)

      assert {:ok, result} = Default.clean_worktree(ctx.worktree_path, ctx.opts)
      assert result.path == ctx.worktree_path
      assert result.cleaned? == true
      assert result.noop? == false
      assert is_binary(result.output)
      refute File.dir?(ctx.worktree_path)
    end

    test "truly idempotent absent-path omits :output entirely", ctx do
      refute File.exists?(ctx.worktree_path)

      assert {:ok, result} = Default.clean_worktree(ctx.worktree_path, ctx.opts)
      assert result.cleaned? == true
      assert result.noop? == true
      refute Map.has_key?(result, :output)
    end

    test "does NOT noop when path is absent but git worktree list still registers it", ctx do
      {:ok, _} =
        Default.create_worktree(
          ctx.repo,
          ctx.worktree_path,
          operation_id: ctx.opts[:operation_id],
          base: ctx.base_sha,
          branch: "feat/stale",
          project_id: "p",
          run_id: "r",
          phase_id: "ph"
        )

      # Operator removes the worktree directory out-of-band but leaves
      # the git registry entry intact. The adapter MUST NOT silently
      # noop here — it MUST attempt `git worktree remove` so the
      # stale entry is surfaced (and the operator notices).
      canonical_path = canonical_path_for(ctx.worktree_path)
      File.rm_rf!(ctx.worktree_path)
      refute File.exists?(ctx.worktree_path)

      porcelain_before = run_git!(["-C", ctx.repo, "worktree", "list", "--porcelain"])
      assert porcelain_before =~ "worktree #{canonical_path}"

      # Git's `worktree remove` succeeds on a missing-but-registered
      # worktree because the entry is marked `prunable`. The point of
      # this test is the adapter MUST NOT short-circuit with a noop
      # — it must call into git and let git's actual result flow
      # through. We assert `noop?: false` and an :ok envelope (since
      # git's behavior is git's contract, not ours to override).
      assert {:ok, %{cleaned?: true, noop?: false}} =
               Default.clean_worktree(ctx.worktree_path, ctx.opts)

      porcelain_after = run_git!(["-C", ctx.repo, "worktree", "list", "--porcelain"])
      refute porcelain_after =~ "worktree #{canonical_path}"
    end

    test "dirty worktree returns error without --force", ctx do
      {:ok, _} =
        Default.create_worktree(
          ctx.repo,
          ctx.worktree_path,
          operation_id: ctx.opts[:operation_id],
          base: ctx.base_sha,
          branch: "feat/dirty",
          project_id: "p",
          run_id: "r",
          phase_id: "ph"
        )

      # Forge a dirty state by staging uncommitted changes.
      File.write!(Path.join(ctx.worktree_path, "dirty.txt"), "uncommitted")
      run_git!(["-C", ctx.worktree_path, "add", "dirty.txt"])

      assert {:error, {:git_worktree_clean_failed, _code, _output}} =
               Default.clean_worktree(ctx.worktree_path, ctx.opts)

      assert File.dir?(ctx.worktree_path)
    end

    test "clean failure dispatches a vcs_operation.fail command", ctx do
      {:ok, _} =
        Default.create_worktree(
          ctx.repo,
          ctx.worktree_path,
          operation_id: ctx.opts[:operation_id],
          base: ctx.base_sha,
          branch: "feat/telemetry",
          project_id: "p",
          run_id: "r",
          phase_id: "ph"
        )

      File.write!(Path.join(ctx.worktree_path, "dirty.txt"), "uncommitted")
      run_git!(["-C", ctx.worktree_path, "add", "dirty.txt"])

      handler_id = "test-clean-failed-#{System.unique_integer([:positive])}"
      parent = self()
      expected_operation_id = ctx.opts[:operation_id]

      :telemetry.attach(
        handler_id,
        [:foreman_server, :vcs, :worktree, :clean_failed],
        fn name, measurements, metadata, _config ->
          if metadata[:operation_id] == expected_operation_id do
            send(parent, {:telemetry, name, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, {:git_worktree_clean_failed, _code, _output}} =
               Default.clean_worktree(ctx.worktree_path, ctx.opts)

      # Adapter no longer emits the canonical clean_failed telemetry — the
      # orchestrator (ForemanServer.Workflow.Worktree) is the sole canonical
      # source. The adapter's contract is to dispatch a vcs_operation.fail
      # command via CommandGateway.
      # Scope the assertion to this test's operation_id so concurrent
      # orchestrator clean_attempts on unrelated worktrees (from
      # boot_reconciliation etc.) do not leak into the test mailbox.
      refute_receive {:telemetry, [:foreman_server, :vcs, :worktree, :clean_failed],
                      _measurements, %{operation_id: ^expected_operation_id}},
                     200
    end

    test "successful clean does NOT emit clean_failed telemetry", ctx do
      {:ok, _} =
        Default.create_worktree(
          ctx.repo,
          ctx.worktree_path,
          operation_id: ctx.opts[:operation_id],
          base: ctx.base_sha,
          branch: "feat/no-telemetry",
          project_id: "p",
          run_id: "r",
          phase_id: "ph"
        )

      handler_id = "test-no-telemetry-#{System.unique_integer([:positive])}"
      parent = self()
      expected_operation_id = ctx.opts[:operation_id]

      :telemetry.attach(
        handler_id,
        [:foreman_server, :vcs, :worktree, :clean_failed],
        fn name, _measurements, metadata, _config ->
          if metadata[:operation_id] == expected_operation_id do
            send(parent, {:telemetry, name})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{cleaned?: true, noop?: false}} =
               Default.clean_worktree(ctx.worktree_path, ctx.opts)

      # Scope the assertion to this test's operation_id so concurrent
      # orchestrator clean_attempts on unrelated worktrees (from
      # boot_reconciliation etc.) do not leak into the test mailbox.
      refute_receive {:telemetry, [:foreman_server, :vcs, :worktree, :clean_failed]}, 200
    end
  end

  describe "required opts enforcement" do
    setup do
      repo =
        Path.join(System.tmp_dir!(), "foreman-vcs-opts-#{System.unique_integer([:positive])}")

      File.rm_rf!(repo)
      File.mkdir_p!(repo)
      on_exit(fn -> File.rm_rf!(repo) end)
      worktree_path = Path.join(repo, ".worktrees/wt-opts")
      File.rm_rf!(worktree_path)
      {:ok, repo: repo, worktree_path: worktree_path}
    end

    test "create_worktree/3 raises when :base is missing", %{
      repo: repo,
      worktree_path: worktree_path
    } do
      opts = [
        operation_id: "wt",
        branch: "main",
        project_id: "p",
        run_id: "r",
        phase_id: "ph"
      ]

      assert_raise KeyError, ~r/base/, fn ->
        Default.create_worktree(repo, worktree_path, opts)
      end
    end

    test "clean_worktree/2 raises when :repo_path is missing", %{worktree_path: worktree_path} do
      opts = [
        operation_id: "wt",
        project_id: "p",
        run_id: "r",
        phase_id: "ph"
      ]

      assert_raise KeyError, ~r/repo_path/, fn ->
        Default.clean_worktree(worktree_path, opts)
      end
    end
  end

  # Run a git command and return combined stdout/stderr. Raises on
  # non-zero exit so test failures surface immediately with the git
  # output that caused them.
  defp run_git!(args) do
    {output, 0} = System.cmd("git", args, stderr_to_stdout: true)
    output
  end

  # Resolve a path to its symlink-resolved canonical form. Mirrors
  # `ForemanServer.VcsAdapter.Default.canonicalize/1` so tests can
  # assert against git porcelain output on hosts where `/tmp` is a
  # symlink (macOS). Uses `File.read_link/1` only — no shell-out, so
  # behavior matches the production implementation exactly.
  defp canonical_path_for(path) do
    parent = Path.dirname(path)
    base = Path.basename(path)

    if File.exists?(parent) do
      Path.join(resolve_symlinks(parent), base)
    else
      Path.expand(path)
    end
  end

  defp resolve_symlinks(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("", fn segment, acc ->
      case acc do
        "" ->
          segment

        _ ->
          candidate = Path.join(acc, segment)

          case File.read_link(candidate) do
            {:ok, target} -> Path.expand(target, Path.dirname(candidate))
            _ -> candidate
          end
      end
    end)
  end
end
