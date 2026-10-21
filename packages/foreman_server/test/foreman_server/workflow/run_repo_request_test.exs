defmodule ForemanServer.Workflow.RunRepoRequestTest do
  @moduledoc """
  E12-S10: a thread adds a repository to its own run (`run.repo.request`).
  Real git repositories, the production worktree path and the real project
  aggregate. Run worktrees live under `~/.foreman/worktrees/<project>`; each
  test uses a unique project id and removes that directory on exit.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.RunRepoAudit

  alias ForemanServer.{
    CommandGateway,
    CommandRouter,
    MultiRepoRuns,
    ProjectionStore,
    ProjectStore
  }

  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.{RunExecutor, RunWorktreeLayout}

  setup do
    ProjectionStoreReset.reset!()
    MultiRepoRuns.enable!()

    root =
      Path.join(System.tmp_dir!(), "run-repo-req-#{System.unique_integer([:positive])}")
      |> realpath()

    allowed = Path.join(root, "allowed")
    File.mkdir_p!(allowed)
    project_id = "proj-rr-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      ProjectionStoreReset.reset!()
      File.rm_rf(root)
      File.rm_rf(Path.join(RunWorktreeLayout.base_root(), project_id))
    end)

    primary = git_repo(root, "primary")
    assert {:ok, _} = ProjectStore.save(%{project_id: project_id, path: primary})

    b = git_repo(allowed, "b")
    add_repo!(project_id, "b", b)

    run_id = "run-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    seed_run!(run_id, project_id)

    state = %{
      task: %{project_id: project_id, task_id: "task-1"},
      run_id: run_id,
      worktree_spec: %{},
      plan_context: nil,
      artifact_base: Path.join(root, "artifacts")
    }

    assert {:ok, _primary} = RunExecutor.__create_run_worktree_for_test__(state, 1)

    %{
      root: root,
      allowed: allowed,
      project_id: project_id,
      run_id: run_id,
      b: b,
      primary: primary
    }
  end

  defp allow!(ctx, allowlist, cap \\ nil) do
    payload = %{repo_allowlist: allowlist, project_id: ctx.project_id}
    payload = if cap, do: Map.put(payload, :max_repos_per_run, cap), else: payload

    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "allow-#{System.unique_integer([:positive])}",
               aggregate_id: "project:#{ctx.project_id}",
               type: "project.update",
               payload: payload
             })
  end

  defp request(ctx, target, command_id \\ nil) do
    CommandGateway.dispatch_system(%{
      type: "run.repo.request",
      command_id: command_id || "req-#{System.unique_integer([:positive])}",
      aggregate_id: "run:#{ctx.run_id}",
      payload: Map.merge(%{run_id: ctx.run_id, requested_by: "run:#{ctx.run_id}"}, target)
    })
  end

  defp audits(ctx) do
    case ForemanServer.EventStore.read_stream_forward("run_repo_audit:" <> ctx.run_id, 0, 1000) do
      {:ok, events} -> Enum.map(events, &event_data/1)
      {:error, _} -> []
    end
  end

  defp created_repo_ids(ctx) do
    for %{repo_id: id, status: "created"} <- ProjectionStore.worktrees_for_run(ctx.run_id),
        is_binary(id),
        do: id
  end

  describe "allowlist" do
    test "an empty allowlist denies registered and unregistered repos and audits both", ctx do
      c = git_repo(ctx.allowed, "c")

      assert {:error, {:repo_not_allowed, _}} = request(ctx, %{repo_id: "b"})
      assert {:error, {:repo_not_allowed, ^c}} = request(ctx, %{repo_path: c})

      assert created_repo_ids(ctx) == []
      assert ProjectionStore.project_repository(ctx.project_id, "c") == nil

      assert [first, second] = audits(ctx)
      assert %{"decision" => "denied", "reason" => "allowlist_empty", "repo_id" => "b"} = first

      assert %{"decision" => "denied", "reason" => "allowlist_empty", "requested_path" => ^c} =
               second

      assert first["requested_by"] == "run:" <> ctx.run_id
    end

    test "a registered repo inside the allowlist is attached next to the primary", ctx do
      allow!(ctx, [ctx.allowed])

      assert {:ok, %{repo_id: "b", status: "attached", effective: "next_phase"}} =
               request(ctx, %{repo_id: "b"})

      assert created_repo_ids(ctx) == ["b"]

      run_dir = RunWorktreeLayout.run_root(ctx.project_id, "task-1", ctx.run_id)
      assert File.dir?(Path.join([run_dir, "repos", "b"]))

      assert [%{"decision" => "allowed", "reason" => "attached", "repo_id" => "b"}] = audits(ctx)

      assert %{worktree: %{operation_id: op}} =
               ctx.run_id
               |> ProjectionStore.run_repositories()
               |> Enum.find(&(&1.repo_id == "b"))

      assert op == "wt-#{ctx.run_id}-b"
    end

    test "a symlink inside the allowlist that escapes it is denied", ctx do
      outside = git_repo(ctx.root, "outside")
      link = Path.join(ctx.allowed, "link")
      File.ln_s!(outside, link)
      allow!(ctx, [ctx.allowed])

      assert {:error, {:repo_not_allowed, ^link}} = request(ctx, %{repo_path: link})
      assert ProjectionStore.project_repository(ctx.project_id, "outside") == nil
      assert ProjectionStore.project_repository(ctx.project_id, "link") == nil

      assert [%{"decision" => "denied", "reason" => "not_in_allowlist"}] = audits(ctx)
    end

    test "a registered repo outside the allowlist is denied", ctx do
      allow!(ctx, [Path.join(ctx.allowed, "nested")])

      assert {:error, {:repo_not_allowed, _}} = request(ctx, %{repo_id: "b"})
    end

    test "/srv/repos does not match /srv/repos-evil", ctx do
      evil = git_repo(Path.join(ctx.root, "allowed-evil"), "e")
      allow!(ctx, [ctx.allowed])

      assert {:error, {:repo_not_allowed, ^evil}} = request(ctx, %{repo_path: evil})
      assert [%{"decision" => "denied", "reason" => "not_in_allowlist"}] = audits(ctx)
    end

    test "a symlinked allowlist entry matches by its real target", ctx do
      via = Path.join(ctx.root, "via")
      File.ln_s!(ctx.allowed, via)
      allow!(ctx, [via])

      assert {:ok, %{status: "attached"}} = request(ctx, %{repo_id: "b"})
    end

    test "a relative or missing path is denied and audited", ctx do
      allow!(ctx, [ctx.allowed])
      missing = Path.join(ctx.allowed, "nope")

      assert {:error, {:repo_not_allowed, "rel/path"}} = request(ctx, %{repo_path: "rel/path"})
      assert {:error, {:repo_not_allowed, ^missing}} = request(ctx, %{repo_path: missing})

      assert [%{"reason" => "path_not_absolute"}, %{"reason" => "path_unresolvable"}] =
               audits(ctx)
    end
  end

  describe "registering an unregistered path" do
    test "inside the allowlist and a git work tree: added by the run, then attached", ctx do
      c = git_repo(ctx.allowed, "c")
      allow!(ctx, [ctx.allowed])

      assert {:ok, %{repo_id: "c", status: "registered_and_attached"}} =
               request(ctx, %{repo_path: c})

      assert %{path: ^c, added_by: added_by} =
               ProjectionStore.project_repository(ctx.project_id, "c")

      assert added_by == "run:" <> ctx.run_id
      assert created_repo_ids(ctx) == ["c"]

      assert [%{"decision" => "allowed", "reason" => "registered_and_attached"}] = audits(ctx)
    end

    test "a directory that is not a git work tree is denied and not registered", ctx do
      plain = Path.join(ctx.allowed, "plain")
      File.mkdir_p!(plain)
      allow!(ctx, [ctx.allowed])

      assert {:error, {:repo_not_git_work_tree, ^plain}} = request(ctx, %{repo_path: plain})
      assert ProjectionStore.project_repository(ctx.project_id, "plain") == nil
      assert [%{"decision" => "denied", "reason" => "repo_not_git_work_tree"}] = audits(ctx)
    end

    test "a checkout sharing another repository's remote is denied", ctx do
      remote = "https://example.com/org/dup.git"
      git!(ctx.b, ["remote", "add", "origin", remote])
      dup = git_repo(ctx.allowed, "dup")
      git!(dup, ["remote", "add", "origin", remote])
      allow!(ctx, [ctx.allowed])

      assert {:error, {:repo_remote_duplicate, "b"}} = request(ctx, %{repo_path: dup})
      assert ProjectionStore.project_repository(ctx.project_id, "dup") == nil
    end

    test "the path of an already registered repo is the registered branch", ctx do
      allow!(ctx, [ctx.allowed])

      assert {:ok, %{repo_id: "b", status: "attached"}} = request(ctx, %{repo_path: ctx.b})
      assert ProjectionStore.project_repositories(ctx.project_id) |> length() == 2
    end
  end

  describe "idempotence and cap" do
    test "re-requesting an attached repo succeeds without a second worktree, even at the cap",
         ctx do
      allow!(ctx, [ctx.allowed], 2)

      assert {:ok, %{status: "attached"}} = request(ctx, %{repo_id: "b"})
      # primary + b == cap: a retry must not hit :max_repos_exceeded.
      assert {:ok, %{status: "already_attached"}} = request(ctx, %{repo_id: "b"})
      assert {:ok, %{status: "already_attached"}} = request(ctx, %{repo_path: ctx.b})

      assert created_repo_ids(ctx) == ["b"]
      assert [%{"reason" => "attached"}, %{"reason" => "already_attached"}, _] = audits(ctx)
    end

    test "the run's own primary is already attached", ctx do
      allow!(ctx, [ctx.root], 1)

      assert {:ok, %{repo_id: "main", status: "already_attached"}} =
               request(ctx, %{repo_path: ctx.primary})

      assert created_repo_ids(ctx) == []
    end

    test "a new attachment beyond max_repos_per_run (primary counts) is denied", ctx do
      c = git_repo(ctx.allowed, "c")
      allow!(ctx, [ctx.allowed], 2)

      assert {:ok, _} = request(ctx, %{repo_id: "b"})
      assert {:error, {:max_repos_exceeded, 2}} = request(ctx, %{repo_path: c})
      # The cap is checked before registering: c stays unregistered.
      assert ProjectionStore.project_repository(ctx.project_id, "c") == nil
      assert [_, %{"decision" => "denied", "reason" => "max_repos_exceeded"}] = audits(ctx)
    end

    test "while the multi-repo gate is closed a new attachment is denied, nothing registered",
         ctx do
      Application.put_env(:foreman_server, :multi_repo, runs: false)
      c = git_repo(ctx.allowed, "c")
      allow!(ctx, [ctx.root])

      assert {:error, :multi_repo_runs_disabled} = request(ctx, %{repo_id: "b"})
      assert {:error, :multi_repo_runs_disabled} = request(ctx, %{repo_path: c})

      assert created_repo_ids(ctx) == []
      assert ProjectionStore.project_repository(ctx.project_id, "c") == nil
      assert [%{"reason" => "multi_repo_runs_disabled"}, _] = audits(ctx)

      # The run's own primary is not a new attachment.
      assert {:ok, %{status: "already_attached"}} = request(ctx, %{repo_path: ctx.primary})
    end

    test "with cap 1 nothing can be attached", ctx do
      allow!(ctx, [ctx.allowed], 1)

      assert {:error, {:max_repos_exceeded, 1}} = request(ctx, %{repo_id: "b"})
      assert created_repo_ids(ctx) == []
    end

    test "a retried request keeps one audit event; a later request audits itself", ctx do
      allow!(ctx, [ctx.allowed])

      assert {:ok, _} = request(ctx, %{repo_id: "b"}, "req-same-#{ctx.run_id}")
      assert {:ok, _} = request(ctx, %{repo_id: "b"}, "req-same-#{ctx.run_id}")
      assert length(audits(ctx)) == 1

      assert {:ok, _} = request(ctx, %{repo_id: "b"}, "req-later-#{ctx.run_id}")
      assert length(audits(ctx)) == 2
    end
  end

  describe "preconditions" do
    test "an unknown run is an error with no audit stream", ctx do
      assert {:error, {:not_found, :run, "run-nope"}} =
               CommandGateway.dispatch_system(%{
                 type: "run.repo.request",
                 command_id: "req-x-#{System.unique_integer([:positive])}",
                 aggregate_id: "run:run-nope",
                 payload: %{run_id: "run-nope", repo_id: "b"}
               })

      assert audits(ctx) == []
    end

    test "a request naming neither repo_id nor repo_path is malformed", ctx do
      assert {:error, :repo_id_or_repo_path_required} = request(ctx, %{})
    end

    test "an unknown repo_id is denied and audited", ctx do
      allow!(ctx, [ctx.allowed])

      assert {:error, {:unknown_repo, "zzz"}} = request(ctx, %{repo_id: "zzz"})
      assert [%{"decision" => "denied", "reason" => "unknown_repo"}] = audits(ctx)
    end

    test "a finished run is refused", ctx do
      allow!(ctx, [ctx.allowed])

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "RunCompleted", payload: %{run_id: ctx.run_id}}
        ])

      assert {:error, {:run_terminal, _}} = request(ctx, %{repo_id: "b"})
    end

    test "run.repo.request is not an operator command", ctx do
      assert {:error, {:command_not_allowed, "run.repo.request"}} =
               CommandGateway.dispatch_operator(%{
                 type: "run.repo.request",
                 command_id: "op-#{System.unique_integer([:positive])}",
                 aggregate_id: "run:#{ctx.run_id}",
                 payload: %{run_id: ctx.run_id, repo_id: "b"}
               })
    end
  end

  describe "audit aggregate" do
    test "the prefix routes to the aggregate and the command validates its fields" do
      assert CommandRouter.aggregate_module_for("run_repo_audit:run-1") == RunRepoAudit

      valid = %{
        run_id: "run-1",
        project_id: "p",
        requested_path: "/x",
        decision: "denied",
        reason: "r",
        requested_by: "run:run-1"
      }

      assert {:ok, %{stream_id: "run_repo_audit:run-1", event_type: "RunRepoRequested"}} =
               RunRepoAudit.handle_command(RunRepoAudit.initial_state(), %{
                 type: "run.repo.audit.record",
                 payload: valid
               })

      assert {:error, {:invalid_decision, "maybe"}} =
               RunRepoAudit.handle_command(RunRepoAudit.initial_state(), %{
                 type: "run.repo.audit.record",
                 payload: %{valid | decision: "maybe"}
               })

      assert :unhandled = RunRepoAudit.handle_command(RunRepoAudit.initial_state(), %{type: "x"})
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp realpath(path) do
    File.mkdir_p!(path)
    {out, 0} = System.cmd("sh", ["-c", "cd \"$1\" && pwd -P", "sh", path])
    File.rm_rf!(path)
    String.trim(out)
  end

  defp git_repo(root, name) do
    repo = Path.join(root, name)
    File.mkdir_p!(repo)
    git!(repo, ["init", "--initial-branch=main", "--quiet"])
    git!(repo, ["config", "user.email", "t@x"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "seed")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-m", "seed", "--quiet"])
    repo
  end

  defp add_repo!(project_id, repo_id, path) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRepositoryAdded",
          payload: %{
            project_id: project_id,
            repo_id: repo_id,
            path: path,
            default_branch: nil,
            vcs: %{adapter: "git"},
            task_provider: nil,
            added_by: "operator:test",
            at: "2026-01-01T00:00:00Z"
          }
        }
      ])
  end

  defp seed_run!(run_id, project_id) do
    payload = %{run_id: run_id, project_id: project_id, task_id: "task-1"}

    :ok =
      ForemanServer.EventStore.append_to_stream("run:#{run_id}", 0, [
        %EventStore.EventData{event_type: "RunStarted", data: payload, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: "RunStarted", payload: payload}])
  end

  defp event_data(%{data: data}), do: data |> Jason.encode!() |> Jason.decode!()

  defp git!(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}) in #{dir}: #{out}")
    end
  end
end
