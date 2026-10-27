defmodule ForemanServer.WorkflowTemplate.Installer do
  @moduledoc """
  Installs workflow templates into a Foreman workflows directory.
  """

  # The legacy sets are derived below from the bundled directory.

  # The bundled manifest filenames, discovered from the actual source
  # directory at compile time rather than hand-maintained — a hardcoded list
  # silently disagreed with the bundled directory the moment a workflow was
  # added or removed, which is exactly what blocked `foreman init --force`
  # after commit 04ba2383 removed several manifests this list still named
  # (AGENTS.md §5.5). Used only by `download_templates/2`, the remote-fetch
  # fallback exercised when no local bundled directory exists at all; the
  # local-copy path (`bundled_templates_available?/1`, `copy_manifests/2`)
  # lists its `source_dir` argument at runtime instead, since that argument
  # need not be the bundled directory (e.g. tests).
  @bundled_workflows_glob Path.join([
                            __DIR__,
                            "..",
                            "..",
                            "..",
                            "priv",
                            "defaults",
                            "workflows",
                            "*.yaml"
                          ])
  @bundled_template_sources @bundled_workflows_glob |> Path.wildcard() |> Enum.sort()

  for source <- @bundled_template_sources do
    @external_resource source
  end

  @bundled_template_files Enum.map(@bundled_template_sources, &Path.basename/1)

  # Same discovery, for bundled prompt files. `fetch_remote/1`'s
  # remote-fallback path previously downloaded only `.yaml` manifests, never
  # `prompts/*.md` — real for every prompt, not just the ones this PR adds,
  # but only surfaced once a manifest referenced a prompt that a remote
  # fallback install could never have fetched.
  @bundled_prompts_glob Path.join([
                          __DIR__,
                          "..",
                          "..",
                          "..",
                          "priv",
                          "defaults",
                          "workflows",
                          "prompts",
                          "*.md"
                        ])
  @bundled_prompt_sources @bundled_prompts_glob |> Path.wildcard() |> Enum.sort()

  for source <- @bundled_prompt_sources do
    @external_resource source
  end

  @bundled_prompt_files Enum.map(@bundled_prompt_sources, &Path.basename/1)

  @bundled_workflow_names @bundled_template_files |> Enum.map(&Path.rootname/1) |> Enum.sort()
  @bundled_prompt_names @bundled_prompt_files |> Enum.map(&Path.rootname/1) |> Enum.sort()

  # Legacy = shipped before minus bundled now, so a bundled name can never be
  # removed. Evidence is `git log --all --name-only` over
  # packages/foreman_server/priv/defaults/workflows and src/defaults/workflows
  # (TS-era): every `*.yaml` name ever added there. Names are added here only,
  # never guessed; one still bundled drops out of the legacy set automatically.
  @ever_shipped_workflow_names ~w(assess bug chore default discover docs epic feature fix
    implement implement-trd implement-trd-beads medium plan pr-review-workflow prd question
    quick release review small smoke task tdd trd verify)
  # Flat `prompts/<name>.md` files ever shipped under
  # priv/defaults/workflows/prompts (the installed `<target>/prompts` layout).
  @ever_shipped_prompt_names ~w(assess create-pr discover fix implement plan release
    review-coderabbit review-repo-rules verify)
  @legacy_workflow_names @ever_shipped_workflow_names
                         |> Kernel.--(@bundled_workflow_names)
                         |> Enum.sort()
  @legacy_prompt_names @ever_shipped_prompt_names
                       |> Kernel.--(@bundled_prompt_names)
                       |> Enum.sort()

  # Sorted as one combined list, not `sort(a) ++ sort(b)` — the two are not
  # equivalent once workflow and prompt paths interleave (e.g. `prompts/*`
  # sorts between `prd.yaml` and `review.yaml`), and `__mix_recompile__?/0`
  # below compares against a single sort of the combined wildcard results.
  # A mismatched order here would make it report a spurious recompile need
  # on every compile even with no file changes (CodeRabbit finding,
  # install.ex:65-69).
  @bundled_sources_fingerprint :erlang.md5(
                                 Enum.join(
                                   Enum.sort(
                                     @bundled_template_sources ++ @bundled_prompt_sources
                                   ),
                                   "\n"
                                 )
                               )

  # `@external_resource` only forces a recompile when a file already in the
  # list changes. A brand-new (or removed) manifest or prompt is not
  # reflected until this module recompiles; `__mix_recompile__?/0` is Mix's
  # supported escape hatch for compile-time state derived from a glob
  # (mirrors `EventCodec`).
  @doc false
  def __mix_recompile__? do
    current =
      (@bundled_workflows_glob |> Path.wildcard()) ++ (@bundled_prompts_glob |> Path.wildcard())

    :erlang.md5(Enum.join(Enum.sort(current), "\n")) != @bundled_sources_fingerprint
  end

  @default_retry_attempts 3
  @default_retry_delay_ms 250

  @type option ::
          {:home_dir, Path.t()}
          | {:target_dir, Path.t()}
          | {:source_dir, Path.t()}
          | {:remote_url, String.t()}
          | {:retry_attempts, pos_integer()}
          | {:retry_delay_ms, non_neg_integer()}

  @spec install([option()]) :: {:ok, [Path.t()]} | {:error, term()}
  def install(opts) when is_list(opts) do
    source_dir = Keyword.get(opts, :source_dir, bundled_source_dir())

    if bundled_templates_available?(source_dir) do
      copy_bundled_templates(source_dir, target_dir(opts))
    else
      fetch_remote(opts)
    end
  end

  @doc """
  Removes the workflow manifests and prompts Foreman once shipped but no longer
  bundles (`legacy_workflow_names/0`, `legacy_prompt_names/0`) from the target
  directory. Bundled files and anything Foreman never shipped (an operator's own
  workflow) are never touched.

  Returns `{:ok, %{removed: paths, absent: paths}}`: `removed` are the files
  deleted, `absent` the legacy paths that were not there (idempotent).
  """
  @spec remove_all([option()]) ::
          {:ok, %{removed: [Path.t()], absent: [Path.t()]}} | {:error, term()}
  def remove_all(opts) when is_list(opts) do
    td = target_dir(opts)

    candidates =
      Enum.map(@legacy_workflow_names, &Path.join(td, "#{&1}.yaml")) ++
        Enum.map(@legacy_prompt_names, &Path.join([td, "prompts", "#{&1}.md"]))

    candidates
    |> Enum.reduce_while({:ok, [], []}, fn path, {:ok, removed, absent} ->
      case File.rm(path) do
        :ok -> {:cont, {:ok, [path | removed], absent}}
        {:error, :enoent} -> {:cont, {:ok, removed, [path | absent]}}
        {:error, reason} -> {:halt, {:error, {:remove_failed, path, reason}}}
      end
    end)
    |> case do
      {:ok, removed, absent} ->
        {:ok, %{removed: Enum.reverse(removed), absent: Enum.reverse(absent)}}

      err ->
        err
    end
  end

  @doc "Manifest names Foreman shipped before and no longer bundles (sorted)."
  @spec legacy_workflow_names() :: [String.t()]
  def legacy_workflow_names, do: @legacy_workflow_names

  @doc "Prompt names (flat `prompts/<name>.md`) Foreman shipped before and no longer bundles (sorted)."
  @spec legacy_prompt_names() :: [String.t()]
  def legacy_prompt_names, do: @legacy_prompt_names

  @doc "Bundled manifest names (sorted)."
  @spec bundled_workflow_names() :: [String.t()]
  def bundled_workflow_names, do: @bundled_workflow_names

  @doc "Bundled prompt names (sorted)."
  @spec bundled_prompt_names() :: [String.t()]
  def bundled_prompt_names, do: @bundled_prompt_names

  @spec fetch_remote([option()]) :: {:ok, [Path.t()]} | {:error, term()}
  def fetch_remote(opts) when is_list(opts) do
    with {:ok, remote_url} <- remote_url(opts),
         {:ok, manifest_downloads} <-
           download_templates(remote_url, @bundled_template_files, opts),
         {:ok, prompt_downloads} <- download_templates(remote_url, prompt_relative_paths(), opts),
         {:ok, installed_paths} <-
           write_downloads(target_dir(opts), manifest_downloads ++ prompt_downloads) do
      {:ok, installed_paths}
    end
  end

  defp prompt_relative_paths, do: Enum.map(@bundled_prompt_files, &Path.join("prompts", &1))

  defp bundled_source_dir do
    Application.app_dir(:foreman_server, "priv/defaults/workflows")
  end

  # Discovered from the source directory rather than a hand-maintained list:
  # a hardcoded set of `.yaml` names silently disagrees with the bundled
  # directory the moment a workflow is added or removed (AGENTS.md §5.5), and
  # `Enum.all?/2` over a stale list blocked `foreman init --force` outright
  # once commit 04ba2383 removed several bundled manifests it still named.
  defp manifest_filenames(source_dir) do
    source_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".yaml"))
    |> Enum.sort()
  end

  defp bundled_templates_available?(source_dir) do
    File.dir?(source_dir) and manifest_filenames(source_dir) != []
  end

  defp copy_bundled_templates(source_dir, destination_dir) do
    with :ok <- File.mkdir_p(destination_dir),
         {:ok, manifest_paths} <- copy_manifests(source_dir, destination_dir),
         {:ok, prompt_paths} <- copy_prompts(source_dir, destination_dir) do
      {:ok, manifest_paths ++ prompt_paths}
    end
  end

  defp copy_manifests(source_dir, destination_dir) do
    source_dir
    |> manifest_filenames()
    |> Enum.reduce_while({:ok, []}, fn filename, {:ok, paths} ->
      source_path = Path.join(source_dir, filename)
      destination_path = Path.join(destination_dir, filename)

      case File.cp(source_path, destination_path) do
        :ok -> {:cont, {:ok, [destination_path | paths]}}
        {:error, reason} -> {:halt, {:error, {:copy_failed, source_path, reason}}}
      end
    end)
    |> reverse_ok_paths()
  end

  defp copy_prompts(source_dir, destination_dir) do
    source_prompts = Path.join(source_dir, "prompts")
    destination_prompts = Path.join(destination_dir, "prompts")

    cond do
      not File.dir?(source_prompts) ->
        {:ok, []}

      :ok != File.mkdir_p(destination_prompts) ->
        {:error, {:mkdir_failed, destination_prompts}}

      true ->
        source_prompts
        |> File.ls!()
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn filename, {:ok, paths} ->
          source_path = Path.join(source_prompts, filename)
          destination_path = Path.join(destination_prompts, filename)

          case File.cp(source_path, destination_path) do
            :ok -> {:cont, {:ok, [destination_path | paths]}}
            {:error, reason} -> {:halt, {:error, {:copy_failed, source_path, reason}}}
          end
        end)
        |> reverse_ok_paths()
    end
  end

  defp remote_url(opts) do
    case Keyword.get(
           opts,
           :remote_url,
           Application.get_env(:foreman_server, :workflow_remote_url)
         ) do
      nil -> {:error, :missing_remote_url}
      url when is_binary(url) and url != "" -> {:ok, url}
      url -> {:error, {:invalid_remote_url, url}}
    end
  end

  defp download_templates(remote_url, relative_paths, opts) do
    attempts = Keyword.get(opts, :retry_attempts, @default_retry_attempts)
    delay_ms = Keyword.get(opts, :retry_delay_ms, @default_retry_delay_ms)

    relative_paths
    |> Enum.reduce_while({:ok, []}, fn relative_path, {:ok, downloads} ->
      case download_template(
             remote_template_url(remote_url, relative_path),
             relative_path,
             attempts,
             delay_ms
           ) do
        {:ok, body} -> {:cont, {:ok, [{relative_path, body} | downloads]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_ok_downloads()
  end

  defp download_template(url, filename, attempts, delay_ms) when attempts > 0 do
    case curl_get(url) do
      {:ok, body} ->
        {:ok, body}

      {:error, _reason} when attempts > 1 ->
        Process.sleep(delay_ms)
        download_template(url, filename, attempts - 1, delay_ms)

      {:error, reason} ->
        {:error, {:download_failed, filename, reason}}
    end
  end

  defp curl_get(url) do
    case System.find_executable("curl") do
      nil ->
        {:error, :curl_not_found}

      curl ->
        args = ["--fail", "--silent", "--show-error", "--location", url]

        case System.cmd(curl, args, stderr_to_stdout: true) do
          {body, 0} ->
            {:ok, body}

          {error_output, status} ->
            {:error, {:curl_failed, status, String.trim(error_output)}}
        end
    end
  end

  defp write_downloads(destination_dir, downloads) do
    with :ok <- File.mkdir_p(destination_dir) do
      downloads
      |> Enum.reduce_while({:ok, []}, fn {relative_path, body}, {:ok, paths} ->
        destination_path = Path.join(destination_dir, relative_path)

        with :ok <- File.mkdir_p(Path.dirname(destination_path)),
             :ok <- File.write(destination_path, body) do
          {:cont, {:ok, [destination_path | paths]}}
        else
          {:error, reason} -> {:halt, {:error, {:write_failed, destination_path, reason}}}
        end
      end)
      |> reverse_ok_paths()
    end
  end

  defp target_dir(opts) do
    case Keyword.get(opts, :target_dir) do
      nil ->
        Path.join([Keyword.get(opts, :home_dir, System.user_home!()), ".foreman", "workflows"])

      path ->
        path
    end
  end

  defp remote_template_url(base_url, filename) do
    cond do
      String.contains?(base_url, "%{file}") ->
        String.replace(base_url, "%{file}", filename)

      String.contains?(base_url, "{file}") ->
        String.replace(base_url, "{file}", filename)

      true ->
        base_url
        |> ensure_trailing_slash()
        |> URI.merge(filename)
        |> to_string()
    end
  end

  defp ensure_trailing_slash(url) do
    if String.ends_with?(url, "/") do
      url
    else
      url <> "/"
    end
  end

  defp reverse_ok_paths({:ok, paths}), do: {:ok, Enum.reverse(paths)}
  defp reverse_ok_paths({:error, _reason} = error), do: error

  defp reverse_ok_downloads({:ok, downloads}), do: {:ok, Enum.reverse(downloads)}
  defp reverse_ok_downloads({:error, _reason} = error), do: error
end

defmodule WorkflowTemplate.Installer do
  @moduledoc false

  defdelegate install(opts), to: ForemanServer.WorkflowTemplate.Installer
  defdelegate fetch_remote(opts), to: ForemanServer.WorkflowTemplate.Installer
end
