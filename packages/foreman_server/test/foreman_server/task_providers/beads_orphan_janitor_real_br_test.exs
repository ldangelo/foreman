defmodule ForemanServer.TaskProviders.BeadsOrphanJanitorRealBrTest.NoTasks do
  @moduledoc false
  # Projection with no task for any bead: every bead is "not dispatched yet".
  def get_task(_opts), do: nil
end

defmodule ForemanServer.TaskProviders.BeadsOrphanJanitorRealBrTest do
  @moduledoc """
  foreman-n3923: `BeadsOrphanJanitor` against beads built and exported by a REAL
  `br` (0.6.0 emits `agent_context` as a JSON string everywhere), through the
  real `BeadsAdapter.create/2` (the same call `Review.BeadSink` makes for gap
  beads) and the real `BeadsAdapter.complete/4` close path.

  Only the projection (no task exists for any bead) is faked.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias ForemanServer.TaskProvider.Registry

  alias ForemanServer.TaskProviders.{
    BeadsAdapter,
    BeadsOrphanJanitor,
    BrRunnerMock,
    JsonSchemaCache,
    SystemBrRunner
  }

  alias ForemanServer.TestSupport.BeadsTreeFixture

  @moduletag :tmp_dir
  @grace_ms 300_000

  setup_all do
    unless BeadsTreeFixture.br_available?(),
      do: raise("this test needs a `br` binary on the PATH")

    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{tmp_dir: tmp_dir} do
    previous_config = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(:foreman_server, :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)
    stub(BrRunnerMock, :cmd, &SystemBrRunner.cmd/3)

    # The close path validates `br`'s answer against the real `br schema`.
    stop_schema_cache()
    start_supervised!(JsonSchemaCache)

    Application.put_env(
      :foreman_server,
      :projection_store_module,
      ForemanServer.TaskProviders.BeadsOrphanJanitorRealBrTest.NoTasks
    )

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_config)
      Application.delete_env(:foreman_server, :projection_store_module)
      stop_schema_cache()
    end)

    beads = Path.join(tmp_dir, "beads")
    File.mkdir_p!(beads)
    sh!("git", ["init", "-q", "-b", "main"], beads)
    sh!("br", ["init", "--prefix", "fx"], beads)
    db = Path.join([beads, ".beads", "beads.db"])

    project_id = "proj-janitor-real-br-#{System.unique_integer([:positive])}"
    :ok = Registry.register_for_project(project_id, BeadsAdapter, %{database_path: db})

    state = %BeadsOrphanJanitor{
      project_id: project_id,
      database_path: db,
      jsonl_path: Path.join([beads, ".beads", "issues.jsonl"]),
      grace_ms: @grace_ms,
      scan_interval_ms: 60_000
    }

    %{state: state, db: db, beads: beads, project_id: project_id}
  end

  test "the export really carries agent_context as a JSON string", ctx do
    id = create_foreman_bead!(ctx, "task-1", "cmd-1")
    flush!(ctx)

    assert is_binary(export_line!(ctx, id)["agent_context"])
  end

  test "(a) a Foreman-created bead with no task is classified and closed", ctx do
    id = create_foreman_bead!(ctx, "task-orphan", "cmd-orphan")
    flush!(ctx)

    counters = BeadsOrphanJanitor.run_scan(ctx.state, now_ms: later_ms())

    assert counters.lines_tagged == 1
    assert counters.lines_closed == 1
    assert counters.lines_untagged == 0
    assert status!(ctx, id) == "closed"
  end

  test "(b) an undispatched Review.BeadSink gap bead is never closed", ctx do
    id =
      create_foreman_bead!(ctx, "review:run:r1", "review:r1:gap:0", [
        "foreman-exec",
        "foreman-gap"
      ])

    flush!(ctx)

    counters = BeadsOrphanJanitor.run_scan(ctx.state, now_ms: later_ms())

    assert counters.lines_tagged == 1
    assert counters.lines_retained == 1
    assert counters.lines_closed == 0
    assert status!(ctx, id) == "open"
  end

  test "(c) a malformed agent_context is left untouched and logged loudly", ctx do
    # `br create` rejects non-JSON `--agent-context`, but accepts any valid JSON
    # value: an array is the realistic "not an object" malformed shape.
    id = create_raw_bead!(ctx, "garbled", ["--agent-context", "[1,2]"])
    flush!(ctx)

    log =
      capture_log(fn ->
        counters = BeadsOrphanJanitor.run_scan(ctx.state, now_ms: later_ms())

        assert counters.lines_malformed == 1
        assert counters.lines_closed == 0
        assert counters.lines_tagged == 0
      end)

    assert log =~ "malformed agent_context"
    assert log =~ id
    assert status!(ctx, id) == "open"
  end

  test "(d) untagged beads (no context / no foreman envelope) are untouched", ctx do
    plain = create_raw_bead!(ctx, "plain", [])
    other = create_raw_bead!(ctx, "other context", ["--agent-context", ~s({"trd_path":"x.md"})])
    flush!(ctx)

    counters = BeadsOrphanJanitor.run_scan(ctx.state, now_ms: later_ms())

    assert counters.lines_untagged == 2
    assert counters.lines_tagged == 0
    assert counters.lines_closed == 0
    assert status!(ctx, plain) == "open"
    assert status!(ctx, other) == "open"
  end

  # --- helpers -----------------------------------------------------------

  # Past the grace window: `linked_at` is the real creation instant.
  defp later_ms, do: System.system_time(:millisecond) + 2 * @grace_ms

  defp create_foreman_bead!(ctx, task_id, command_id, labels \\ nil) do
    attrs = %{
      task_id: task_id,
      command_id: command_id,
      title: "bead #{task_id}",
      description: "janitor real-br fixture",
      priority: 2,
      task_type: "task"
    }

    attrs = if labels, do: Map.put(attrs, :labels, labels), else: attrs
    assert {:ok, issue} = BeadsAdapter.create(ctx.project_id, attrs)
    issue.id
  end

  defp create_raw_bead!(ctx, title, extra_args) do
    args = ["create", "--title", title, "--type", "task", "--priority", "2"] ++ extra_args
    out = sh!("br", args ++ ["--json", "--db", ctx.db], ctx.beads)

    case Jason.decode!(out) do
      [%{"id" => id}] -> id
      %{"id" => id} -> id
    end
  end

  defp flush!(ctx), do: sh!("br", ["sync", "--flush-only", "--db", ctx.db], ctx.beads)

  defp export_line!(ctx, id) do
    ctx.state.jsonl_path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find(&(&1["id"] == id))
  end

  defp status!(ctx, id) do
    out = sh!("br", ["show", id, "--json", "--db", ctx.db], ctx.beads)
    [%{"status" => status}] = Jason.decode!(out)
    status
  end

  defp stop_schema_cache do
    case Process.whereis(:foreman_server_json_schema_cache) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp sh!(bin, args, cwd) do
    case System.cmd(bin, args, cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> raise "#{bin} #{Enum.join(args, " ")} exited #{code}: #{out}"
    end
  end
end
