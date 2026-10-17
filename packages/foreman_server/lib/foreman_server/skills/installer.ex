defmodule ForemanServer.Skills.Digest do
  @moduledoc false

  @doc """
  The bundled-skills fingerprint digest: `md5` of `"name\\0SKILL.md-body"` for each skill,
  with the read error in place of the body when a `SKILL.md` is absent or unreadable — so a
  vanished file is a change too, not a silent no-op.

  Digesting CONTENT rather than names is what lets `__mix_recompile__?/0` tell a bundle EDIT
  from a bundle RENAME. Individual `@external_resource` declarations are not a substitute for
  it: they do not cover a directory being added or removed.
  """
  @spec digest([String.t()], Path.t()) :: binary()
  def digest(names, source_dir) do
    names
    |> Enum.map_join("\n", fn name ->
      case File.read(Path.join([source_dir, name, "SKILL.md"])) do
        {:ok, body} -> "#{name}\0#{body}"
        {:error, reason} -> "#{name}\0#{inspect(reason)}"
      end
    end)
    |> then(&:erlang.md5/1)
  end
end

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

  # The bundled tree lives in the application's `priv/`, which a Mix release ships even when
  # it does not ship the source tree — so the RUNTIME path is resolved through
  # `Application.app_dir(:foreman_server, "priv/defaults/skills")` (`bundled_skills_source/1`
  # below), never from `__DIR__`: a `__DIR__` path is baked at
  # compile time and would name a path that does not exist in a release, in which case
  # `list_skill_dirs/1` reads a missing directory as an empty bundle and the install reports a
  # successful-looking no-op with zero skills installed (§5.2). The compile-time attributes
  # below still use `__DIR__`, and correctly so: they only run during compilation, where the
  # source tree exists by definition.
  @source_tree_bundled_dir Path.join([
                             __DIR__,
                             "..",
                             "..",
                             "..",
                             "priv",
                             "defaults",
                             "skills"
                           ])

  # The fingerprint digest itself lives in `ForemanServer.Skills.Digest`, defined at the top of
  # this file, because a module attribute cannot call a `def` of its OWN module: attributes are
  # evaluated during body expansion, before the function table exists, so
  # `@fingerprint skills_digest(...)` fails with "undefined function skills_digest/2 (there is
  # no such import)" regardless of where the `def` sits. A separate `defmodule` IS compiled at
  # its definition point, so calling into one works. Both this attribute and
  # `__mix_recompile__?/0` go through that one function, so the two can never disagree about
  # what "changed" means — a divergence would silently stop the recompile check from seeing
  # content edits, which is the bug this digest exists to prevent.
  # Compile-time only, deliberately sourced from `@source_tree_bundled_dir`: this list and the
  # fingerprint below exist to make Mix recompile the module when the bundled tree changes.
  # They never run in a release, so the source-tree path is the correct input here. Runtime
  # resolution is `bundled_skills_source/0`.
  @bundled_skill_dirs @source_tree_bundled_dir
                      |> File.ls!()
                      |> Enum.filter(fn name ->
                        File.dir?(Path.join(@source_tree_bundled_dir, name))
                      end)
                      |> Enum.sort()

  for dir <- @bundled_skill_dirs do
    skill_md = Path.join([@source_tree_bundled_dir, dir, "SKILL.md"])
    if File.regular?(skill_md), do: @external_resource(skill_md)
  end

  @bundled_skills_fingerprint ForemanServer.Skills.Digest.digest(
                                @bundled_skill_dirs,
                                @source_tree_bundled_dir
                              )

  @doc """
  The directory bundled skills are copied FROM at runtime.

  `Application.app_dir/2`, the same idiom `Workflow.Install.bundled_source_dir/0` uses for the
  bundled workflows (`workflow/install.ex:186`): a Mix release ships the application's `priv/`
  even when it does not ship the source tree, so this is the only path that resolves in both
  `mix`/`iex -S mix` and a release. Under `mix`, `app_dir` already points at `_build/<env>/lib/foreman_server`,
  whose `priv` is the symlink Mix creates to the checkout's `priv/`, so the release path exists
  there too.

  The source-tree path is kept as a fallback for a bare-`:code` load where the app directory
  has no `priv` (for instance `mix run --no-mix-exs` or an unusual `--path`), because
  `list_skill_dirs/1` reads a missing directory as an EMPTY BUNDLE and would report a
  successful-looking no-op with zero skills installed (§5.2). It is a fallback, not the
  mechanism: `__DIR__` is baked at compile time and does not exist in a sourceless release.
  """
  @spec bundled_skills_source(keyword()) :: Path.t()
  def bundled_skills_source(opts \\ []) do
    # `:bundled_skills_dir` exists so the release scenario this resolver guards -- `priv/`
    # shipped WITHOUT the skills subtree -- is exercisable from a test instead of only inside a
    # real release build.
    case Keyword.get(opts, :bundled_skills_dir) do
      nil ->
        release = Application.app_dir(:foreman_server, "priv/defaults/skills")
        if File.dir?(release), do: release, else: @source_tree_bundled_dir

      override ->
        override
    end
  end

  @doc false
  def __mix_recompile__? do
    current =
      case File.ls(@source_tree_bundled_dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(fn name ->
            File.dir?(Path.join(@source_tree_bundled_dir, name))
          end)
          |> Enum.sort()

        {:error, _} ->
          []
      end

    ForemanServer.Skills.Digest.digest(current, @source_tree_bundled_dir) !=
      @bundled_skills_fingerprint
  end

  @type option ::
          {:home_dir, Path.t()}
          | {:target_dir, Path.t()}
          | {:source_dir, Path.t()}
          | {:install_skills, [String.t()]}

  @spec install([option()]) :: {:ok, [Path.t()]} | {:error, term()}
  def install(opts \\ []) when is_list(opts) do
    source_dir = Keyword.get_lazy(opts, :source_dir, fn -> bundled_skills_source(opts) end)
    dest_dir = target_dir(opts)

    with :ok <- File.mkdir_p(dest_dir),
         {:ok, skill_names} <- list_skill_dirs(source_dir, opts) do
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
    source_dir = Keyword.get_lazy(opts, :source_dir, fn -> bundled_skills_source(opts) end)

    case list_skill_dirs(source_dir, opts) do
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

  # CodeRabbit #3: a missing source directory must not read as an empty bundle.
  #
  # `File.ls/1` reports an EMPTY directory as `{:ok, []}` and an ABSENT one as
  # `{:error, :enoent}`, so the two causes are distinguishable right here; folding them together
  # (AGENTS.md 5.3) is exactly what let a broken bundle source install zero skills and report a
  # successful no-op. Absent is now an error, with its own code, on both entry points:
  # `install/1` (an explicit `:source_dir` the caller named) reports `:source_dir_missing`, and
  # the auto-install path reports `:bundled_skills_missing` so the boot hook can say which
  # bundle it looked in.
  # The first code has no production caller today: the only caller of `install/1` is the boot
  # hook, which resolves the bundle itself, and no CLI flag or MCP tool sets a skills
  # `:source_dir` (`workflow.go:72` sets one for the *workflow* installer, a different module).
  # It is kept because §5.3 wants the two causes separable if such a caller is added.
  #
  # Empty stays `{:ok, []}` on both paths. It is a different fact from absent, and it is a
  # legitimate configuration rather than a defect: `Workflow.Install`'s own boot guard is
  # `bundled_templates_available?/1`, which is `File.dir? && manifest_filenames != []`
  # (`workflow/install.ex:201`) — an existing-but-empty directory takes the "already installed"
  # branch there, so erroring on empty here would make this installer disagree with the sibling
  # subsystem about the same situation. `maybe_install/1` already returns `{:ok, :noop}` for an
  # empty bundle via that guard, so no operator-visible behavior depends on the fold.
  defp list_skill_dirs(source_dir, opts) do
    # Only a caller that NAMED a path can be told it named a bad one; when the path was resolved
    # from the bundle, its absence is a packaging problem instead (§5.3).
    named? =
      case Keyword.fetch(opts, :source_dir) do
        {:ok, value} when is_binary(value) -> true
        _ -> false
      end

    case File.ls(source_dir) do
      {:ok, entries} ->
        dirs =
          entries
          |> Enum.filter(fn name -> File.dir?(Path.join(source_dir, name)) end)
          |> Enum.sort()

        {:ok, dirs}

      {:error, :enoent} ->
        {:error, missing_source_error(named?, source_dir)}

      {:error, reason} ->
        {:error, {:list_skills_failed, source_dir, reason}}
    end
  end

  # `:source_dir` present means the caller named a directory explicitly, so its absence is a
  # defect in THAT argument; absent `:source_dir` means the auto-detected bundle resolved to a
  # path that is not there, which is a packaging problem.
  defp missing_source_error(named?, source_dir) do
    if named?, do: {:source_dir_missing, source_dir}, else: {:bundled_skills_missing, source_dir}
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
