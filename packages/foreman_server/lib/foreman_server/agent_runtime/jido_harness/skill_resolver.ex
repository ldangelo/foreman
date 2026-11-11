defmodule ForemanServer.AgentRuntime.JidoHarness.SkillResolver do
  @moduledoc """
  Whether the harness that will launch a run can actually load a skill the
  workflow's `command:` names (TRD-021, PRD AC-007-1).

  The per-provider skill knowledge lives here, beside
  `ForemanServer.AgentRuntime.JidoHarness.ReadinessCheck` (which owns the
  per-provider install knowledge): one boundary for "what does this harness
  load". `ForemanServer.Skills.Installer` is deliberately not consulted: it
  installs the bundled skills into `~/.foreman/skills`, a directory pi does not
  read, so a skill found only there is `:missing`, not `:available`.

  ## Verdicts and the fail-safe rule

    * `:available` - the skill is positively found where the harness loads it.
    * `:missing` - absence is PROVEN across every source the harness loads for
      this launch.
    * `:unverifiable` - anything else. A caller must neither refuse a run nor
      promise a skill on evidence it does not have, so every input this module
      cannot resolve, read or parse (an unknown package source form, a package
      that is not on disk, an unreadable or invalid `settings.json` /
      `package.json`, a glob it cannot expand, frontmatter it cannot parse) ends
      in `:unverifiable`, never `:missing`.

  `:claude`, any other provider, and any backend other than the host workflow
  backend are `:unverifiable` (no repo-defined skill directory for claude; the
  host filesystem says nothing about what a container sees). No union across
  providers: a provider is answered from its own sources only.

  ## What pi loads (pi-coding-agent 1.5.0, `dist/bundle/chunks/chunk-44DLKSKE.js`)

  Verified from the loader source, not from the Foreman CLI's recommendation:

    * user skills dir `<agent_dir>/skills` and project skills dir
      `<project>/.pi/skills` (`addAutoDiscoveredResources`: `userDirs.skills =
      join(globalBaseDir, "skills")`, `projectDirs.skills = join(projectBaseDir,
      "skills")`, `projectBaseDir = join(cwd, ".pi")`). NOT `.pi/agent/skills`
      under a project. `agent_dir` is `PI_CODING_AGENT_DIR` (tilde-expanded) or
      `~/.pi/agent` (`getAgentDir`, chunk-36QC74V4.js).
    * `~/.agents/skills` and every `<dir>/.agents/skills` from the project up to
      its git root (`collectAncestorAgentsSkillDirs`).
    * the `skills` arrays in `<agent_dir>/settings.json` (resolved from
      `agent_dir`) and `<project>/.pi/settings.json` (resolved from
      `<project>/.pi`): plain entries are files or directories.
    * every package in `packages` of both settings files: `npm:<name>` at
      `<agent_dir>/npm/node_modules/<name>` (project scope:
      `<project>/.pi/npm/node_modules/<name>`), a git URL at
      `<agent_dir>/git/<host>/<user>/<repo>` (project scope under `.pi/git`), or
      a local path; each package contributes the paths of its `package.json`
      `pi.skills` manifest (plain paths and `*`/`?` globs), or `<package>/skills`
      when it declares no manifest resource fields.
    * a directory is scanned like `collectSkillEntries`: a `SKILL.md` ends the
      descent of its directory, dot directories and `node_modules` are skipped.
      A skill's name is its frontmatter `name`, else its directory's name, and a
      file without a non-empty frontmatter `description` is not loaded at all
      (`loadSkillFromFile`). The directory name is therefore NOT the identity.

  ## Conditions that make a find `:unverifiable` instead of `:available`

  A skill found only where pi's own decision cannot be reproduced at admission:

    * project-scoped sources (project `.pi/skills`, project settings and
      packages, ancestor `.agents/skills`): pi loads them only when the launch
      directory is trusted (`isProjectTrusted`), decided at run time from
      `trust.json`, the default-trust setting and the mode, for the worktree
      path that does not exist yet;
    * a source filtered by settings patterns (`!`, `+`, `-`, glob entries) or a
      package declared as an object with filters, or a scan that met an ignore
      file (`.gitignore`, `.ignore`, `.fdignore`), because those can exclude the
      file.

  `:missing` additionally requires that no extension could contribute skill
  paths: an extension's `resources_discover` handler can return `skillPaths`
  at run time, so any extension source (package `pi.extensions`, an
  `extensions` directory, an `extensions` settings entry, a local package
  directory with no resource fields) makes absence unprovable.

  ## Options

  All of them exist so tests never touch the real home directory.

    * `:home` - the home directory (default `System.user_home!/0`).
    * `:agent_dir` - pi's agent directory (default: `PI_CODING_AGENT_DIR` from
      the environment, else `<home>/.pi/agent`). The environment is read in
      `default_agent_dir/1` only. A value that is neither absolute nor
      `~`-prefixed is resolved by pi against the launch cwd, which does not exist
      at admission, so it makes the answer `:unverifiable`.
    * `:project_root` - the project's checkout (no worktree exists at admission).
      When omitted, project-scoped sources cannot be examined, so an absence can
      never be proven and the answer is `:unverifiable` unless the skill is found
      in a user-scoped source.
  """

  alias ForemanServer.Jobsite.ExecutionProfile

  @type verdict :: :available | :missing | :unverifiable

  @ignore_files [".gitignore", ".ignore", ".fdignore"]
  @resource_fields ["extensions", "skills", "prompts", "themes"]

  @spec resolve(atom(), String.t(), atom(), keyword()) :: verdict()
  def resolve(provider, skill, backend, opts \\ []) when is_binary(skill) do
    if backend == ExecutionProfile.host_backend() do
      resolve_on_host(provider, skill, opts)
    else
      :unverifiable
    end
  end

  # The requested name is only ever COMPARED with the identity of skills found
  # under the declared sources (pi: frontmatter `name`, taken verbatim; the
  # `/skill:<x>` command takes everything up to the first space). No path is
  # built from it, so no shape check is needed to keep it inside the roots.
  defp resolve_on_host(:pi, skill, opts), do: resolve_pi(skill, opts)

  defp resolve_on_host(_provider_without_repo_skill_dir, _skill, _opts), do: :unverifiable

  # ---------------------------------------------------------------------------
  # pi
  # ---------------------------------------------------------------------------

  defp resolve_pi(skill, opts) do
    home = Keyword.get_lazy(opts, :home, &System.user_home!/0)
    project_root = Keyword.get(opts, :project_root)

    with {:ok, agent_dir} <- agent_dir(opts, home),
         ctx = %{home: home, agent_dir: agent_dir, project_root: project_root},
         {:ok, acc} <- collect_sources(ctx) do
      verdict(acc, skill)
    else
      :error -> :unverifiable
    end
  end

  # pi resolves the agent directory with `resolvePath(agentDir)`, whose base is
  # the LAUNCH cwd. That cwd (a worktree) does not exist at admission, so a
  # value that is neither absolute nor `~`-prefixed cannot be resolved here.
  defp agent_dir(opts, home) do
    raw =
      case Keyword.fetch(opts, :agent_dir) do
        {:ok, value} -> value
        :error -> default_agent_dir(home)
      end

    case raw do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if Path.type(trimmed) == :absolute or trimmed == "~" or String.starts_with?(trimmed, "~/"),
          do: {:ok, expand(trimmed, "/", home)},
          else: :error

      _ ->
        :error
    end
  end

  # The one place the environment is read (`getAgentDir` in pi).
  defp default_agent_dir(home) do
    case System.get_env("PI_CODING_AGENT_DIR") do
      value when value in [nil, ""] -> Path.join(home, ".pi/agent")
      value -> value
    end
  end

  # Accumulator: `files` are `{path, mode, flags}` skill-file candidates,
  # `ext?` is true when an extension could add skills, `unsure?` when something
  # could not be resolved or read.
  defp new_acc, do: %{files: [], ext?: false, unsure?: false}

  defp collect_sources(ctx) do
    project_base = ctx.project_root && Path.join(ctx.project_root, ".pi")

    with {:ok, user_settings} <- read_settings(Path.join(ctx.agent_dir, "settings.json")),
         {:ok, project_settings} <- read_project_settings(project_base) do
      acc = new_acc()
      acc = if ctx.project_root == nil, do: %{acc | unsure?: true}, else: acc

      acc
      |> add_packages(ctx, project_settings, user_settings, project_base)
      |> add_settings_entries(user_settings, ctx.agent_dir, :user, ctx.home)
      |> add_settings_entries(project_settings, project_base, :project, ctx.home)
      |> add_auto_dirs(
        ctx,
        project_base,
        filter_flags(user_settings),
        filter_flags(project_settings)
      )
      |> then(&{:ok, &1})
    else
      :error -> :error
    end
  end

  defp read_project_settings(nil), do: {:ok, %{}}
  defp read_project_settings(base), do: read_settings(Path.join(base, "settings.json"))

  defp read_settings(path) do
    case read_json(path) do
      {:ok, nil} -> {:ok, %{}}
      {:ok, %{} = map} -> {:ok, map}
      _ -> :error
    end
  end

  # {:ok, nil} when the file is absent, {:ok, map} when it is a JSON object,
  # :error for any other outcome (unreadable, invalid, not an object).
  defp read_json(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(String.trim_leading(content, "\uFEFF")) do
          {:ok, %{} = map} -> {:ok, map}
          _ -> :error
        end

      {:error, :enoent} ->
        {:ok, nil}

      {:error, _} ->
        :error
    end
  end

  # -- auto-discovered directories (addAutoDiscoveredResources) ---------------

  # Every auto-discovered skill is run through `isEnabledByOverrides` with the
  # SAME scope's settings `skills` array (`userOverrides.skills`,
  # `projectOverrides.skills`), and pi keeps only the enabled ones. A scope whose
  # array holds any `!`, `+`, `-` or glob entry can therefore disable a skill in
  # its auto-discovered directories: a find there is `:unverifiable`. (The
  # overrides only remove skills, so absence is unaffected.)
  defp filter_flags(settings) do
    case Map.get(settings, "skills") do
      list when is_list(list) ->
        if Enum.any?(list, &(is_binary(&1) and pattern?(&1))), do: [:filtered], else: []

      _ ->
        []
    end
  end

  defp add_auto_dirs(acc, ctx, project_base, user_flags, project_flags) do
    acc
    |> add_scan(Path.join(ctx.agent_dir, "skills"), :pi, :user, user_flags)
    |> add_extension_dir(Path.join(ctx.agent_dir, "extensions"))
    |> add_scan(Path.join(ctx.home, ".agents/skills"), :agents, :user, user_flags)
    |> add_project_dirs(ctx, project_base, project_flags)
  end

  defp add_project_dirs(acc, %{project_root: nil}, _base, _flags), do: acc

  defp add_project_dirs(acc, ctx, project_base, flags) do
    user_agents = Path.join(ctx.home, ".agents/skills")

    acc =
      acc
      |> add_scan(Path.join(project_base, "skills"), :pi, :project, flags)
      |> add_extension_dir(Path.join(project_base, "extensions"))

    ctx.project_root
    |> ancestor_agents_skill_dirs()
    |> Enum.reject(&(&1 == user_agents))
    |> Enum.reduce(acc, &add_scan(&2, &1, :agents, :project, flags))
  end

  # `collectAncestorAgentsSkillDirs`: the start dir and every ancestor up to and
  # including the nearest directory holding `.git` (or the filesystem root).
  defp ancestor_agents_skill_dirs(start) do
    start = Path.expand(start)
    git_root = find_git_root(start)
    walk_ancestors(start, git_root, [])
  end

  defp walk_ancestors(dir, git_root, acc) do
    acc = [Path.join(dir, ".agents/skills") | acc]
    parent = Path.dirname(dir)

    cond do
      git_root != nil and dir == git_root -> Enum.reverse(acc)
      parent == dir -> Enum.reverse(acc)
      true -> walk_ancestors(parent, git_root, acc)
    end
  end

  defp find_git_root(dir) do
    cond do
      File.exists?(Path.join(dir, ".git")) -> dir
      Path.dirname(dir) == dir -> nil
      true -> find_git_root(Path.dirname(dir))
    end
  end

  # `collectAutoExtensionEntries`: the directory itself resolves an entry
  # (`pi.extensions` or `index.ts`/`index.js`), or a non-dot child other than
  # `node_modules` is a `.ts`/`.js` file or a directory that resolves one. Ignore
  # files can only remove entries, so they are not consulted.
  defp add_extension_dir(acc, dir) do
    case File.ls(dir) do
      {:ok, names} ->
        case extension_entries?(dir, names) do
          true -> %{acc | ext?: true}
          false -> acc
          :error -> %{acc | unsure?: true}
        end

      {:error, code} when code in [:enoent, :enotdir] ->
        acc

      {:error, _} ->
        %{acc | unsure?: true}
    end
  end

  defp extension_entries?(dir, names) do
    case resolves_extension_entry(dir) do
      :error ->
        :error

      true ->
        true

      false ->
        names
        |> Enum.reject(&(String.starts_with?(&1, ".") or &1 == "node_modules"))
        |> Enum.reduce_while(false, fn name, false ->
          path = Path.join(dir, name)

          case File.stat(path) do
            {:ok, %{type: :regular}} ->
              if String.ends_with?(name, [".ts", ".js"]), do: {:halt, true}, else: {:cont, false}

            {:ok, %{type: :directory}} ->
              case resolves_extension_entry(path) do
                :error -> {:halt, :error}
                found -> if found, do: {:halt, true}, else: {:cont, false}
              end

            _ ->
              {:cont, false}
          end
        end)
    end
  end

  # `resolveExtensionEntries`: a `pi.extensions` path that exists, else an index
  # file. A package.json this module cannot read is `:error`.
  defp resolves_extension_entry(dir) do
    manifest =
      case read_manifest(dir) do
        {:ok, nil} -> {:ok, []}
        {:ok, %{"extensions" => list}} -> {:ok, list}
        {:ok, _} -> {:ok, []}
        :error -> :error
      end

    case manifest do
      :error ->
        :error

      {:ok, declared} ->
        Enum.any?(declared, &File.exists?(Path.expand(declared_path(dir, &1)))) or
          File.exists?(Path.join(dir, "index.ts")) or File.exists?(Path.join(dir, "index.js"))
    end
  end

  # Node's `resolve(root, entry)`: an absolute entry stands alone, anything else
  # (including `~...`) is joined to the root. `~` is never expanded.
  defp declared_path(root, entry),
    do: if(Path.type(entry) == :absolute, do: entry, else: Path.join(root, entry))

  # -- settings.json `skills` / `extensions` arrays ---------------------------

  defp add_settings_entries(acc, settings, base, scope, home) do
    acc
    |> add_extension_entries(Map.get(settings, "extensions"))
    |> add_skill_entries(Map.get(settings, "skills"), base, scope, home)
  end

  defp add_extension_entries(acc, nil), do: acc
  defp add_extension_entries(acc, []), do: acc
  defp add_extension_entries(acc, list) when is_list(list), do: %{acc | ext?: true}
  defp add_extension_entries(acc, _malformed), do: %{acc | unsure?: true}

  defp add_skill_entries(acc, nil, _base, _scope, _home), do: acc

  defp add_skill_entries(acc, entries, base, scope, home) when is_list(entries) do
    if Enum.all?(entries, &is_binary/1) do
      {plain, patterns} = Enum.split_with(entries, &(not pattern?(&1)))
      flags = if patterns == [], do: [], else: [:filtered]

      Enum.reduce(plain, acc, fn entry, acc ->
        add_path(acc, expand(entry, base, home), scope, flags)
      end)
    else
      %{acc | unsure?: true}
    end
  end

  defp add_skill_entries(acc, _malformed, _base, _scope, _home), do: %{acc | unsure?: true}

  defp pattern?(entry),
    do: String.starts_with?(entry, ["!", "+", "-"]) or String.contains?(entry, ["*", "?"])

  # `collectFilesFromPaths` for the skills type: a file is itself, a directory
  # is scanned.
  defp add_path(acc, path, scope, flags) do
    case File.stat(path) do
      {:ok, %{type: :directory}} -> add_scan(acc, path, :pi, scope, flags)
      {:ok, %{type: :regular}} -> add_file(acc, path, scope, flags)
      {:ok, _other} -> acc
      {:error, :enoent} -> acc
      {:error, _} -> %{acc | unsure?: true}
    end
  end

  # -- packages ---------------------------------------------------------------

  defp add_packages(acc, ctx, project_settings, user_settings, project_base) do
    with {:ok, project_pkgs} <- package_list(project_settings),
         {:ok, user_pkgs} <- package_list(user_settings) do
      entries =
        Enum.map(project_pkgs, &{&1, :project}) ++ Enum.map(user_pkgs, &{&1, :user})

      entries
      |> dedupe(ctx, project_base)
      |> Enum.reduce(acc, fn {pkg, scope}, acc ->
        add_package(acc, ctx, pkg, scope, project_base)
      end)
    else
      :error -> %{acc | unsure?: true}
    end
  end

  defp package_list(settings) do
    case Map.get(settings, "packages") do
      nil -> {:ok, []}
      list when is_list(list) -> {:ok, list}
      _ -> :error
    end
  end

  # `dedupePackages`: the project entry wins over a user entry of the same
  # identity. An entry whose identity cannot be computed is kept (and fails in
  # `add_package`, which is `:unverifiable`).
  defp dedupe(entries, ctx, project_base) do
    {kept, _seen} =
      Enum.reduce(entries, {[], MapSet.new()}, fn {pkg, scope} = entry, {kept, seen} ->
        base = if scope == :project, do: project_base, else: ctx.agent_dir

        case package_identity(pkg, base, ctx.home) do
          {:ok, id} ->
            if MapSet.member?(seen, id),
              do: {kept, seen},
              else: {[entry | kept], MapSet.put(seen, id)}

          :error ->
            {[entry | kept], seen}
        end
      end)

    Enum.reverse(kept)
  end

  defp package_identity(pkg, base, home) do
    with {:ok, source, _filtered?} <- package_source(pkg),
         {:ok, parsed} <- parse_source(source) do
      case parsed do
        {:npm, name, _version} -> {:ok, "npm:" <> name}
        {:git, host, path} -> {:ok, "git:#{host}/#{path}"}
        {:local, path} -> {:ok, "local:" <> expand(path, base || "/", home)}
      end
    end
  end

  defp package_source(source) when is_binary(source), do: {:ok, source, false}

  defp package_source(%{"source" => source}) when is_binary(source) and source != "",
    do: {:ok, source, true}

  defp package_source(_), do: :error

  defp add_package(acc, ctx, pkg, scope, project_base) do
    flags = if is_map(pkg), do: [:filtered], else: []
    base = if scope == :project, do: project_base, else: ctx.agent_dir

    with true <- base != nil,
         {:ok, source, _} <- package_source(pkg),
         {:ok, parsed} <- parse_source(source),
         {:ok, root} <- package_root(parsed, scope, ctx, base),
         {:ok, %{type: :directory}} <- File.stat(root),
         {:ok, manifest} <- read_manifest(root) do
      collect_package(acc, root, manifest, scope, flags, local?(parsed))
    else
      _ -> %{acc | unsure?: true}
    end
  end

  defp local?({:local, _}), do: true
  defp local?(_), do: false

  # `parseSource` / `isLocalPath` / `parseGitUrl` for the forms whose install
  # location can be computed. Everything else is `:error` (unverifiable).
  defp parse_source("npm:" <> spec) do
    case Regex.run(~r/^(@?[^@]+(?:\/[^@]+)?)(?:@(.+))?$/, String.trim(spec)) do
      [_, name] -> npm_source(name, nil)
      [_, name, version] -> npm_source(name, version)
      _ -> :error
    end
  end

  defp parse_source(source) do
    trimmed = String.trim(source)

    cond do
      String.starts_with?(trimmed, ["git:", "github:", "ssh:", "builtin:"]) ->
        :error

      String.starts_with?(trimmed, ["http:", "https:"]) ->
        parse_git_https(trimmed)

      true ->
        {:ok, {:local, source}}
    end
  end

  defp npm_source(name, version) do
    segments = String.split(name, "/")

    if name != "" and Enum.all?(segments, &(&1 not in ["", ".", ".."])) and
         not String.starts_with?(name, "/"),
       do: {:ok, {:npm, name, version}},
       else: :error
  end

  # hosted-git-info owns `host`/`path` for the well-known hosts: `<host>`,
  # `<user>/<project>` with a trailing `.git` stripped. Other hosts and shapes
  # go through a generic parser this module does not reproduce.
  defp parse_git_https(url) do
    with %URI{scheme: scheme, host: host, path: path, userinfo: nil}
         when scheme in ["https", "http"] and
                host in ["github.com", "gitlab.com", "bitbucket.org"] <-
           URI.parse(url),
         [user, project] <- path |> String.trim("/") |> String.split("/"),
         project = String.replace_suffix(project, ".git", ""),
         true <- user != "" and project != "" do
      {:ok, {:git, host, "#{user}/#{project}"}}
    else
      _ -> :error
    end
  end

  # An npm or git package that is not installed would be installed by pi at
  # launch, so a missing directory is `:error` (unverifiable), as is an npm
  # package whose installed version is not provably the configured one.
  defp package_root({:npm, name, version}, scope, ctx, _base) do
    install_root =
      if scope == :project,
        do: ctx.project_root && Path.join(ctx.project_root, ".pi/npm"),
        else: Path.join(ctx.agent_dir, "npm")

    with true <- install_root != nil,
         root = Path.join([install_root, "node_modules", name]),
         {:ok, %{"version" => installed}} when is_binary(installed) <-
           read_json(Path.join(root, "package.json")) |> nonnil(),
         true <- version == nil or version == installed do
      {:ok, root}
    else
      _ -> :error
    end
  end

  defp package_root({:git, host, path}, scope, ctx, _base) do
    install_root =
      if scope == :project,
        do: ctx.project_root && Path.join(ctx.project_root, ".pi/git"),
        else: Path.join(ctx.agent_dir, "git")

    if install_root, do: {:ok, Path.join([install_root, host, path])}, else: :error
  end

  defp package_root({:local, path}, _scope, ctx, base), do: {:ok, expand(path, base, ctx.home)}

  defp nonnil({:ok, nil}), do: :error
  defp nonnil(other), do: other

  # `readPiManifest`: nil when package.json is absent or has no `pi` object; a
  # package.json that cannot be read or parsed, or a resource field that is not
  # an array of strings, is `:error` (pi ignores those, this module does not
  # guess what that means for the answer).
  defp read_manifest(root) do
    case read_json(Path.join(root, "package.json")) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %{"pi" => %{} = pi}} ->
        Enum.reduce_while(@resource_fields, {:ok, %{}}, fn field, {:ok, manifest} ->
          case Map.get(pi, field) do
            nil -> {:cont, {:ok, manifest}}
            list when is_list(list) -> manifest_field(manifest, field, list)
            _ -> {:halt, :error}
          end
        end)
        |> case do
          {:ok, manifest} -> {:ok, manifest}
          :error -> :error
        end

      {:ok, %{}} ->
        {:ok, nil}

      :error ->
        :error
    end
  end

  defp manifest_field(manifest, field, list) do
    if Enum.all?(list, &is_binary/1),
      do: {:cont, {:ok, Map.put(manifest, field, list)}},
      else: {:halt, :error}
  end

  # `collectPackageResources`.
  defp collect_package(acc, root, manifest, scope, flags, local?) do
    cond do
      manifest != nil and map_size(manifest) > 0 ->
        acc
        |> package_extensions(Map.get(manifest, "extensions"))
        |> package_manifest_skills(root, Map.get(manifest, "skills"), scope, flags)

      true ->
        convention_package(acc, root, scope, flags, local?)
    end
  end

  defp package_extensions(acc, list) when list in [nil, []], do: acc
  defp package_extensions(acc, _declared), do: %{acc | ext?: true}

  defp package_manifest_skills(acc, _root, nil, _scope, _flags), do: acc

  defp package_manifest_skills(acc, root, entries, scope, flags) do
    {patterns, plain} = Enum.split_with(entries, &String.starts_with?(&1, ["!", "+", "-"]))
    flags = if patterns == [], do: flags, else: [:filtered | flags]

    Enum.reduce(plain, acc, fn entry, acc ->
      if String.contains?(entry, ["*", "?"]) do
        add_glob(acc, root, entry, scope, flags)
      else
        add_path(acc, Path.expand(declared_path(root, entry)), scope, flags)
      end
    end)
  end

  # `expandPackageGlob`: matches under the package root, hidden segments
  # dropped. A pattern using syntax `Path.wildcard/1` reads differently from
  # node's glob (braces, classes) is not expanded.
  defp add_glob(acc, root, pattern, scope, flags) do
    if String.contains?(pattern, ["{", "}", "[", "]"]) do
      %{acc | unsure?: true}
    else
      root
      |> Path.join(pattern)
      |> Path.wildcard()
      |> Enum.reject(fn path ->
        # `Path.wildcard/1` keeps the pattern's literal prefix, so strip it to
        # get the segments below the package root. (`Path.relative_to/2` would
        # normalise a `..` match into an absolute path and put the root's own
        # hidden ancestors into the check.)
        path
        |> String.replace_prefix(Path.join(root, ""), "")
        |> Path.split()
        |> Enum.any?(&(String.starts_with?(&1, ".") and &1 != ".."))
      end)
      |> Enum.reduce(acc, &add_path(&2, &1, scope, flags))
    end
  end

  # No manifest resource fields: the conventional `<root>/<type>` directories;
  # none of them and a local package means the directory is itself an
  # extension entry.
  defp convention_package(acc, root, scope, flags, local?) do
    skills = Path.join(root, "skills")
    ext = Path.join(root, "extensions")
    any_dir? = Enum.any?(~w(extensions skills prompts themes), &File.dir?(Path.join(root, &1)))

    acc = if File.dir?(ext), do: %{acc | ext?: true}, else: acc
    acc = if not any_dir? and local?, do: %{acc | ext?: true}, else: acc
    add_scan(acc, skills, :pi, scope, flags)
  end

  # ---------------------------------------------------------------------------
  # scanning (`collectSkillEntries`)
  # ---------------------------------------------------------------------------

  defp add_scan(acc, dir, mode, scope, flags) do
    case scan(dir, mode, dir) do
      {:ok, files, ignore?} ->
        flags = if ignore?, do: [:ignore | flags], else: flags

        %{acc | files: Enum.map(files, &{&1, scope, flags}) ++ acc.files}

      :enoent ->
        acc

      :error ->
        %{acc | unsure?: true}
    end
  end

  defp add_file(acc, path, scope, flags) do
    if String.ends_with?(path, ".md"),
      do: %{acc | files: [{path, scope, flags} | acc.files]},
      else: acc
  end

  # {:ok, files, ignore_file_seen?} | :enoent | :error
  defp scan(dir, mode, root) do
    case File.ls(dir) do
      {:error, :enoent} ->
        :enoent

      {:error, :enotdir} ->
        :enoent

      {:error, _} ->
        :error

      {:ok, names} ->
        ignore? = Enum.any?(@ignore_files, &(&1 in names))

        if "SKILL.md" in names and regular?(Path.join(dir, "SKILL.md")) == true do
          {:ok, [Path.join(dir, "SKILL.md")], ignore?}
        else
          scan_children(dir, names, mode, root, ignore?)
        end
    end
  end

  defp scan_children(dir, names, mode, root, ignore?) do
    names
    |> Enum.reject(&(String.starts_with?(&1, ".") or &1 == "node_modules"))
    |> Enum.reduce_while({:ok, [], ignore?}, fn name, {:ok, files, ignore?} ->
      path = Path.join(dir, name)

      case File.stat(path) do
        {:ok, %{type: :directory}} ->
          case scan(path, mode, root) do
            {:ok, sub, sub_ignore?} -> {:cont, {:ok, sub ++ files, ignore? or sub_ignore?}}
            :enoent -> {:cont, {:ok, files, ignore?}}
            :error -> {:halt, :error}
          end

        {:ok, %{type: :regular}} ->
          loose_ok? = (mode == :pi and dir == root) or (mode == :agents and dir != root)

          if String.ends_with?(name, ".md") and loose_ok?,
            do: {:cont, {:ok, [path | files], ignore?}},
            else: {:cont, {:ok, files, ignore?}}

        {:ok, _other} ->
          {:cont, {:ok, files, ignore?}}

        {:error, _} ->
          # A broken symlink is skipped by pi; anything else is unreadable.
          {:cont, {:ok, files, ignore?}}
      end
    end)
  end

  defp regular?(path) do
    match?({:ok, %{type: :regular}}, File.stat(path))
  end

  # ---------------------------------------------------------------------------
  # verdict
  # ---------------------------------------------------------------------------

  defp verdict(acc, skill) do
    {matches, unsure?} =
      Enum.reduce(acc.files, {[], acc.unsure?}, fn {path, scope, flags}, {matches, unsure?} ->
        case skill_identity(path) do
          {:ok, ^skill} -> {[{scope, flags} | matches], unsure?}
          {:ok, _other_or_unloaded} -> {matches, unsure?}
          :error -> {matches, true}
        end
      end)

    cond do
      Enum.any?(matches, fn {scope, flags} -> scope == :user and flags == [] end) -> :available
      matches != [] -> :unverifiable
      unsure? or acc.ext? -> :unverifiable
      true -> :missing
    end
  end

  # `loadSkillFromFile`: `{:ok, name}` for a file pi loads, `{:ok, nil}` for one
  # it does not, `:error` for one this module cannot judge.
  defp skill_identity(path) do
    with {:ok, content} <- File.read(path),
         {:ok, front} <- frontmatter(content) do
      case front.description do
        :present -> {:ok, identity_name(front.name, path)}
        :absent -> {:ok, nil}
      end
    else
      _ -> :error
    end
  end

  # An empty `name` is falsy in pi's `name || parentDirName`.
  defp identity_name(name, path) when name in [nil, ""], do: Path.basename(Path.dirname(path))
  defp identity_name(name, _path), do: name

  # Frontmatter, restricted to what decides loading: `name` (a string or
  # absent) and whether `description` is a non-empty string. Any construct this
  # reader does not understand is `:error`.
  defp frontmatter(content) do
    normalized =
      content
      |> String.trim_leading("\uFEFF")
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")

    with true <- String.starts_with?(normalized, "---"),
         [_ | _] = rest <- :binary.matches(normalized, "\n---"),
         {index, _} <- Enum.find(rest, fn {i, _} -> i >= 3 end) do
      yaml = binary_part(normalized, 4, max(index - 4, 0))
      parse_yaml_header(yaml)
    else
      _ -> {:ok, %{name: nil, description: :absent}}
    end
  end

  defp parse_yaml_header(yaml) do
    lines = String.split(yaml, "\n")

    with {:ok, entries} <- group_keys(lines),
         keys = Enum.map(entries, &elem(&1, 0)),
         true <- keys == Enum.uniq(keys),
         {:ok, name} <- scalar_field(entries, "name"),
         {:ok, description} <- scalar_field(entries, "description") do
      present? = is_binary(description) and String.trim(description) != ""
      {:ok, %{name: name, description: if(present?, do: :present, else: :absent)}}
    else
      _ -> :error
    end
  end

  # Top-level `key: value` entries with their indented continuation lines.
  defp group_keys(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, entries} ->
      cond do
        String.trim(line) == "" or String.starts_with?(String.trim_leading(line), "#") ->
          {:cont, {:ok, entries}}

        String.starts_with?(line, [" ", "\t"]) ->
          case entries do
            [{key, value, cont} | rest] -> {:cont, {:ok, [{key, value, cont ++ [line]} | rest]}}
            [] -> {:halt, :error}
          end

        true ->
          case Regex.run(~r/^([A-Za-z0-9_-]+):(?:\s+(.*))?$/, line) do
            [_, key] -> {:cont, {:ok, [{key, "", []} | entries]}}
            [_, key, value] -> {:cont, {:ok, [{key, value, []} | entries]}}
            _ -> {:halt, :error}
          end
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      :error -> :error
    end
  end

  # {:ok, string | nil} for the field, `:error` for a form not understood. An
  # absent field and an explicit null are both `nil` (pi: not a string).
  defp scalar_field(entries, key) do
    case List.keyfind(entries, key, 0) do
      nil -> {:ok, nil}
      {_, value, continuation} -> scalar_value(String.trim(value), continuation)
    end
  end

  defp scalar_value("", []), do: {:ok, nil}

  # A key with no inline value and indented lines is a nested structure, not a
  # string.
  defp scalar_value("", _continuation), do: :error

  defp scalar_value(<<q, _::binary>> = value, []) when q in [?", ?'] do
    inner = String.slice(value, 1..-2//1)

    if String.ends_with?(value, <<q>>) and String.length(value) >= 2 and
         not String.contains?(inner, [<<q>>, "\\"]),
       do: {:ok, inner},
       else: :error
  end

  defp scalar_value(<<c, _::binary>> = value, continuation) when c in [?|, ?>] do
    if Regex.match?(~r/^[|>][+-]?[0-9]?$/, value) do
      {:ok, continuation |> Enum.map_join("\n", &String.trim/1) |> String.trim()}
    else
      :error
    end
  end

  defp scalar_value(value, continuation) do
    cond do
      String.starts_with?(value, ["[", "{", "&", "*", "!", "%", "@", "`", "#", "'", "\""]) ->
        :error

      String.contains?(value, [": ", " #"]) ->
        :error

      # Not a YAML string: pi would ignore it.
      # (null, booleans, and every number form: decimal, `.inf`, `.nan`,
      # `0x17`, `0o17`). Anything starting like a number is not read.
      value in ["~", "null", "Null", "NULL", "true", "false", "True", "False"] or
          String.starts_with?(value, [
            "0",
            "1",
            "2",
            "3",
            "4",
            "5",
            "6",
            "7",
            "8",
            "9",
            "-",
            "+",
            "."
          ]) ->
        :error

      true ->
        plain_multiline(value, continuation)
    end
  end

  defp plain_multiline(first, continuation) do
    parts = [first | Enum.map(continuation, &String.trim/1)]

    if Enum.any?(continuation, &String.contains?(&1, [": ", " #"])),
      do: :error,
      else: {:ok, parts |> Enum.reject(&(&1 == "")) |> Enum.join(" ")}
  end

  # ---------------------------------------------------------------------------
  # paths (`resolvePath` in pi: trim, expand a leading `~`, resolve from base)
  # ---------------------------------------------------------------------------

  defp expand(input, base, home) do
    trimmed = String.trim(input)

    path =
      case trimmed do
        "~" -> home
        "~/" <> rest -> Path.join(home, rest)
        other -> other
      end

    Path.expand(path, base)
  end
end
