defmodule ForemanServer.Skills.Installer do
  @moduledoc """
  Installs bundled skill files from `priv/defaults/skills/` into the operator's
  `~/.foreman/skills/` directory (one sub-directory per skill, each containing
  a `SKILL.md`).

  Each skill directory under `priv/defaults/skills/` is treated as one skill.
  The installer copies all files within each skill directory recursively.

  The install path mirrors `WorkflowTemplate.Installer` — target defaults to
  `System.user_home!()/.foreman/skills` and is overridable via `:target_dir`.
  """

  @bundled_skills_source Path.join([
                           __DIR__,
                           "..",
                           "..",
                           "..",
                           "priv",
                           "defaults",
                           "skills"
                         ])

  @bundled_skill_dirs @bundled_skills_source
                      |> File.ls!()
                      |> Enum.filter(fn name ->
                        File.dir?(Path.join(@bundled_skills_source, name))
                      end)
                      |> Enum.sort()

  for dir <- @bundled_skill_dirs do
    skill_md = Path.join([@bundled_skills_source, dir, "SKILL.md"])
    if File.regular?(skill_md), do: @external_resource(skill_md)
  end

  @bundled_skills_fingerprint :erlang.md5(
                                Enum.join(
                                  @bundled_skill_dirs,
                                  "\n"
                                )
                              )

  @doc false
  def __mix_recompile__? do
    current =
      case File.ls(@bundled_skills_source) do
        {:ok, entries} ->
          entries
          |> Enum.filter(fn name ->
            File.dir?(Path.join(@bundled_skills_source, name))
          end)
          |> Enum.sort()

        {:error, _} ->
          []
      end

    :erlang.md5(Enum.join(current, "\n")) != @bundled_skills_fingerprint
  end

  @type option ::
          {:home_dir, Path.t()}
          | {:target_dir, Path.t()}
          | {:source_dir, Path.t()}

  @spec install([option()]) :: {:ok, [Path.t()]} | {:error, term()}
  def install(opts \\ []) when is_list(opts) do
    source_dir = Keyword.get(opts, :source_dir, @bundled_skills_source)
    dest_dir = target_dir(opts)

    with :ok <- File.mkdir_p(dest_dir),
         {:ok, skill_names} <- list_skill_dirs(source_dir) do
      skill_names
      |> Enum.reduce_while({:ok, []}, fn skill_name, {:ok, paths} ->
        case copy_skill(source_dir, dest_dir, skill_name) do
          {:ok, copied} -> {:cont, {:ok, paths ++ copied}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  @doc """
  Installs bundled skills into `~/.foreman/skills` when that directory holds no
  skill yet, mirroring `WorkflowTemplate.Installer.maybe_install/1`. Returns
  `{:ok, :noop}` when a skill is already present, so a boot never overwrites an
  operator's edits.
  """
  @spec maybe_install([option()]) :: {:ok, [Path.t()] | :noop} | {:error, term()}
  def maybe_install(opts \\ []) do
    dest_dir = target_dir(opts)

    case File.ls(dest_dir) do
      {:ok, entries} ->
        installed? =
          Enum.any?(entries, fn name ->
            File.regular?(Path.join([dest_dir, name, "SKILL.md"]))
          end)

        if installed?, do: {:ok, :noop}, else: install(opts)

      {:error, :enoent} ->
        install(opts)

      {:error, reason} ->
        {:error, {:list_skills_failed, dest_dir, reason}}
    end
  end

  defp list_skill_dirs(source_dir) do
    case File.ls(source_dir) do
      {:ok, entries} ->
        dirs =
          entries
          |> Enum.filter(fn name -> File.dir?(Path.join(source_dir, name)) end)
          |> Enum.sort()

        {:ok, dirs}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:list_skills_failed, source_dir, reason}}
    end
  end

  defp copy_skill(source_dir, dest_dir, skill_name) do
    src = Path.join(source_dir, skill_name)
    dst = Path.join(dest_dir, skill_name)

    case File.cp_r(src, dst) do
      {:ok, copied} -> {:ok, Enum.filter(copied, &File.regular?/1)}
      {:error, reason, _acc} -> {:error, {:copy_failed, src, reason}}
    end
  end

  defp target_dir(opts) do
    case Keyword.get(opts, :target_dir) do
      nil ->
        Path.join([Keyword.get(opts, :home_dir, System.user_home!()), ".foreman", "skills"])

      path ->
        path
    end
  end
end
