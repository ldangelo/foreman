defmodule ForemanServer.TestSupport.BeadsTreeFixture do
  @moduledoc """
  TRD-006a (TRD-2026-72f477ca): the synthetic Beads tree the end-to-end test runs
  against, built with the REAL `br` (never hand-written JSON), so the shapes
  Foreman reads are the shapes `br` emits.

  `build!/1` creates, under `root`:

    * `project/` - a git repository whose HEAD commits the fixture TRD
      (`test/fixtures/beads_epic/TRD-synthetic-epic.md`) at `docs/TRD/TRD-synthetic-epic.md`,
      the project a Foreman instance registers;
    * `beads/.beads/beads.db` - a `br` database (outside the project, as a
      deployment keeps it) holding the tree:

          epic  (issue_type `implement_trd_beads`, label `foreman-exec`,
                 agent_context.trd_path -> the TRD above)
          ├── task_a   (parent-child -> epic)
          └── task_b   (parent-child -> epic, `blocks` edge: depends on task_a)

  The tree's shape is fixed; the ids are `br`'s (`<prefix>-<hash>`), so tests read
  them from the returned map and never hard-code them. Depends on nothing outside
  this repository: no ensemble checkout, no `~/.foreman`.
  """

  @trd_fixture Path.expand("../fixtures/beads_epic/TRD-synthetic-epic.md", __DIR__)
  @trd_path "docs/TRD/TRD-synthetic-epic.md"

  @type t :: %{
          project_root: String.t(),
          trd_path: String.t(),
          database_path: String.t(),
          jsonl_path: String.t(),
          epic_id: String.t(),
          task_ids: [String.t()]
        }

  @doc "True when a `br` binary is on the PATH (the fixture cannot be built without one)."
  @spec br_available?() :: boolean()
  def br_available?, do: System.find_executable("br") != nil

  @spec build!(String.t()) :: t()
  def build!(root) when is_binary(root) do
    project = Path.join(root, "project")
    beads = Path.join(root, "beads")
    File.mkdir_p!(Path.join(project, Path.dirname(@trd_path)))
    File.mkdir_p!(beads)
    File.cp!(@trd_fixture, Path.join(project, @trd_path))

    for args <- [
          ["init", "-q", "-b", "main"],
          ["config", "user.email", "fixture@example.invalid"],
          ["config", "user.name", "fixture"],
          ["add", "."],
          ["commit", "-q", "--no-gpg-sign", "-m", "fixture TRD"]
        ],
        do: cmd!("git", args, project)

    cmd!("git", ["init", "-q", "-b", "main"], beads)
    cmd!("br", ["init", "--prefix", "fx"], beads)
    db = Path.join([beads, ".beads", "beads.db"])

    epic =
      create!(db, [
        "--title",
        "Synthetic epic: two tasks, one dependency",
        "--type",
        "implement_trd_beads",
        "--priority",
        "1",
        "--description",
        "Fixture epic for the beads-build end-to-end test.",
        "--labels",
        "foreman-exec",
        "--agent-context",
        Jason.encode!(%{"trd_path" => @trd_path})
      ])

    task_a = create!(db, task_args("Synthetic task A"))
    task_b = create!(db, task_args("Synthetic task B (needs A)"))

    for child <- [task_a, task_b],
        do: cmd!("br", ["dep", "add", child, epic, "--type", "parent-child", "--db", db], beads)

    cmd!("br", ["dep", "add", task_b, task_a, "--type", "blocks", "--db", db], beads)

    jsonl = Path.join([beads, ".beads", "issues.jsonl"])
    cmd!("br", ["sync", "--flush-only", "--db", db], beads)

    %{
      project_root: project,
      trd_path: @trd_path,
      database_path: db,
      jsonl_path: jsonl,
      epic_id: epic,
      task_ids: [task_a, task_b]
    }
  end

  @doc """
  The epic's line from `br`'s `issues.jsonl` export (what `BeadsWatcher` reads).

  `agent_context:`

    * `:as_exported` (default) - verbatim, as `br` 0.6.0 writes it: `agent_context`
      is a JSON-ENCODED STRING;
    * `:object` - `agent_context` decoded into a JSON object, the shape a producer
      that embeds the object would write.
  """
  @spec epic_line!(t(), keyword()) :: String.t()
  def epic_line!(%{jsonl_path: jsonl, epic_id: epic_id}, opts \\ []) do
    line =
      jsonl
      |> File.stream!()
      |> Enum.find(fn line -> match?({:ok, %{"id" => ^epic_id}}, Jason.decode(line)) end)
      |> case do
        nil -> raise "epic #{epic_id} is not in #{jsonl}"
        line -> String.trim_trailing(line, "\n")
      end

    case Keyword.get(opts, :agent_context, :as_exported) do
      :as_exported ->
        line

      :object ->
        line
        |> Jason.decode!()
        |> Map.update!("agent_context", &Jason.decode!/1)
        |> Jason.encode!()
    end
  end

  @doc "Closes `ids` with the real `br` (what the stand-in agent does). Raises on failure."
  @spec close!(t(), [String.t()]) :: :ok
  def close!(%{database_path: db}, ids) when is_list(ids) do
    {_out, 0} =
      System.cmd("br", ["close" | ids] ++ ["--reason", "fixture agent", "--db", db],
        stderr_to_stdout: true
      )

    :ok
  end

  @doc "Every bead of the tree as `br` reports it now: `%{id => status}`."
  @spec statuses!(t()) :: %{String.t() => String.t()}
  def statuses!(%{database_path: db, epic_id: epic_id, task_ids: task_ids}) do
    {out, 0} = System.cmd("br", ["show", epic_id | task_ids] ++ ["--json", "--db", db])
    out |> Jason.decode!() |> Map.new(fn issue -> {issue["id"], issue["status"]} end)
  end

  defp task_args(title),
    do: ["--title", title, "--type", "task", "--priority", "2", "--description", title]

  defp create!(db, args) do
    {out, 0} = System.cmd("br", ["create" | args] ++ ["--json", "--db", db])

    case Jason.decode!(out) do
      [%{"id" => id}] -> id
      %{"id" => id} -> id
    end
  end

  defp cmd!(bin, args, cwd) do
    case System.cmd(bin, args, cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> raise "#{bin} #{Enum.join(args, " ")} exited #{code}: #{out}"
    end
  end
end
