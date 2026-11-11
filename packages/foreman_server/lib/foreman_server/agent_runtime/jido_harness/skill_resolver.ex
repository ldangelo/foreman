defmodule ForemanServer.AgentRuntime.JidoHarness.SkillResolver do
  @moduledoc """
  Whether the harness that will launch a run can actually load a skill the
  workflow's `command:` names (TRD-021, PRD AC-007-1).

  The per-provider skill-directory knowledge lives here, beside
  `ForemanServer.AgentRuntime.JidoHarness.ReadinessCheck` (which owns the
  per-provider install knowledge): one boundary for "what does this harness
  read". `ForemanServer.Skills.Installer` is deliberately not consulted: it
  installs the bundled skills into `~/.foreman/skills`, a directory the pi/omp
  CLIs do not scan, so a skill found only there would be reported `:available`
  and then fail in the harness.

  `resolve/3,4` answers against the LAUNCHING provider's own directories only,
  never a union:

    * `:pi` - `<project_root>/.pi/agent/skills/<skill>/SKILL.md` and
      `<home>/.pi/agent/skills/<skill>/SKILL.md` (the two directories
      Foreman's CLI recommends for pi/omp). `~/.foreman/skills` is not searched.
    * `:claude` - no repo-defined skill directory (the recommended directory
      is a commands directory), so `:unverifiable`.
    * any other provider - `:unverifiable`.
    * any backend other than the host workflow backend - `:unverifiable`: the
      host filesystem says nothing about what a container sees.

  `:unverifiable` is never `:available` and never `:missing`: the caller must
  not refuse a run, nor promise a skill, on evidence it does not have.

  A skill name is a single directory name. A name with a path separator, a
  leading dot (`.`/`..`), or any character outside `[A-Za-z0-9._-]` can never
  name a directory under a skill root, so it is `:missing` for a verifiable
  provider; it never reaches the filesystem.

  Options: `:project_root` (the project's checkout; no worktree exists at
  admission; when omitted the project directory is not searched) and `:home`
  (defaults to the user's home directory).
  """

  alias ForemanServer.Jobsite.ExecutionProfile

  @type verdict :: :available | :missing | :unverifiable

  @skill_name ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  @spec resolve(atom(), String.t(), atom(), keyword()) :: verdict()
  def resolve(provider, skill, backend, opts \\ []) when is_binary(skill) do
    if backend == ExecutionProfile.host_backend() do
      resolve_on_host(provider, skill, opts)
    else
      :unverifiable
    end
  end

  defp resolve_on_host(:pi, skill, opts) do
    cond do
      not Regex.match?(@skill_name, skill) ->
        :missing

      Enum.any?(pi_skill_roots(opts), &File.regular?(Path.join([&1, skill, "SKILL.md"]))) ->
        :available

      true ->
        :missing
    end
  end

  defp resolve_on_host(_provider_without_repo_skill_dir, _skill, _opts), do: :unverifiable

  @doc "The directories searched for `:pi` skills, in search order."
  @spec pi_skill_roots(keyword()) :: [Path.t()]
  def pi_skill_roots(opts \\ []) do
    home = Keyword.get_lazy(opts, :home, &System.user_home!/0)

    project =
      case Keyword.get(opts, :project_root) do
        root when is_binary(root) -> [Path.join(root, ".pi/agent/skills")]
        nil -> []
      end

    project ++ [Path.join(home, ".pi/agent/skills")]
  end
end
