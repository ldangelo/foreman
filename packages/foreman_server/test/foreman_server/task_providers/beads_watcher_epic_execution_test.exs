defmodule ForemanServer.TaskProviders.BeadsWatcherEpicExecutionTest do
  @moduledoc """
  TRD-005-TEST (TRD-2026-72f477ca): regression tests that pin what
  `BeadsWatcher` already guarantees — and, for AC-006-2, now guarantees — for a
  tagged `implement_trd_beads` epic: REQ-006 (`trd_path` validation), REQ-007
  (the fail-closed `foreman-exec` label gate) and REQ-010 (no new locks for
  external bead edits).

  ## What is Foreman-observable here

  Every test drives `BeadsWatcher.process_line/2` (and, for REQ-010, a whole
  `boot_replay/1` read pass) with the real `Workflow.Catalog` mapping
  `implement_trd_beads` to the bundled `implement-trd-beads` workflow, the real
  `ProjectionStore` (registered project, seeded task projections) and, for
  REQ-006, a real git repository whose HEAD holds (or does not hold) the TRD.
  The `br` CLI is a Mox (`BrRunnerMock`): a test that expects no `br` call
  registers no expectation, so any call fails it. `CommandGateway` is a
  recording fake: it shows which commands the watcher dispatches (`task.create`,
  `task.approve`, anything else) without running them.

  What is asserted is therefore the watcher's decision for a line: its outcome,
  the `br update` it issues, the telemetry it emits, and the commands it sends.

    * REQ-006 / AC-006-1, AC-006-2: missing, deleted, directory, out-of-project
      and untracked `trd_path` are all blocked with the one remediation comment
      and never reach `task.create`; a committed TRD is dispatched.
    * REQ-007 / AC-007-1: no `foreman-exec` label means skipped, no `br` call, no
      command.
    * REQ-007 / AC-007-2: the watcher decides only NEW dispatches. Once a task
      exists past `open` for a bead, a line without the label produces no command
      at all (in particular no `run.cancel`); an `open` task, by contrast, still has
      its approval retried.
    * REQ-010 / AC-010-1: a human's `br update <child> --status=in_progress` is
      read, skipped and left alone: no command, no `br` call, and no lease taken by
      the per-line decision. The one lock the watcher has, the `BeadsDbLease` it
      holds across a read pass (REQ-004, pre-existing), is free again once the pass
      ends, so it can never be what rejects a human's write.

  ## What is beads-build's own job, not tested here

  Whether `ensemble-beads-build` skips, logs or resumes a child that a human set
  to `in_progress`, or accepts one a human closed (AC-010-1's "its own existing
  logic", AC-010-2), and whether the in-flight run keeps executing after the label
  is removed (AC-007-2's "NOT retroactively cancelled" as seen from the run), are
  decided inside the skill and `RunExecutor`; Foreman cannot observe them from the
  watcher. What this file proves for them is the Foreman-side half: the watcher
  issues no command that could cancel or reject anything. A human's `br` write is
  not mediated by Foreman, so "no lock rejects it" is shown by the absence of any
  watcher-held lease after a pass, not by exercising `br` itself.
  """

  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.BeadsDbLease
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TaskProviders.BeadsWatcher
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.AssetCatalog
  alias ForemanServer.Workflow.Catalog

  @moduletag :tmp_dir

  @missing_trd_path_event [
    :foreman_server,
    :task_provider,
    :beads,
    :watcher,
    :status_gate,
    :skipped,
    :missing_trd_path
  ]
  @label_gate_event [:foreman_server, :task_provider, :beads, :watcher, :label_gate, :skipped]
  @reconciled_event [:foreman_server, :task_provider, :beads, :watcher, :reconciled]
  @replay_completed_event [:foreman_server, :task_provider, :beads, :watcher, :replay_completed]

  setup :verify_on_exit!

  # --- Fakes ------------------------------------------------------------
  #
  # Same shape as the fake in `BeadsWatcherPipelineTest`: it records every
  # command the watcher hands to the gateway and answers `{:ok, nil}`.

  defmodule RecordingCommandGateway do
    @moduledoc false
    def reset, do: :persistent_term.put({__MODULE__, :calls}, [])
    def calls, do: :persistent_term.get({__MODULE__, :calls}, [])

    def dispatch_system(command, timeout), do: record(command, timeout)
    def dispatch_system_approval(command, timeout), do: record(command, timeout)
    def dispatch_operator(command, timeout), do: record(command, timeout)

    defp record(command, timeout) do
      :persistent_term.put({__MODULE__, :calls}, calls() ++ [{command, timeout}])
      {:ok, nil}
    end
  end

  setup %{tmp_dir: tmp_dir} do
    ProjectionStoreReset.reset!()

    original_cg =
      Application.get_env(:foreman_server, :command_gateway_module, ForemanServer.CommandGateway)

    Application.put_env(:foreman_server, :command_gateway_module, RecordingCommandGateway)
    RecordingCommandGateway.reset()

    # The REAL Catalog over the bundled manifests (an empty root is filled from
    # `priv/defaults/workflows` on boot), isolated from the app-wide one.
    prev_server = Application.get_env(:foreman_server, :workflow_catalog)
    prev_poll = Application.get_env(:foreman_server, :workflow_catalog_poll_ms)
    server_name = :"epic_execution_catalog_#{System.unique_integer([:positive])}"
    Application.put_env(:foreman_server, :workflow_catalog, server_name)
    Application.put_env(:foreman_server, :workflow_catalog_poll_ms, 60_000)

    start_supervised!(
      {Catalog,
       name: server_name,
       catalog: AssetCatalog.new(Path.join(tmp_dir, "workflows")),
       skills_target_dir: Path.join(tmp_dir, "skills")}
    )

    on_exit(fn ->
      Application.put_env(:foreman_server, :command_gateway_module, original_cg)

      if prev_server,
        do: Application.put_env(:foreman_server, :workflow_catalog, prev_server),
        else: Application.delete_env(:foreman_server, :workflow_catalog)

      if prev_poll,
        do: Application.put_env(:foreman_server, :workflow_catalog_poll_ms, prev_poll),
        else: Application.delete_env(:foreman_server, :workflow_catalog_poll_ms)

      RecordingCommandGateway.reset()
      ProjectionStoreReset.reset!()
    end)

    # Not a fake of the mapping under test: the bundled manifest must really
    # route a tagged epic to the TRD-and-Beads workflow.
    assert {:ok, "implement-trd-beads"} = Catalog.type_to_workflow("implement_trd_beads")

    :ok
  end

  # A registered project whose git HEAD holds `docs/TRD/epic.md`, once held
  # `docs/TRD/deleted.md`, and has an untracked `docs/TRD/untracked.md` on disk.
  setup %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "project")
    File.mkdir_p!(Path.join(repo, "docs/TRD"))
    File.write!(Path.join(repo, "docs/TRD/epic.md"), "# TRD\n")
    File.write!(Path.join(repo, "docs/TRD/deleted.md"), "# soon gone\n")

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.email", "t@t"],
          ["config", "user.name", "t"],
          ["add", "."],
          ["commit", "-q", "-m", "init"],
          ["rm", "-q", "docs/TRD/deleted.md"],
          ["commit", "-q", "-m", "delete the TRD"]
        ] do
      {_, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    end

    File.write!(Path.join(repo, "docs/TRD/untracked.md"), "# not committed\n")

    project_id = "proj-epic-#{System.unique_integer([:positive])}"
    register_project(project_id, repo)

    state = %BeadsWatcher{
      project_id: project_id,
      database_path: Path.join(tmp_dir, "epic.db"),
      jsonl_path: Path.join(tmp_dir, "issues.jsonl"),
      poll_ms: 60_000
    }

    %{state: state, repo: repo}
  end

  # --- REQ-006 ----------------------------------------------------------

  describe "REQ-006: trd_path validation for a tagged epic" do
    test "AC-006-1: an epic with no agent_context.trd_path is blocked with the missing-trd_path comment",
         %{state: state} do
      attach_telemetry(@missing_trd_path_event)
      expect_block("epic-no-trd")

      assert :skipped = BeadsWatcher.process_line(state, epic_line("epic-no-trd"))

      assert RecordingCommandGateway.calls() == []
      assert_receive {:telemetry, @missing_trd_path_event, metadata}, 500
      assert metadata.bead_id == "epic-no-trd"
      assert metadata.project_id == state.project_id
      refute Map.has_key?(metadata, :reason)
    end

    test "AC-006-1: a blank trd_path and a non-string trd_path are blocked the same way",
         %{state: state} do
      for {bead_id, trd_path} <- [{"epic-blank-trd", ""}, {"epic-number-trd", 42}] do
        expect_block(bead_id)
        line = epic_line(bead_id, agent_context: %{"trd_path" => trd_path})

        assert :skipped = BeadsWatcher.process_line(state, line)
      end

      assert RecordingCommandGateway.calls() == []
    end

    for {name, trd_path, reason} <- [
          {"names a file that does not exist", "docs/TRD/never-existed.md", :trd_path_missing},
          {"names a file deleted from the repo", "docs/TRD/deleted.md", :trd_path_missing},
          {"names a directory", "docs/TRD", :trd_path_is_directory},
          {"escapes the project with ..", "../x.md", :trd_path_not_project_relative},
          {"is an absolute path", "/etc/hosts", :trd_path_not_project_relative},
          {"names a file present on disk but never committed", "docs/TRD/untracked.md",
           :trd_path_not_tracked_blob}
        ] do
      test "AC-006-2: an epic whose trd_path #{name} is blocked like a missing trd_path",
           %{state: state} do
        attach_telemetry(@missing_trd_path_event)
        expect_block("epic-bad-trd")

        line = epic_line("epic-bad-trd", agent_context: %{"trd_path" => unquote(trd_path)})

        assert :skipped = BeadsWatcher.process_line(state, line)

        assert RecordingCommandGateway.calls() == [],
               "no task.create may be sent for an unusable trd_path"

        assert_receive {:telemetry, @missing_trd_path_event, metadata}, 500
        assert metadata.bead_id == "epic-bad-trd"
        assert metadata.reason == unquote(reason)
      end
    end

    test "AC-006-2: control — the same epic with the TRD present and committed is dispatched",
         %{state: state} do
      line = epic_line("epic-good-trd", agent_context: %{"trd_path" => "docs/TRD/epic.md"})

      assert :imported = BeadsWatcher.process_line(state, line)

      assert [{create, _}, {approve, _}] = RecordingCommandGateway.calls()
      assert create.type == "task.create"
      assert create.payload.workflow_type == "implement-trd-beads"
      assert create.payload.trd_path == "docs/TRD/epic.md"
      assert create.payload.external_id == "epic-good-trd"
      assert approve.type == "task.approve"
    end

    test "AC-006-2: a bead blocked for a deleted TRD is dispatched once the TRD is committed again",
         %{state: state, repo: repo} do
      line = epic_line("epic-restored", agent_context: %{"trd_path" => "docs/TRD/deleted.md"})

      expect_block("epic-restored")
      assert :skipped = BeadsWatcher.process_line(state, line)
      assert RecordingCommandGateway.calls() == []

      File.write!(Path.join(repo, "docs/TRD/deleted.md"), "# back\n")

      for args <- [["add", "."], ["commit", "-q", "-m", "restore the TRD"]] do
        {_, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
      end

      assert :imported = BeadsWatcher.process_line(state, line)
      assert [{%{type: "task.create"}, _}, {%{type: "task.approve"}, _}] = calls()
    end

    test "AC-006-2: a fault of the project, not of the path, does not block the bead",
         %{state: state} do
      line = epic_line("epic-project-fault", agent_context: %{"trd_path" => "docs/TRD/epic.md"})

      # Outside the checkout: `tmp_dir` sits inside this repository, and git
      # would resolve a plain subdirectory of it to the enclosing work tree.
      not_git =
        Path.join(System.tmp_dir!(), "epic-not-git-#{System.unique_integer([:positive])}")

      File.mkdir_p!(not_git)
      on_exit(fn -> File.rm_rf(not_git) end)
      register_project("proj-not-git", not_git)

      for project_id <- ["proj-never-registered", "proj-not-git"] do
        RecordingCommandGateway.reset()

        assert :imported = BeadsWatcher.process_line(%{state | project_id: project_id}, line)
        assert [{%{type: "task.create"}, _}, {%{type: "task.approve"}, _}] = calls()
      end
    end
  end

  # --- REQ-007 ----------------------------------------------------------

  describe "REQ-007: the foreman-exec label gate" do
    for {name, labels, reason} <- [
          {"has no labels field", :absent, :no_labels},
          {"has an empty label list", [], :not_foreman_exec},
          {"carries only other labels", ["epic", "foreman"], :not_foreman_exec}
        ] do
      test "AC-007-1: a tagged epic that #{name} is skipped without any command or br call",
           %{state: state} do
        attach_telemetry(@label_gate_event)

        line =
          epic_line("epic-unlabeled",
            labels: unquote(Macro.escape(labels)),
            agent_context: %{"trd_path" => "docs/TRD/epic.md"}
          )

        assert :skipped = BeadsWatcher.process_line(state, line)

        assert RecordingCommandGateway.calls() == []
        assert_receive {:telemetry, @label_gate_event, metadata}, 500
        assert metadata.bead_id == "epic-unlabeled"
        assert metadata.reason == unquote(reason)
      end
    end

    test "AC-007-1: control — the same epic with foreman-exec is dispatched", %{state: state} do
      line =
        epic_line("epic-labeled",
          labels: ["epic", "foreman-exec"],
          agent_context: %{"trd_path" => "docs/TRD/epic.md"}
        )

      assert :imported = BeadsWatcher.process_line(state, line)
      assert [{%{type: "task.create"}, _}, {%{type: "task.approve"}, _}] = calls()
    end

    test "AC-007-1: an unlabeled epic without a trd_path is left alone, not blocked",
         %{state: state} do
      # The label gate precedes the trd_path gate: no label, no `br update`
      # (BrRunnerMock has no expectation, so a call would fail this test).
      assert :skipped = BeadsWatcher.process_line(state, epic_line("epic-nolabel", labels: []))
      assert RecordingCommandGateway.calls() == []
    end

    for status <- ["in_progress", "approved"] do
      test "AC-007-2: label removed while the epic's task is #{status} — the line is reconciled and no command is sent",
           %{state: state} do
        attach_telemetry(@reconciled_event)
        seed_task(state, "epic-running", unquote(status))

        # The bead as it reads after the human removed the label mid-run.
        line =
          epic_line("epic-running",
            status: "in_progress",
            labels: ["epic"],
            agent_context: %{"trd_path" => "docs/TRD/epic.md"}
          )

        assert :reconciled = BeadsWatcher.process_line(state, line)

        assert RecordingCommandGateway.calls() == [],
               "no run.cancel / task.* command may follow a label removal"

        assert_receive {:telemetry, @reconciled_event, %{bead_id: "epic-running"}}, 500
      end
    end

    test "AC-007-2: the label removed entirely (no labels field) also dispatches nothing",
         %{state: state} do
      seed_task(state, "epic-running", "in_progress")

      line = epic_line("epic-running", status: "in_progress", labels: :absent)

      assert :reconciled = BeadsWatcher.process_line(state, line)
      assert RecordingCommandGateway.calls() == []
    end

    test "AC-007-2: control — a task still open (never approved) has its approval retried, not dropped",
         %{state: state} do
      seed_task(state, "epic-unapproved", "open")

      line = epic_line("epic-unapproved", labels: [])

      assert :imported = BeadsWatcher.process_line(state, line)

      assert [{%{type: "task.approve"} = approve, _}] = RecordingCommandGateway.calls()
      assert approve.aggregate_id == "task:beads:#{state.project_id}:epic-unapproved"
    end
  end

  # --- REQ-010 ----------------------------------------------------------

  describe "REQ-010: no new locks for external bead edits" do
    test "AC-010-1: a child a human set to in_progress is skipped — no command, no br call, no lease",
         %{state: state} do
      seed_task(state, "epic-running", "in_progress")
      stream = BeadsDbLease.stream_id(state.database_path)
      on_exit(fn -> drop_lease_stream(stream) end)

      assert :skipped = BeadsWatcher.process_line(state, child_line("epic-running.1"))

      assert RecordingCommandGateway.calls() == []
      assert {_state, 0} = Aggregate.load(BeadsDbLease, stream), "process_line took a lease"
    end

    test "AC-010-1: a read pass over the human's edit holds the lease only for the pass, and frees it",
         %{state: state} do
      attach_telemetry(@replay_completed_event)
      seed_task(state, "epic-running", "in_progress")
      stream = BeadsDbLease.stream_id(state.database_path)
      on_exit(fn -> drop_lease_stream(stream) end)

      File.write!(
        state.jsonl_path,
        epic_line("epic-running",
          status: "in_progress",
          agent_context: %{"trd_path" => "docs/TRD/epic.md"}
        ) <> "\n" <> child_line("epic-running.1") <> "\n"
      )

      BeadsWatcher.boot_replay(state)

      assert RecordingCommandGateway.calls() == []
      assert_receive {:telemetry, @replay_completed_event, counters}, 500
      assert counters.lines_processed == 2
      assert counters.lines_imported == 0
      assert counters.lines_reconciled == 1

      # The pass acquired and released the watcher's pre-existing lease
      # (REQ-004); after it, nothing holds it and nobody waits.
      {lease, version} = Aggregate.load(BeadsDbLease, stream)
      assert version > 0, "the read pass should have used the lease"
      assert lease.holder == nil
      assert lease.waiters == []
    end
  end

  # --- helpers ----------------------------------------------------------

  defp calls, do: RecordingCommandGateway.calls()

  # A tagged epic: issue_type `implement_trd_beads`, status open, labeled for
  # Foreman, no `foreman` tag in agent_context (the human/scaffold tagging is
  # `issue_type` + label + `trd_path`). Options override each field; `labels:
  # :absent` omits the field and `agent_context: nil` omits that one.
  defp epic_line(bead_id, opts \\ []) do
    bead = %{
      "id" => bead_id,
      "title" => "Execute epic #{bead_id}",
      "status" => Keyword.get(opts, :status, "open"),
      "issue_type" => "implement_trd_beads"
    }

    bead =
      case Keyword.get(opts, :labels, ["foreman-exec"]) do
        :absent -> bead
        labels -> Map.put(bead, "labels", labels)
      end

    bead =
      case Keyword.get(opts, :agent_context) do
        nil -> bead
        agent_context -> Map.put(bead, "agent_context", agent_context)
      end

    Jason.encode!(bead)
  end

  # A child bead as a human leaves it after `br update <id> --status=in_progress`:
  # no Foreman label, no Foreman tag, a plain task.
  defp child_line(bead_id) do
    Jason.encode!(%{
      "id" => bead_id,
      "title" => "Child #{bead_id}",
      "status" => "in_progress",
      "issue_type" => "task",
      "labels" => []
    })
  end

  # The block path: a live `br show` (still open) and then the one `br update`
  # carrying the remediation comment for `bead_id`.
  defp expect_block(bead_id) do
    expect(BrRunnerMock, :cmd, 2, fn
      {:show, %{id: ^bead_id}}, _config, _opts ->
        {:ok, %{stdout: ~s({"status":"open"}), stderr: "", exit_code: 0}}

      {:update, %{flags: flags}}, _config, _opts ->
        assert flags == [
                 bead_id,
                 "--status",
                 "blocked",
                 "--transition-comment",
                 "Blocked: workflow requires trd_path in agent_context. Re-run: " <>
                   "br update #{bead_id} --agent-context '{\"trd_path\":\"docs/TRD/...\"}' --status open"
               ]

        {:ok, %{stdout: "", stderr: "", exit_code: 0}}
    end)
  end

  defp register_project(project_id, path) do
    :sys.replace_state(ProjectionStore, fn state ->
      put_in(state.projects[project_id], %{project_id: project_id, path: path, status: "active"})
    end)
  end

  # The projection of the task `BeadsWatcher` created for `bead_id`.
  defp seed_task(state, bead_id, status) do
    task_id = "beads:#{state.project_id}:#{bead_id}"

    :sys.replace_state(ProjectionStore, fn store ->
      put_in(store.tasks[task_id], %{
        task_id: task_id,
        project_id: state.project_id,
        external_id: bead_id,
        workflow_type: "implement-trd-beads",
        status: status
      })
    end)
  end

  defp attach_telemetry(event) do
    handler_id = "epic-execution-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler_id, event, &__MODULE__.forward_telemetry/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  @doc false
  def forward_telemetry(event, _measurements, metadata, test_pid),
    do: send(test_pid, {:telemetry, event, metadata})

  # A stream the watcher never wrote has nothing to delete (and deleting it logs).
  defp drop_lease_stream(stream) do
    case Aggregate.load(BeadsDbLease, stream) do
      {_state, 0} -> :ok
      {_state, _version} -> Store.delete_stream(stream, :any_version, :hard)
    end
  end
end
