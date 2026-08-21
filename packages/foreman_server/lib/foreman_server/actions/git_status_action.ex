defmodule ForemanServer.Actions.GitStatusAction do
  @moduledoc """
  A `Jido.Action` that returns the porcelain output of
  `git status` for a given path (TRD-2026-4212be7e, JAF-T001).

  This is the first concrete Jido.Action in the Foreman codebase —
  it establishes the pattern that other tools (diff_read, task_get,
  etc.) will follow as the legacy TypeScript tool factories are
  migrated (JAF-T002). Foreman had no legacy TypeScript tool
  factories (the prior agent runtime shelled out to the external
  `pi` Node CLI via `Port.open`); the JAF-T002 migration is
  effectively a "first author" exercise.

  The action shells out to `git` directly. Foreman runs every
  workflow inside a worktree (per `ForemanServer.Aggregates.Run`), so
  the default `:path` is the current working directory. Tests and
  Jido agents can override with `params.path`.

  ## Output shape

      {:ok, %{porcelain: ["M lib/foo.ex", "?? new.txt"], exit_code: 0}}

  `porcelain` is a list of `git status --porcelain` output lines
  (already split on `\\n`, trailing empty line stripped). `exit_code`
  is 0 for a clean run; non-zero is wrapped as
  `{:error, {:git_exit, code, stderr}}` so Jido can serialize it
  to the AI tool result.

  ## Failure modes

    - `{:error, :not_a_git_repo}` — `:path` is not inside a git
      working tree (`git status` returned 128 with
      "fatal: not a git repository").
    - `{:error, {:git_exit, code, stderr}}` — `git status` returned
      a non-zero exit for some other reason.
  """

  use Jido.Action,
    name: "git_status",
    description: "Get the porcelain output of `git status` for a path",
    category: "git",
    tags: ["git", "status", "vcs"],
    vsn: "1.0.0",
    schema: [
      path: [
        type: :string,
        required: false,
        doc: "Filesystem path to the git working tree (default: cwd)"
      ]
    ],
    output_schema: [
      porcelain: [type: {:list, :string}, required: true, doc: "Porcelain output lines"],
      exit_code: [type: :integer, required: true, doc: "`git status` exit code (0 on success)"]
    ]

  @impl true
  def run(params, _context) do
    path = Map.get(params, :path, File.cwd!())
    args = ["-C", path, "status", "--porcelain"]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} ->
        porcelain =
          output
          |> String.split("\n", trim: true)

        {:ok, %{porcelain: porcelain, exit_code: 0}}

      {output, 128} ->
        if String.contains?(output, "not a git repository") do
          {:error, :not_a_git_repo}
        else
          {:error, {:git_exit, 128, output}}
        end

      {output, code} ->
        {:error, {:git_exit, code, output}}
    end
  end
end
