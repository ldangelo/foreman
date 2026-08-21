defmodule ForemanServer.Actions.DiffReadAction do
  @moduledoc """
  A `Jido.Action` that returns the unified diff text for a path at a
  given git reference (TRD-2026-4212be7e, JAF-T002).

  The action shells out to `git diff` and returns the diff text plus
  the exit code. It does not enforce VFS at the action layer — callers
  are expected to pass paths that are already inside the worktree
  bound to `run_id` via `ForemanServer.Agents.VfsIsolation`.

  ## Output shape

      {:ok, %{diff: "...diff text...", exit_code: 0}}

  `diff` is the raw unified-diff output. Empty string when there are no
  changes. `exit_code` is 0 on success; non-zero is wrapped as
  `{:error, {:git_exit, code, stderr}}` so Jido can serialize it
  to the AI tool result.

  ## Failure modes

    - `{:error, :not_a_git_repo}` — `:path` is not inside a git
      working tree (`git diff` returned 128 with "fatal: not a git
      repository").
    - `{:error, {:git_exit, code, stderr}}` — `git diff` returned a
      non-zero exit for some other reason.
  """

  use Jido.Action,
    name: "diff_read",
    description: "Read the unified diff for a path at a git ref",
    category: "git",
    tags: ["git", "diff", "vcs"],
    vsn: "1.0.0",
    schema: [
      path: [
        type: :string,
        required: false,
        doc: "Filesystem path to read the diff for (default: cwd)"
      ],
      ref: [
        type: :string,
        required: false,
        doc: "Git reference to diff against (default: \"HEAD\")"
      ]
    ],
    output_schema: [
      diff: [type: :string, required: true, doc: "Unified diff text"],
      exit_code: [type: :integer, required: true, doc: "`git diff` exit code (0 on success)"]
    ]

  @default_ref "HEAD"

  @impl true
  def run(params, _context) do
    path = Map.get(params, :path, File.cwd!())
    ref = Map.get(params, :ref, @default_ref)
    args = ["-C", path, "diff", ref, "--"]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, %{diff: output, exit_code: 0}}

      {output, 128} ->
        if String.contains?(output, "not a git repository") do
          {:error, :not_a_git_repo}
        else
          {:error, {:git_exit, 128, output}}
        end

      {output, 129} ->
        # Newer git (≥2.38) prints "warning: Not a git repository"
        # and exits 129 instead of 128.
        if String.contains?(output, "Not a git repository") or
             String.contains?(output, "not a git repository") do
          {:error, :not_a_git_repo}
        else
          {:error, {:git_exit, 129, output}}
        end

      {output, code} ->
        {:error, {:git_exit, code, output}}
    end
  end
end
