defmodule ForemanServerWeb.OperatorDashboardTestGateway do
  def dispatch_operator(envelope) do
    send(
      Application.fetch_env!(:foreman_server, :operator_dashboard_test_pid),
      {:dashboard_command, envelope}
    )

    {:ok, %{accepted: true}}
  end
end

defmodule ForemanServerWeb.OperatorDashboardRejectingGateway do
  def dispatch_operator(envelope) do
    send(
      Application.fetch_env!(:foreman_server, :operator_dashboard_test_pid),
      {:dashboard_command, envelope}
    )

    {:error, {:phase_terminal, envelope.payload.run_id}}
  end
end

defmodule ForemanServerWeb.OperatorDashboardTest do
  use ForemanServerWeb.ConnCase, async: false

  alias ForemanServer.CommandGateway
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServerWeb.OperatorDashboard

  @token "operator-dashboard-test-token"

  setup do
    ProjectionStoreReset.reset!()
    previous_token = Application.get_env(:foreman_server, :api_bearer_token)
    previous_gateway = Application.get_env(:foreman_server, :command_gateway_module)
    previous_pid = Application.get_env(:foreman_server, :operator_dashboard_test_pid)

    Application.put_env(:foreman_server, :api_bearer_token, @token)
    Application.put_env(:foreman_server, :operator_dashboard_test_pid, self())

    on_exit(fn ->
      ProjectionStoreReset.reset!()
      restore_env(:api_bearer_token, previous_token)
      restore_env(:command_gateway_module, previous_gateway)
      restore_env(:operator_dashboard_test_pid, previous_pid)
    end)

    :ok
  end

  test "dashboard route is authenticated, separate from existing /dashboard, and renders empty state" do
    assert build_conn() |> get("/dashboard/runs") |> response(401) == "unauthorized"

    conn = build_conn() |> get("/dashboard/runs?token=#{@token}")
    assert html_response(conn, 200) =~ "Operator Run Dashboard"
    assert html_response(conn, 200) =~ "No runs found."

    jido = build_conn() |> get("/dashboard?token=#{@token}")
    assert html_response(jido, 200) =~ "Jido Live Dashboard"
  end

  # foreman-70eq6: the page used to render with no root layout, so axe found no
  # <title> and no <html lang>, and no client script loaded: every phx-click and
  # phx-submit on it was dead in a browser.
  test "the run dashboard has the shared root layout: title, lang, LiveSocket bootstrap, skip target" do
    html = build_conn() |> get("/dashboard/runs?token=#{@token}") |> html_response(200)

    assert html =~ ~s(<html lang="en")
    assert html =~ "<title>Operator Run Dashboard</title>"
    assert html =~ ~s(<script src="/assets/vendor/phoenix_live_view.min.js")
    assert html =~ ~s(new window.LiveView.LiveSocket("/live")
    assert html =~ ~s(<a class="ws-skip" href="#main">)
    assert html =~ ~s(<main id="main")
  end

  test "list and detail DTOs use projections, durable logs, phase status, absent markers, and truncation metadata" do
    seed_run("run-dashboard", status: "in_progress")

    assert {:ok, [row]} = OperatorDashboard.list_runs(%{"limit" => "9999"})
    assert row.run_id == "run-dashboard"
    assert row.project_id == "project-1"
    assert row.workflow == "plan"
    assert row.task_label == "ad-hoc run"
    assert row.current_phase_name == "implement"
    assert row.actions.stop.enabled == true
    assert row.actions.resume.enabled == false

    assert {:ok, detail} = OperatorDashboard.run_detail("run-dashboard")
    assert detail.run.run_id == "run-dashboard"
    assert [%{name: "implement", status: "in_progress"}] = detail.phases
    assert {:ok, logs} = detail.logs
    assert logs.count == 1
    assert hd(logs.entries).content == "hello operator"
    assert logs.truncated == false

    assert {:error, :run_not_found} = OperatorDashboard.run_detail("missing")
    assert {:error, :run_not_found} = OperatorDashboard.run_logs("missing")
  end

  # Production dispatch puts the name on the frozen snapshot only: the `run.start` payload
  # `Workflow.Dispatcher` sends has no top-level `workflow_name`, so the run projection keeps
  # nil and a DTO that read only that field reported `:absent` for every real run.
  test "a dispatched run's DTO takes its workflow name from the frozen snapshot" do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunStarted",
          payload: %{
            run_id: "run-dispatched",
            project_id: "project-1",
            workflow_snapshot: %{run_id: "run-dispatched", workflow_name: "prd", phases: []}
          }
        }
      ])

    assert %{workflow_name: nil, workflow_snapshot: %{workflow_name: "prd"}} =
             ProjectionStore.run("run-dispatched")

    assert {:ok, rows} = OperatorDashboard.list_runs(%{"limit" => "9999"})
    assert %{workflow: "prd"} = Enum.find(rows, &(&1.run_id == "run-dispatched"))
  end

  test "a run with neither a workflow name nor a snapshot name reports :absent" do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "RunStarted",
          payload: %{run_id: "run-nameless", project_id: "project-1", workflow_snapshot: %{}}
        }
      ])

    assert {:ok, rows} = OperatorDashboard.list_runs(%{"limit" => "9999"})
    assert %{workflow: :absent} = Enum.find(rows, &(&1.run_id == "run-nameless"))
  end

  test "run actions dispatch exact command gateway envelopes and stop defaults to operator_pause" do
    Application.put_env(
      :foreman_server,
      :command_gateway_module,
      ForemanServerWeb.OperatorDashboardTestGateway
    )

    assert {:ok, %{command: command}} = OperatorDashboard.pause_run("run-1", "   ")
    assert command.type == "run.pause"
    assert command.aggregate_id == "run:run-1"
    assert command.payload.run_id == "run-1"
    assert command.payload.reason == "operator_pause"
    assert command.payload.actor == "operator_dashboard"
    assert_receive {:dashboard_command, ^command}

    assert {:ok, %{command: resume}} = OperatorDashboard.resume_run("run-1", "operator says go")
    assert resume.type == "run.resume"
    assert resume.payload.reason == "operator says go"
  end

  test "operator gateway validates pause and resume run aggregate ids before dispatch" do
    for type <- ["run.pause", "run.resume"] do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 type: type,
                 command_id: "dashboard-test-#{type}",
                 aggregate_id: "run:other",
                 payload: %{run_id: "run-1", reason: "operator"}
               })
    end
  end

  test "rejected command returns typed reason while preserving envelope" do
    Application.put_env(
      :foreman_server,
      :command_gateway_module,
      ForemanServerWeb.OperatorDashboardRejectingGateway
    )

    assert {:error, {:phase_terminal, "run-2"}, envelope} = OperatorDashboard.reset_run("run-2")
    assert envelope.type == "run.reset"
    assert_receive {:dashboard_command, ^envelope}
  end

  test "change evidence uses retained worktree and rejects missing worktree as typed unavailable" do
    tmp = Path.join(System.tmp_dir!(), "operator-dashboard-#{System.unique_integer([:positive])}")

    try do
      File.rm_rf!(tmp)
      File.mkdir_p!(tmp)

      {_, 0} = System.cmd("git", ["init"], cd: tmp)
      File.write!(Path.join(tmp, "README.md"), "base\n")
      {_, 0} = System.cmd("git", ["add", "README.md"], cd: tmp)

      {_, 0} =
        System.cmd(
          "git",
          ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "base"],
          cd: tmp
        )

      {base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)
      File.write!(Path.join(tmp, "README.md"), "changed\n")

      {_, 0} =
        System.cmd(
          "git",
          [
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-am",
            "change"
          ],
          cd: tmp
        )

      seed_run("run-evidence",
        status: "completed",
        worktree_path: tmp,
        base_ref: String.trim(base)
      )

      assert {:ok, %{state: :available, files: files}} =
               OperatorDashboard.change_evidence("run-evidence")

      assert [%{path: "README.md", status: "M"}] = files

      seed_run("run-no-worktree", status: "completed")

      assert {:ok, %{state: :worktree_missing}} =
               OperatorDashboard.change_evidence("run-no-worktree")
    after
      File.rm_rf!(tmp)
    end
  end

  describe "list_runs/1 detail option" do
    setup do
      for id <- ["run-a", "run-b", "run-c"], do: seed_run(id, status: "completed")

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "PhaseStarted",
            payload: %{
              phase_id: "run-a-phase-2",
              run_id: "run-a",
              index: 2,
              name: "review",
              attempt: 1,
              artifact_template: "artifact.md"
            }
          }
        ])

      :ok
    end

    test ":full (explicit and default) derives the current phase and a boolean completed_with_errors" do
      assert {:ok, default_rows} = OperatorDashboard.list_runs(%{})
      assert {:ok, full_rows} = OperatorDashboard.list_runs(%{detail: :full})
      assert default_rows == full_rows

      row = Enum.find(full_rows, &(&1.run_id == "run-a"))
      assert row.current_phase_id == "run-a-phase-1"
      assert row.current_phase_name == "implement"
      assert row.current_phase_status == "in_progress"
      assert row.completed_with_errors == false
      assert Enum.all?(full_rows, &is_boolean(&1.completed_with_errors))
    end

    test ":summary carries :absent in the derived fields and equals :full elsewhere" do
      assert {:ok, full_rows} = OperatorDashboard.list_runs(%{detail: :full})
      assert {:ok, summary_rows} = OperatorDashboard.list_runs(%{detail: :summary})
      assert length(summary_rows) == 3

      for summary <- summary_rows do
        assert summary.current_phase_id == :absent
        assert summary.current_phase_name == :absent
        assert summary.current_phase_status == :absent
        assert summary.latest_stall == :absent
        assert summary.completed_with_errors == :absent

        full = Enum.find(full_rows, &(&1.run_id == summary.run_id))

        for field <- [:run_id, :status, :workflow, :task_id, :pr_url] do
          assert Map.fetch!(summary, field) == Map.fetch!(full, field)
        end
      end
    end

    test ":summary never reads phases or repositories; :full reads them once per run" do
      assert {3, %{phases: 3, repos: 3}} = count_derived_reads(%{detail: :full})
      assert {3, %{phases: 0, repos: 0}} = count_derived_reads(%{detail: :summary})
    end

    test "an unknown detail is a typed error" do
      assert {:error, {:malformed_detail, "bogus"}} =
               OperatorDashboard.list_runs(%{detail: "bogus"})
    end
  end

  describe "bounded change evidence" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "operator-evidence-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "preview returns the patch of a changed file", %{tmp: tmp} do
      seed_evidence_run(tmp, %{"README.md" => "changed\n"})

      assert {:ok, %{diff: diff, truncated?: false, bytes: bytes}} =
               OperatorDashboard.preview_bounded("run-evidence", "README.md")

      assert diff =~ "+changed"
      assert bytes == byte_size(diff)

      assert {:ok, %{files: [%{path: "README.md"}]}} =
               OperatorDashboard.change_evidence_bounded("run-evidence")
    end

    test "a patch over the byte cap is cut on a UTF-8 boundary at both parities", %{tmp: tmp} do
      seed_evidence_run(tmp, %{
        "e1.txt" => String.duplicate("é", 20_000) <> "\n",
        "e2.txt" => "a" <> String.duplicate("é", 20_000) <> "\n"
      })

      {full1, 0} = System.cmd("git", ["diff", "HEAD~1..HEAD", "--", "e1.txt"], cd: tmp)
      assert byte_size(full1) > 24_000

      previews =
        for path <- ["e1.txt", "e2.txt"] do
          assert {:ok, %{diff: diff, truncated?: true, bytes: bytes}} =
                   OperatorDashboard.preview_bounded("run-evidence", path)

          assert byte_size(diff) <= 24_000
          assert String.valid?(diff)
          assert bytes > 24_000
          {path, diff, bytes}
        end

      assert {_, _, bytes1} = Enum.find(previews, &(elem(&1, 0) == "e1.txt"))
      assert bytes1 == byte_size(full1)
      # exactly one of the two offsets lands mid-character, so one cut was trimmed below the cap
      assert Enum.any?(previews, fn {_, diff, _} -> byte_size(diff) < 24_000 end)
    end

    test "a patch that is not UTF-8 previews as valid UTF-8, under and over the byte cap", %{
      tmp: tmp
    } do
      # Latin-1 bytes: a lone 0xE9 is not a UTF-8 sequence, and `git diff` passes it through.
      seed_evidence_run(tmp, %{
        "small.txt" => "caf" <> <<0xE9>> <> "\n",
        "big.txt" => String.duplicate(<<0xE9>>, 30_000) <> "\n"
      })

      {raw, 0} = System.cmd("git", ["diff", "HEAD~1..HEAD", "--", "small.txt"], cd: tmp)
      refute String.valid?(raw)

      assert {:ok, %{diff: small, truncated?: false, bytes: small_bytes}} =
               OperatorDashboard.preview_bounded("run-evidence", "small.txt")

      assert String.valid?(small)
      assert small =~ "caf"
      assert small_bytes == byte_size(small)
      assert {:ok, _json} = Jason.encode(small)

      assert {:ok, %{diff: big, truncated?: true}} =
               OperatorDashboard.preview_bounded("run-evidence", "big.txt")

      assert String.valid?(big)
      assert byte_size(big) <= 24_000
      assert {:ok, _json} = Jason.encode(big)
    end

    test "a traversal path is :malformed_path and starts no git process", %{tmp: tmp} do
      seed_evidence_run(tmp, %{"README.md" => "changed\n"})
      log = install_fake_git(tmp, "")

      assert {:error, :malformed_path} =
               OperatorDashboard.preview_bounded("run-evidence", "../../etc/passwd")

      assert {:error, :malformed_path} =
               OperatorDashboard.preview_bounded("run-evidence", "/etc/passwd")

      refute File.exists?(log)
    end

    test "a file not among the changed files, and an unknown run, are :unavailable", %{tmp: tmp} do
      seed_evidence_run(tmp, %{"README.md" => "changed\n"})

      assert {:error, :unavailable} =
               OperatorDashboard.preview_bounded("run-evidence", "other.md")

      assert {:error, :unavailable} =
               OperatorDashboard.preview_bounded("no-such-run", "README.md")
    end

    test "a hung git is cut off at timeout_ms with :evidence_timeout and its task is gone", %{
      tmp: tmp
    } do
      seed_evidence_run(tmp, %{"README.md" => "changed\n"})
      log = install_fake_git(tmp, "sleep 5\n")
      before = MapSet.new(Process.list())

      # A 1 s budget leaves the shim ample time to start under load, so "git ran" is not a race.
      {micros, result} =
        :timer.tc(fn -> OperatorDashboard.change_evidence_bounded("run-evidence", 1_000) end)

      assert result == {:error, :evidence_timeout}
      assert micros < 3_000_000
      # git really started: the result is the timeout, not an early failure
      assert File.exists?(log)
      assert spawned_by_test_and_alive(before) == []

      before = MapSet.new(Process.list())

      assert {:error, :evidence_timeout} =
               OperatorDashboard.preview_bounded("run-evidence", "README.md", 1_000)

      assert spawned_by_test_and_alive(before) == []
      # the task was shut down: no late reply reaches the caller
      refute_receive {_ref, _result}, 200
    end
  end

  describe "planning documents" do
    alias ForemanServerWeb.OperatorDashboard.ChangeEvidence

    setup do
      tmp =
        Path.join(System.tmp_dir!(), "operator-planning-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "a prd-shaped branch yields exactly the PRD and TRD", %{tmp: tmp} do
      seed_evidence_run(tmp, %{
        "docs/PRD/PRD-a.md" => "prd\n",
        "docs/TRD/TRD-a.md" => "trd\n",
        "README.md" => "changed\n"
      })

      assert {:ok, docs} = OperatorDashboard.planning_documents_bounded("run-evidence", nil)

      assert Enum.sort_by(docs, & &1.path) == [
               %{kind: :prd, path: "docs/PRD/PRD-a.md"},
               %{kind: :trd, path: "docs/TRD/TRD-a.md"}
             ]
    end

    test "a run that changed only code has no documents", %{tmp: tmp} do
      seed_evidence_run(tmp, %{"lib/x.ex" => "x\n"})
      assert {:ok, []} = OperatorDashboard.planning_documents_bounded("run-evidence", nil)
    end

    test "extra_path is returned only when among the changed files", %{tmp: tmp} do
      seed_evidence_run(
        tmp,
        %{"docs/TRD/changed-plan.md" => "new\n"},
        base: %{"docs/TRD/pre-existing.md" => "old\n"}
      )

      assert {:ok, []} =
               OperatorDashboard.planning_documents_bounded(
                 "run-evidence",
                 "docs/TRD/pre-existing.md"
               )

      assert {:ok, [%{kind: :trd, path: "docs/TRD/changed-plan.md"}]} =
               OperatorDashboard.planning_documents_bounded(
                 "run-evidence",
                 "docs/TRD/changed-plan.md"
               )
    end

    test "a deleted document is dropped", %{tmp: tmp} do
      seed_evidence_run(tmp, %{"docs/TRD/TRD-new.md" => "n\n"},
        base: %{"docs/TRD/old.md" => "o\n", "docs/TRD/TRD-old.md" => "o\n"},
        delete: ["docs/TRD/old.md", "docs/TRD/TRD-old.md"]
      )

      assert {:ok, [%{kind: :trd, path: "docs/TRD/TRD-new.md"}]} =
               OperatorDashboard.planning_documents_bounded("run-evidence", "docs/TRD/old.md")
    end

    test "a run without a worktree and an unknown run are unavailable" do
      seed_run("run-bare", status: "completed")

      assert {:unavailable, :worktree_missing} =
               OperatorDashboard.planning_documents_bounded("run-bare", nil)

      assert {:unavailable, :run_not_found} =
               OperatorDashboard.planning_documents_bounded("no-such-run", nil)
    end

    test "a hung git is cut off with :evidence_timeout", %{tmp: tmp} do
      seed_evidence_run(tmp, %{"docs/PRD/PRD-a.md" => "prd\n"})
      install_fake_git(tmp, "sleep 5\n")

      {micros, result} =
        :timer.tc(fn ->
          OperatorDashboard.planning_documents_bounded("run-evidence", nil, 100)
        end)

      assert result == {:unavailable, :evidence_timeout}
      assert micros < 1_000_000
      refute_receive {_ref, _result}, 200
    end

    test "selection never returns an unsafe path or a deleted status" do
      files =
        for {status, path} <- [
              {"A", "../docs/PRD/PRD-x.md"},
              {"A", "/abs/docs/TRD/TRD-x.md"},
              {"A", "docs/TRD/../../etc/TRD-x.md"},
              {"A", "docs/PRD/PRD-ok.md"},
              {"D", "docs/PRD/PRD-gone.md"},
              {"R100", "docs/TRD/TRD-renamed.md"}
            ],
            do: %{status: status, path: path, source: :worktree}

      assert ChangeEvidence.select_planning_documents(files, "../etc/passwd") == [
               %{kind: :prd, path: "docs/PRD/PRD-ok.md"},
               %{kind: :trd, path: "docs/TRD/TRD-renamed.md"}
             ]
    end
  end

  # Records every invocation (one line per call) in `<dir>/git.log`, runs `body`, and is placed
  # first on PATH until the test exits. Returns the log path.
  defp install_fake_git(tmp, body) do
    bin = Path.join(tmp, "fakebin")
    log = Path.join(tmp, "git.log")
    File.mkdir_p!(bin)
    script = Path.join(bin, "git")
    File.write!(script, "#!/bin/sh\necho \"$@\" >> '#{log}'\n#{body}")
    File.chmod!(script, 0o755)

    previous = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> previous)
    on_exit(fn -> System.put_env("PATH", previous) end)
    log
  end

  # Processes started since `before` that are still alive and descend from the calling test:
  # `Task.async` records its caller in `$ancestors`, so a bounded read that leaked its task
  # would show up here. (The OS `git` child of a killed port is not an Erlang process and
  # survives the kill: a known limitation, TRD finding F13.)
  defp spawned_by_test_and_alive(before) do
    me = self()

    for pid <- Process.list(),
        not MapSet.member?(before, pid),
        {:dictionary, dict} <- [Process.info(pid, :dictionary)],
        me in Keyword.get(dict, :"$ancestors", []),
        do: pid
  end

  # A git repo with a README base commit and one commit adding/changing `files`, registered as
  # the retained worktree of run "run-evidence".
  defp seed_evidence_run(tmp, files, opts \\ []) do
    git = fn args -> {_, 0} = System.cmd("git", args, cd: tmp, stderr_to_stdout: true) end
    ident = ["-c", "user.name=Test", "-c", "user.email=test@example.com"]

    write = fn name, content ->
      File.mkdir_p!(Path.dirname(Path.join(tmp, name)))
      File.write!(Path.join(tmp, name), content)
    end

    git.(["init"])
    write.("README.md", "base\n")
    for {name, content} <- Keyword.get(opts, :base, %{}), do: write.(name, content)
    git.(["add", "."])
    git.(ident ++ ["commit", "-m", "base"])
    {base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)

    for {name, content} <- files, do: write.(name, content)
    for name <- Keyword.get(opts, :delete, []), do: File.rm!(Path.join(tmp, name))
    git.(["add", "-A"])
    git.(ident ++ ["commit", "-m", "change"])

    seed_run("run-evidence", status: "completed", worktree_path: tmp, base_ref: String.trim(base))
  end

  # Counts the calls this process makes to the two per-run projection reads, via call tracing
  # reported to a separate tracer process (a process cannot be traced by itself).
  defp count_derived_reads(params) do
    parent = self()
    tracer = spawn_link(fn -> tracer_loop(%{phases: 0, repos: 0}) end)

    :erlang.trace_pattern({ProjectionStore, :phases_for_run, 1}, true, [:global])
    :erlang.trace_pattern({ProjectionStore, :run_repositories, 1}, true, [:global])
    :erlang.trace(parent, true, [:call, {:tracer, tracer}])

    try do
      {:ok, rows} = OperatorDashboard.list_runs(params)
      ref = :erlang.trace_delivered(parent)
      assert_receive {:trace_delivered, ^parent, ^ref}
      send(tracer, {:report, parent})
      assert_receive {:counts, counts}
      {length(rows), counts}
    after
      :erlang.trace(parent, false, [:call])
      :erlang.trace_pattern({ProjectionStore, :phases_for_run, 1}, false, [:global])
      :erlang.trace_pattern({ProjectionStore, :run_repositories, 1}, false, [:global])
    end
  end

  defp tracer_loop(acc) do
    receive do
      {:trace, _pid, :call, {ProjectionStore, :phases_for_run, _}} ->
        tracer_loop(%{acc | phases: acc.phases + 1})

      {:trace, _pid, :call, {ProjectionStore, :run_repositories, _}} ->
        tracer_loop(%{acc | repos: acc.repos + 1})

      {:report, from} ->
        send(from, {:counts, acc})
        tracer_loop(acc)
    end
  end

  defp seed_run(run_id, opts) do
    status = Keyword.get(opts, :status, "awaiting_worker")

    events =
      [
        %{
          event_type: "RunStarted",
          payload: %{run_id: run_id, project_id: "project-1", workflow_name: "plan"}
        },
        %{
          event_type: "PhaseStarted",
          payload: %{
            phase_id: "#{run_id}-phase-1",
            run_id: run_id,
            index: 1,
            name: "implement",
            attempt: 1,
            artifact_template: "artifact.md"
          }
        },
        %{
          event_type: "WorkerStdout",
          payload: %{
            run_id: run_id,
            worker_id: "worker-1",
            sequence: 1,
            line: "hello operator",
            timestamp: "2026-09-23T00:00:00Z"
          }
        }
      ] ++ worktree_events(run_id, opts)

    assert :ok = ProjectionStore.apply_events(events)

    :sys.replace_state(ProjectionStore, fn state ->
      update_in(state, [:runs, run_id], fn run ->
        %{run | status: status, terminal?: status in ["completed", "failed"]}
      end)
    end)
  end

  defp worktree_events(run_id, opts) do
    case Keyword.get(opts, :worktree_path) do
      nil ->
        []

      path ->
        [
          %{
            event_type: "WorktreeCreated",
            payload: %{
              operation_id: "wt-#{run_id}",
              project_id: "project-1",
              run_id: run_id,
              phase_id: "#{run_id}-phase-1",
              worktree_path: path,
              base_ref: Keyword.fetch!(opts, :base_ref),
              branch: "foreman/#{run_id}"
            }
          }
        ]
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore_env(key, value), do: Application.put_env(:foreman_server, key, value)
end
