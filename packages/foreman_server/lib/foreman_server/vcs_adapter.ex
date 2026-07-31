defmodule ForemanServer.VcsAdapter do
  @moduledoc """
  Event-owned VCS adapter boundary.

  New clone/branch/create_pr operations emit lifecycle events through
  `ForemanServer.CommandRouter` and retry transient failures with exponential
  backoff. Legacy worktree and merge helpers remain as thin command-router
  wrappers so existing call sites stay event-routed.
  """

  alias ForemanServer.CommandRouter

  @type backend :: :git | :jujutsu
  @type operation :: :clone | :branch | :create_pr
  @type operation_result :: {:ok, %{event: map(), projection: map(), result: map()}} | {:error, term()}
  @type legacy_result :: {:ok, %{event: map(), projection: map(), result: map()}} | {:error, term()}

  @callback clone(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback branch(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback create_pr(map(), keyword()) :: {:ok, map()} | {:error, term()}

  @default_impl ForemanServer.VcsAdapter.Default
  @default_retries 3
  @default_base_backoff_ms 200

  @spec clone(map(), keyword()) :: operation_result()
  def clone(input, opts \\ []) when is_map(input) and is_list(opts), do: execute(:clone, input, opts)

  @spec branch(map(), keyword()) :: operation_result()
  def branch(input, opts \\ []) when is_map(input) and is_list(opts), do: execute(:branch, input, opts)

  @spec create_pr(map(), keyword()) :: operation_result()
  def create_pr(input, opts \\ []) when is_map(input) and is_list(opts), do: execute(:create_pr, input, opts)

  @spec create_worktree(map()) :: legacy_result()
  def create_worktree(input) when is_map(input) do
    with {:ok, backend} <- backend(value(input, :backend, :git)),
         {:ok, run_id} <- required_binary(value(input, :run_id), :run_id),
         {:ok, workspace_id} <- required_binary(value(input, :workspace_id, run_id), :workspace_id),
         {:ok, project_path} <- required_binary(value(input, :project_path), :project_path),
         {:ok, base_ref} <- required_binary(value(input, :base_ref, "HEAD"), :base_ref) do
      branch = value(input, :branch, "foreman/#{run_id}")

      worktree_path =
        value(input, :worktree_path, Path.join([project_path, ".foreman", "worktrees", run_id]))

      stale = observe_stale(worktree_path)
      policy = value(input, :stale_policy, "reuse")

      payload = %{
        operation_id: value(input, :operation_id, "vcs-#{run_id}"),
        run_id: run_id,
        workspace_id: workspace_id,
        backend: Atom.to_string(backend),
        project_path: project_path,
        worktree_path: worktree_path,
        branch: branch,
        base_ref: base_ref,
        revision: value(input, :revision, base_ref),
        stale: stale,
        stale_policy: policy,
        effects: stale_effects(stale, policy, backend),
        adapter: adapter_details(backend)
      }
      |> put_if(:project_id, value(input, :project_id))

      dispatch_legacy("vcs.worktree.create", payload)
    end
  end

  @spec cleanup_worktree(map()) :: legacy_result()
  def cleanup_worktree(input) when is_map(input) do
    with {:ok, backend} <- backend(value(input, :backend, :git)),
         {:ok, run_id} <- required_binary(value(input, :run_id), :run_id),
         {:ok, worktree_path} <- required_binary(value(input, :worktree_path), :worktree_path) do
      payload = %{
        operation_id: value(input, :operation_id, "cleanup-#{run_id}"),
        run_id: run_id,
        backend: Atom.to_string(backend),
        worktree_path: worktree_path,
        effects: [%{action: "remove_worktree", path: worktree_path}],
        adapter: adapter_details(backend)
      }
      |> put_if(:project_id, value(input, :project_id))

      dispatch_legacy("vcs.worktree.clean", payload)
    end
  end

  @spec merge_branch(map()) :: legacy_result()
  def merge_branch(input) when is_map(input) do
    with {:ok, backend} <- backend(value(input, :backend, :git)),
         {:ok, run_id} <- required_binary(value(input, :run_id), :run_id),
         {:ok, branch} <- required_binary(value(input, :branch), :branch),
         {:ok, target} <- required_binary(value(input, :target, "main"), :target) do
      payload = %{
        operation_id: value(input, :operation_id, "merge-#{run_id}"),
        run_id: run_id,
        backend: Atom.to_string(backend),
        branch: branch,
        target: target,
        effects: [%{action: merge_action(backend), branch: branch, target: target}],
        adapter: adapter_details(backend)
      }
      |> put_if(:project_id, value(input, :project_id))

      dispatch_legacy("vcs.merge.request", payload)
    end
  end

  @spec adapters() :: [map()]
  def adapters do
    [adapter_details(:git), adapter_details(:jujutsu)]
  end

  @spec classify_error(term()) :: %{kind: String.t(), transient?: boolean(), code: integer() | nil}
  def classify_error(reason) do
    case reason do
      {:http_status, status, _body} when status in [401, 403, 404] ->
        %{kind: "http_status", transient?: false, code: status}

      {:http_status, status, _body} when status == 408 or status == 425 or status == 429 ->
        %{kind: "http_status", transient?: true, code: status}

      {:http_status, status, _body} when status >= 500 and status <= 599 ->
        %{kind: "http_status", transient?: true, code: status}

      {:transport, reason} when reason in [:timeout, :closed, :connect_timeout, :econnrefused, :nxdomain] ->
        %{kind: "transport", transient?: true, code: nil}

      {:transport, {:failed_connect, _details}} ->
        %{kind: "transport", transient?: true, code: nil}

      {:transport, {:tls_alert, _details}} ->
        %{kind: "transport", transient?: true, code: nil}

      :timeout ->
        %{kind: "timeout", transient?: true, code: nil}

      {:auth_rejected, _} ->
        %{kind: "auth_rejected", transient?: false, code: nil}

      {:not_found, _} ->
        %{kind: "not_found", transient?: false, code: nil}

      :invalid_repo_format ->
        %{kind: "invalid_repo_format", transient?: false, code: nil}
      {:unsupported_vcs_backend, _} ->
        %{kind: "unsupported_backend", transient?: false, code: nil}

      _ ->
        %{kind: "unknown", transient?: false, code: nil}
    end
  end

  defp execute(operation, input, opts) do
    impl = impl(opts)
    retries = Keyword.get(opts, :retries, @default_retries)
    base_backoff_ms = Keyword.get(opts, :base_backoff_ms, @default_base_backoff_ms)
    sleep_fn = Keyword.get(opts, :sleep_fn, &:timer.sleep/1)

    with {:ok, payload} <- build_payload(operation, input, impl, retries),
         {:ok, _started} <- dispatch_operation_event("vcs.operation.start", payload) do
      operation_input = Map.merge(input, payload)

      case invoke_with_retry(operation, impl, operation_input, opts, retries, base_backoff_ms, sleep_fn, 1) do
        {:ok, result, attempt} ->
          completed_payload =
            payload
            |> Map.put(:status, "completed")
            |> Map.put(:attempt, attempt)
            |> Map.put(:max_attempts, retries + 1)
            |> Map.put(:result, result)

          with {:ok, response} <- dispatch_operation_event("vcs.operation.complete", completed_payload) do
            {:ok, Map.put(response, :result, result)}
          end

        {:error, reason, attempt, classification} ->
          failed_payload =
            payload
            |> Map.put(:status, "failed")
            |> Map.put(:attempt, attempt)
            |> Map.put(:max_attempts, retries + 1)
            |> Map.put(:retryable, classification.transient?)
            |> Map.put(:error, encode_error(reason, classification))

          with {:ok, _response} <- dispatch_operation_event("vcs.operation.fail", failed_payload) do
            {:error, reason}
          end
      end
    end
  end

  defp invoke_with_retry(operation, impl, input, opts, retries, base_backoff_ms, sleep_fn, attempt) do
    result =
      impl
      |> apply(operation, [input, opts])
      |> normalize_result(Map.fetch!(input, :operation_id))

    case result do
      {:ok, payload} ->
        {:ok, payload, attempt}

      {:error, reason} ->
        classification = classify_error(reason)

        if classification.transient? and attempt <= retries do
          sleep_fn.(backoff_ms(base_backoff_ms, attempt))
          invoke_with_retry(operation, impl, input, opts, retries, base_backoff_ms, sleep_fn, attempt + 1)
        else
          {:error, reason, attempt, classification}
        end
    end
  end

  defp build_payload(operation, input, impl, retries) do
    operation_id = value(input, :operation_id, default_operation_id(operation))

    with {:ok, operation_id} <- required_binary(operation_id, :operation_id),
         {:ok, operation_payload} <- operation_payload(operation, input) do
      {:ok,
       operation_payload
       |> Map.put(:operation_id, operation_id)
       |> Map.put(:operation, Atom.to_string(operation))
       |> Map.put(:status, "started")
       |> Map.put(:attempt, 1)
       |> Map.put(:max_attempts, retries + 1)
       |> Map.put(:adapter, adapter_name(impl))}
    end
  end

  defp operation_payload(:clone, input) do
    with {:ok, repo} <- required_binary(value(input, :repo), :repo),
         {:ok, path} <- required_binary(value(input, :path), :path) do
      {:ok,
       %{}
       |> Map.put(:repo, repo)
       |> Map.put(:path, path)
       |> put_if(:base_ref, value(input, :base_ref))
       |> put_if(:project_id, value(input, :project_id))
       |> put_if(:run_id, value(input, :run_id))}
    end
  end

  defp operation_payload(:branch, input) do
    with {:ok, repo} <- required_binary(value(input, :repo), :repo),
         {:ok, branch} <- required_binary(value(input, :branch), :branch),
         {:ok, base_ref} <- required_binary(value(input, :base_ref, "main"), :base_ref) do
      {:ok,
       %{}
       |> Map.put(:repo, repo)
       |> Map.put(:branch, branch)
       |> Map.put(:base_ref, base_ref)
       |> put_if(:project_id, value(input, :project_id))
       |> put_if(:run_id, value(input, :run_id))}
    end
  end

  defp operation_payload(:create_pr, input) do
    with {:ok, repo} <- required_binary(value(input, :repo), :repo),
         {:ok, branch} <- required_binary(value(input, :branch), :branch),
         {:ok, base_branch} <- required_binary(value(input, :base_branch, "main"), :base_branch),
         {:ok, title} <- required_binary(value(input, :title), :title) do
      {:ok,
       %{}
       |> Map.put(:repo, repo)
       |> Map.put(:branch, branch)
       |> Map.put(:base_branch, base_branch)
       |> Map.put(:title, title)
       |> put_if(:body, value(input, :body))
       |> put_if(:project_id, value(input, :project_id))
       |> put_if(:run_id, value(input, :run_id))}
    end
  end

  defp dispatch_operation_event(command_type, payload) do
    dispatch(command_type, payload)
  end

  defp dispatch_legacy(command_type, payload) do
    with {:ok, response} <- dispatch(command_type, payload) do
      {:ok, Map.put(response, :result, payload)}
    end
  end

  defp dispatch(command_type, payload) do
    command_id = "#{Map.fetch!(payload, :operation_id)}:#{String.replace(command_type, ".", "-")}"

    CommandRouter.handle(%{
      command_id: command_id,
      command_type: command_type,
      payload: payload,
      metadata: %{
        correlation_id: Map.fetch!(payload, :operation_id),
        idempotency_key: command_id,
        source: "vcs-adapter"
      }
    })
  end

  defp normalize_result({:ok, result}, operation_id) when is_map(result) do
    {:ok, Map.put_new(result, :operation_id, operation_id)}
  end

  defp normalize_result({:ok, result}, operation_id) do
    {:ok, %{operation_id: operation_id, value: normalize_value(result)}}
  end

  defp normalize_result({:error, reason}, _operation_id), do: {:error, reason}
  defp normalize_result(other, _operation_id), do: {:error, {:invalid_vcs_result, other}}

  defp encode_error(reason, classification) do
    %{
      kind: classification.kind,
      transient: classification.transient?,
      code: classification.code,
      message: inspect(reason),
      details: normalize_value(reason)
    }
  end

  defp backoff_ms(base_backoff_ms, attempt), do: base_backoff_ms * :math.pow(2, attempt - 1) |> round()

  defp default_operation_id(operation) do
    "#{Atom.to_string(operation)}-#{System.unique_integer([:positive])}"
  end

  defp impl(opts) do
    Keyword.get(opts, :impl, Application.get_env(:foreman_server, :vcs_adapter_impl, @default_impl))
  end

  defp adapter_name(@default_impl), do: "github"
  defp adapter_name(impl) when is_atom(impl), do: inspect(impl)

  defp observe_stale(worktree_path) do
    if File.exists?(worktree_path),
      do: %{exists: true, path: worktree_path},
      else: %{exists: false}
  end

  defp stale_effects(%{exists: false}, _policy, _backend), do: [%{action: "create_worktree"}]

  defp stale_effects(%{exists: true, path: path}, "clean", _backend),
    do: [%{action: "remove_stale_worktree", path: path}, %{action: "create_worktree"}]

  defp stale_effects(%{exists: true, path: path}, "rebase", backend),
    do: [%{action: "reuse_worktree", path: path}, %{action: rebase_action(backend)}]

  defp stale_effects(%{exists: true, path: path}, _policy, _backend),
    do: [%{action: "reuse_worktree", path: path}]

  defp backend(:git), do: {:ok, :git}
  defp backend(:jujutsu), do: {:ok, :jujutsu}
  defp backend("git"), do: {:ok, :git}
  defp backend("jujutsu"), do: {:ok, :jujutsu}
  defp backend("jj"), do: {:ok, :jujutsu}
  defp backend(value), do: {:error, {:unsupported_vcs_backend, value}}

  defp adapter_details(:git),
    do: %{
      backend: "git",
      commands: %{worktree: "git worktree", rebase: "git rebase", merge: "git merge"}
    }

  defp adapter_details(:jujutsu),
    do: %{
      backend: "jujutsu",
      commands: %{worktree: "jj workspace", rebase: "jj rebase", merge: "jj git push"}
    }

  defp rebase_action(:git), do: "git_rebase"
  defp rebase_action(:jujutsu), do: "jj_rebase"
  defp merge_action(:git), do: "git_merge"
  defp merge_action(:jujutsu), do: "jj_bookmark_merge"

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp value(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp normalize_value(value) when is_struct(value), do: value |> Map.from_struct() |> normalize_value()
  defp normalize_value(value) when is_map(value), do: Map.new(value, fn {key, nested} -> {normalize_key(key), normalize_value(nested)} end)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&normalize_value/1)
  defp normalize_value(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key
end
