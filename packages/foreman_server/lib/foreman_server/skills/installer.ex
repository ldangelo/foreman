defmodule ForemanServer.Skills.Installer do
  @moduledoc """
  Installs bundled skill files from `priv/defaults/skills/` into the operator's
  `~/.foreman/skills/` directory (one sub-directory per skill, each containing
  a `SKILL.md`).

  Each skill directory under `priv/defaults/skills/` is treated as one skill.
  The installer copies all files within each skill directory recursively.

  Install-if-absent boot semantics mirror `ForemanServer.Workflow.Catalog.ensure_installed/1`
  (`workflow/catalog.ex:220`); the bundled workflow templates themselves are installed by
  `ForemanServer.WorkflowTemplate.Installer`, whose module lives at
  `lib/foreman_server/workflow/install.ex`. Target defaults to
  `System.user_home!()/.foreman/skills` and is overridable via `:target_dir`.

  `maybe_install/1` copies **only the skills that are missing**, so an operator's edits to a
  skill already on disk survive every boot. `install/1` is the force-reinstall path and
  overwrites everything in its source.
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

  # Digests the CONTENT of every SKILL.md, not just the directory names. A
  # name-list fingerprint could not tell a bundle edit from a bundle rename, and
  # `__mix_recompile__?/0` returning false is what let a stale `@bundled_skill_dirs`
  # survive into a released binary (AGENTS.md §5.5). Individual `@external_resource`
  # declarations are not a substitute: they do not cover a directory being added or
  # removed, which is what this list is derived from.
  @bundled_skills_fingerprint :erlang.md5(
                                Enum.map_join(@bundled_skill_dirs, "\n", fn dir ->
                                  case File.read(
                                         Path.join([@bundled_skills_source, dir, "SKILL.md"])
                                       ) do
                                    {:ok, body} -> "#{dir}\0#{body}"
                                    {:error, reason} -> "#{dir}\0#{inspect(reason)}"
                                  end
                                end)
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

    digest =
      Enum.map_join(current, "\n", fn dir ->
        case File.read(Path.join([@bundled_skills_source, dir, "SKILL.md"])) do
          {:ok, body} -> "#{dir}\0#{body}"
          {:error, reason} -> "#{dir}\0#{inspect(reason)}"
        end
      end)

    :erlang.md5(digest) != @bundled_skills_fingerprint
  end

  @type option ::
          {:home_dir, Path.t()}
          | {:target_dir, Path.t()}
          | {:source_dir, Path.t()}
          | {:install_skills, [String.t()]}

  @spec install([option()]) :: {:ok, [Path.t()]} | {:error, term()}
  def install(opts \\ []) when is_list(opts) do
    source_dir = Keyword.get(opts, :source_dir, @bundled_skills_source)
    dest_dir = target_dir(opts)

    with :ok <- File.mkdir_p(dest_dir),
         {:ok, skill_names} <- list_skill_dirs(source_dir) do
      skill_names = restrict(skill_names, Keyword.get(opts, :install_skills))

      skill_names
      |> Enum.reduce_while({:ok, []}, fn skill_name, {:ok, paths} ->
        case copy_skill(source_dir, dest_dir, skill_name) do
          {:ok, copied} -> {:cont, {:ok, paths ++ copied}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  # `nil` means "everything". `[]` means "nothing", so a caller that passes an empty allowlist
  # cannot silently widen into a full reinstall of skills the operator has edited.
  defp restrict(names, nil), do: names
  defp restrict(names, only) when is_list(only), do: Enum.filter(names, &(&1 in only))

  @doc """
  Installs bundled skills into `~/.foreman/skills`, copying only skills that are not
  already present there. Returns `{:ok, :noop}` when *every* bundled skill already has
  a `SKILL.md` on disk — or when the bundle itself is empty, which satisfies the same
  "nothing missing" condition; `{:ok, []}` is what `install/1` returns when it actually
  ran the copy and copied nothing.

  Two properties the previous gate had neither:

  - It asked "is *anything* in the destination?" instead of "is *everything the bundle
    ships* there?", so a skill added to the bundle in a later release never reached an
    operator who already had one installed.
  - On a miss it called `install/1` with the whole bundle, force-copying skills that were
    already present and overwriting the operator's edits to them — the opposite of what this
    function's docstring promised. Only missing skills are copied now.
  """
  @spec maybe_install([option()]) :: {:ok, [Path.t()] | :noop} | {:error, term()}
  def maybe_install(opts \\ []) do
    dest_dir = target_dir(opts)
    source_dir = Keyword.get(opts, :source_dir, @bundled_skills_source)

    case list_skill_dirs(source_dir) do
      {:ok, names} ->
        case Enum.reject(names, &skill_installed?(dest_dir, &1)) do
          [] -> {:ok, :noop}
          missing -> install(Keyword.put(opts, :install_skills, missing))
        end

      {:error, _} = err ->
        err
    end
  end

  defp skill_installed?(dest_dir, name) do
    File.regular?(Path.join([dest_dir, name, "SKILL.md"]))
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

  @doc """
  Resolves the install destination: explicit `:target_dir`, else `:home_dir` (default
  `System.user_home!()`) joined with `.foreman/skills`. Both keys treat a present `nil` exactly
  as an absent one: `Keyword.get/3`'s default fires only when the key is missing, and callers
  that translate options by name (the `skills_*` mapping in `ForemanServer.Workflow.Catalog`)
  cannot always distinguish the two at their own boundary. Public so that translation is
  testable against the one place the default is computed.
  """
  @spec target_dir([option()]) :: Path.t()
  def target_dir(opts) do
    case Keyword.get(opts, :target_dir) do
      nil ->
        home = Keyword.get(opts, :home_dir) || System.user_home!()
        Path.join([home, ".foreman", "skills"])

      path ->
        path
    end
  end
end
