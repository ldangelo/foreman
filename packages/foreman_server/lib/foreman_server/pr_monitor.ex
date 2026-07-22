defmodule ForemanServer.PrMonitor do
  @moduledoc "Periodically reconciles recorded pull request state from GitHub."

  use GenServer

  alias ForemanServer.ProjectionStore

  @default_interval_ms 60_000
  @terminal_pr_states MapSet.new(["merged", "closed"])

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec tick_once() :: {:ok, map()}
  def tick_once do
    run_once(monitor_config([]))
  end

  @spec state() :: map()
  def state, do: GenServer.call(__MODULE__, :state)

  @impl true
  def init(opts) do
    config = monitor_config(opts)

    state = %{
      enabled: config.enabled,
      interval_ms: config.interval_ms,
      checker: config.checker,
      command_handler: config.command_handler,
      last_tick: nil,
      errors: 0
    }

    if config.enabled, do: schedule_tick(config.interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info(:tick, %{enabled: true, interval_ms: interval_ms} = state) do
    {:ok, summary} = run_once(state)
    schedule_tick(interval_ms)

    {:noreply, %{state | last_tick: summary, errors: state.errors + summary.errors}}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  defp run_once(config) do
    snapshot = ProjectionStore.snapshot()

    summary =
      snapshot.runs
      |> Map.values()
      |> Enum.filter(&monitorable_run?/1)
      |> Enum.reduce(empty_summary(), fn run, summary ->
        case monitor_run(run, snapshot, config) do
          {:ok, result} -> merge_result(summary, result)
          {:error, _reason} -> Map.update!(summary, :errors, &(&1 + 1))
        end
      end)

    {:ok, summary}
  end

  defp monitorable_run?(run) do
    pr_url = Map.get(run, :pr_url)
    pr_state = Map.get(run, :pr_state)

    is_binary(pr_url) and pr_url != "" and not MapSet.member?(@terminal_pr_states, pr_state)
  end

  defp monitor_run(run, snapshot, config) do
    with {:ok, context} <- run_context(run, snapshot),
         {:ok, observation} <- call_checker(config.checker, context.project_path, context.pr_url) do
      observation = normalize_observation(observation)
      result = handle_observation(context, observation, config.command_handler)
      {:ok, Map.update!(result, :checked, &(&1 + 1))}
    end
  end

  defp run_context(run, snapshot) do
    task_id = Map.get(run, :task_id)
    task = Map.get(snapshot.tasks, task_id, %{})
    project_id = Map.get(run, :project_id) || Map.get(task, :project_id)
    project = Map.get(snapshot.projects, project_id, %{})

    context = %{
      run_id: Map.get(run, :run_id),
      task_id: task_id,
      project_id: project_id,
      project_path: Map.get(project, :path),
      pr_url: Map.get(run, :pr_url),
      pr_state: Map.get(run, :pr_state),
      branch_name: Map.get(run, :branch_name),
      phase: Map.get(run, :current_phase) || "pr-monitor"
    }

    required = [:run_id, :task_id, :project_id, :project_path, :pr_url]

    if Enum.all?(required, &present?(Map.get(context, &1))) do
      {:ok, context}
    else
      {:error, :missing_context}
    end
  end

  # Made public so GhWebhookHandler (submodule) can reuse these functions.
  def handle_observation(context, %{state: :merged} = observation, command_handler) do
    payload =
      context
      |> common_payload(observation)
      |> maybe_put(:merged_at, Map.get(observation, :merged_at))
      |> maybe_put(:merge_commit_sha, Map.get(observation, :merge_commit_sha))
      |> maybe_put(:head_sha, Map.get(observation, :head_ref_oid))
      |> maybe_put(:base_branch, Map.get(observation, :base_ref_name))

    with {:ok, _} <- handle_command(command_handler, "run.pr.merge", payload),
         {:ok, _} <-
           handle_command(command_handler, "task.update", %{
             task_id: context.task_id,
             status: "merged"
           }) do
      %{empty_summary() | merged: 1}
    else
      {:error, _reason} -> %{empty_summary() | errors: 1}
    end
  end

  def handle_observation(context, %{state: :closed} = observation, command_handler) do
    if context.pr_state == "closed" do
      %{empty_summary() | closed: 1}
    else
      payload =
        context
        |> common_payload(observation)
        |> Map.put(:action, "closed")
        |> Map.put(:reason, "GitHub reports PR closed without merge")

      with {:ok, _} <- handle_command(command_handler, "run.pr.reset", payload),
           {:ok, _} <-
             handle_command(command_handler, "task.close", %{
               task_id: context.task_id,
               project_id: context.project_id
             }) do
        %{empty_summary() | closed: 1}
      else
        {:error, _reason} -> %{empty_summary() | errors: 1}
      end
    end
  end

  def handle_observation(context, %{state: :draft} = observation, command_handler) do
    if context.pr_state == "draft" do
      empty_summary()
    else
      payload =
        context
        |> common_payload(observation)
        |> Map.put(:pr_state, "draft")
        |> Map.put(:phase, context.phase)
        |> maybe_put(:head_sha, Map.get(observation, :head_ref_oid))
        |> maybe_put(:base_branch, Map.get(observation, :base_ref_name))

      update_pr(command_handler, "run.pr.update", payload)
    end
  end

  def handle_observation(context, %{state: :open} = observation, command_handler) do
    if context.pr_state == "open" do
      empty_summary()
    else
      payload =
        context
        |> common_payload(observation)
        |> maybe_put(:head_sha, Map.get(observation, :head_ref_oid))
        |> maybe_put(:base_branch, Map.get(observation, :base_ref_name))

      update_pr(command_handler, "run.pr.ready", payload)
    end
  end

  def handle_observation(_context, _observation, _command_handler), do: empty_summary()

  defp update_pr(command_handler, command_type, payload) do
    required = [:branch_name, :head_sha, :base_branch]

    if Enum.all?(required, &present?(Map.get(payload, &1))) do
      case handle_command(command_handler, command_type, payload) do
        {:ok, _} -> %{empty_summary() | updated: 1}
        {:error, _reason} -> %{empty_summary() | errors: 1}
      end
    else
      %{empty_summary() | skipped: 1}
    end
  end

  defp common_payload(context, observation) do
    %{
      run_id: context.run_id,
      project_id: context.project_id,
      task_id: context.task_id,
      pr_url: Map.get(observation, :url) || context.pr_url,
      branch_name: Map.get(observation, :head_ref_name) || context.branch_name
    }
  end

  defp call_checker(checker, project_path, pr_url) do
    cond do
      function_exported?(checker, :observe_pr, 2) -> checker.observe_pr(project_path, pr_url)
      function_exported?(checker, :check_pr, 2) -> checker.check_pr(project_path, pr_url)
      function_exported?(checker, :check, 2) -> checker.check(project_path, pr_url)
      true -> {:error, {:invalid_checker, checker}}
    end
  rescue
    error -> {:error, error}
  end

  defp handle_command(command_handler, command_type, payload) do
    command = %{command_type: command_type, payload: payload}

    cond do
      function_exported?(command_handler, :handle, 1) ->
        command_handler.handle(command)

      function_exported?(command_handler, :handle_command, 1) ->
        command_handler.handle_command(command)

      true ->
        {:error, {:invalid_command_handler, command_handler}}
    end
  rescue
    error -> {:error, error}
  end

  # Made public so GhWebhookHandler (submodule) can reuse this function.
  def normalize_observation(observation) do
    %{
      state: normalize_state(get_field(observation, :state), get_field(observation, :is_draft)),
      url: get_field(observation, :url),
      merged_at: get_field(observation, :merged_at),
      merge_commit_sha:
        get_field(observation, :merge_commit_sha) || merge_commit_sha(observation),
      head_ref_oid: get_field(observation, :head_ref_oid),
      base_ref_name: get_field(observation, :base_ref_name),
      head_ref_name: get_field(observation, :head_ref_name)
    }
  end

  defp normalize_state(:merged, _is_draft), do: :merged
  defp normalize_state(:closed, _is_draft), do: :closed
  defp normalize_state(:draft, _is_draft), do: :draft
  defp normalize_state(:open, true), do: :draft
  defp normalize_state(:open, _is_draft), do: :open
  defp normalize_state("MERGED", _is_draft), do: :merged
  defp normalize_state("CLOSED", _is_draft), do: :closed
  defp normalize_state("OPEN", true), do: :draft
  defp normalize_state("OPEN", _is_draft), do: :open
  defp normalize_state("merged", _is_draft), do: :merged
  defp normalize_state("closed", _is_draft), do: :closed
  defp normalize_state("draft", _is_draft), do: :draft
  defp normalize_state("open", true), do: :draft
  defp normalize_state("open", _is_draft), do: :open
  defp normalize_state(state, _is_draft), do: state

  defp merge_commit_sha(observation) do
    case get_field(observation, :merge_commit) do
      %{} = commit -> get_field(commit, :oid)
      _ -> nil
    end
  end

  defp get_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || Map.get(map, camelize(key))
  end

  defp get_field(_map, _key), do: nil

  defp camelize(key) do
    key
    |> Atom.to_string()
    |> String.split("_")
    |> then(fn [first | rest] -> first <> Enum.map_join(rest, &String.capitalize/1) end)
  end

  defp merge_result(summary, result) do
    Map.merge(summary, result, fn _key, left, right -> left + right end)
  end

  defp empty_summary do
    %{checked: 0, merged: 0, closed: 0, updated: 0, skipped: 0, errors: 0}
  end

  defp monitor_config(opts) do
    env = Application.get_env(:foreman_server, :pr_monitor, [])

    %{
      enabled: Keyword.get(opts, :enabled, Keyword.get(env, :enabled, true)),
      interval_ms:
        Keyword.get(opts, :interval_ms, Keyword.get(env, :interval_ms, @default_interval_ms)),
      checker:
        Keyword.get(opts, :checker, Keyword.get(env, :checker, ForemanServer.PrMonitor.GhChecker)),
      command_handler:
        Keyword.get(
          opts,
          :command_handler,
          Keyword.get(env, :command_handler, ForemanServer.PrMonitor.CommandHandler)
        )
    }
  end

  defp schedule_tick(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp present?(value), do: is_binary(value) and value != ""
end

defmodule ForemanServer.PrMonitor.GhChecker do
  @moduledoc false

  @spec observe_pr(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def observe_pr(project_path, pr_url) do
    args = [
      "pr",
      "view",
      pr_url,
      "--json",
      "state,mergedAt,url,headRefOid,baseRefName,headRefName,isDraft,mergeCommit",
      "--jq",
      "."
    ]

    case System.cmd("gh", args, cd: project_path, stderr_to_stdout: true) do
      {output, 0} -> Jason.decode(output)
      {output, status} -> {:error, {:gh_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, error}
  end
end

defmodule ForemanServer.PrMonitor.CommandHandler do
  @moduledoc false

  alias ForemanServer.CommandRouter

  @spec handle(map()) :: {:ok, map()} | {:error, term()}
  def handle(%{command_type: command_type, payload: payload}) do
    run_id = Map.get(payload, :run_id) || Map.get(payload, :task_id) || "unknown"

    CommandRouter.handle(%{
      command_id: command_id(command_type, run_id),
      command_type: command_type,
      payload: payload
    })
  end

  defp command_id(command_type, run_id) do
    unique = System.unique_integer([:positive])
    "pr-monitor:#{command_type}:#{run_id}:#{unique}"
  end
end

defmodule ForemanServer.PrMonitor.GhWebhookHandler do
  @moduledoc """
  Handles GitHub webhook `pull_request` events in real time.

  Reuses `GhChecker.observe_pr/2` result normalization and `CommandHandler.handle/1`
  command dispatch — the webhook path differs only in how the observation is obtained
  (payload parsing vs. `gh` CLI call) and how the matching run is found (snapshot scan
  by `pr_url` or `branch_name`).

  Duplicate deliveries are idempotent via `X-GitHub-Delivery` header dedupe in the
  existing `integration_dedupe` projection.
  """

  alias ForemanServer.ProjectionStore

  @spec handle(map()) :: {:ok, map()} | {:error, term()}
  @doc """
  Process a GitHub `pull_request` webhook payload.

  ## Payload shape
  Expected keys:
  - `action` (string) — e.g. "opened", "closed", "synchronize", "ready_for_review"
  - `pull_request` (map) — GitHub PR object
  - `repository` (map) — GitHub repository object
  - `delivery_id` (string) — `X-GitHub-Delivery` header value (for dedupe)

  ## Returns
  - `{:ok, %{commands_issued: non_neg_integer()}}` on success
  - `{:error, :duplicate}` if this delivery was already processed
  - `{:error, :no_matching_run}` if no run matches the PR URL or branch
  - `{:error, reason}` on other failures
  """
  def handle(payload) do
    with {:ok, %{pr_url: pr_url, branch_name: branch_name, action: action, pr_payload: pr_payload, merged: merged, is_draft: is_draft}} <- parse_payload(payload),
         {:ok, dedupe_key} <- dedupe_key(payload),
         :ok <- check_dedupe(dedupe_key),
         {:ok, context} <- find_matching_context(pr_url, branch_name) do
      # Normalize observation from the webhook payload, mirroring GhChecker.observe_pr/2 output
      observation = normalize_webhook_observation(pr_payload, action, merged, is_draft)
      # Call parent PrMonitor module functions by their full module path.
      observation = ForemanServer.PrMonitor.normalize_observation(observation)

      result =
        ForemanServer.PrMonitor.handle_observation(
          context,
          observation,
          ForemanServer.PrMonitor.CommandHandler
        )

      record_dedupe(dedupe_key, context.task_id)

      {:ok, %{commands_issued: result_issued_count(result)}}
    end
  end

  @doc "Verify an HMAC-SHA256 signature from GitHub's X-Hub-Signature-256 header."
  @spec verify_signature(String.t(), String.t(), String.t()) :: boolean()
  def verify_signature(body, signature_header, secret) do
    expected = "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))
    safe_string_compare(expected, signature_header)
  end

  @doc "Build the HMAC signature for a given body and secret (useful in tests)."
  @spec build_signature(String.t(), String.t()) :: String.t()
  def build_signature(body, secret) do
    "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))
  end

  # Parse the webhook payload into a normalized structure.
  defp parse_payload(payload) when is_map(payload) do
    with {:ok, pr_url} <- extract_pr_url(payload),
         {:ok, branch_name} <- extract_branch_name(payload),
         {:ok, action} <- extract_action(payload),
         {:ok, pr_payload} <- extract_pr(payload),
         {:ok, merged} <- extract_merged(pr_payload),
         {:ok, is_draft} <- extract_is_draft(pr_payload) do
      {:ok, %{pr_url: pr_url, branch_name: branch_name, action: action, pr_payload: pr_payload, merged: merged, is_draft: is_draft}}
    end
  end

  defp parse_payload(_payload), do: {:error, :invalid_payload}

  defp extract_pr_url(payload) do
    url = get_field(payload, ["pull_request", "html_url"]) || get_field(payload, ["pull_request", "url"])
    if is_binary(url) and url != "", do: {:ok, url}, else: {:error, :missing_pr_url}
  end

  defp extract_branch_name(payload) do
    head = get_field(payload, ["pull_request", "head"])
    branch = get_field(head, "ref") || get_field(payload, ["pull_request", "head_ref"])
    if is_binary(branch) and branch != "", do: {:ok, branch}, else: {:error, :missing_branch_name}
  end

  defp extract_action(payload) do
    action = get_field(payload, "action")
    if is_binary(action) and action != "", do: {:ok, action}, else: {:error, :missing_action}
  end

  defp extract_pr(payload) do
    pr = get_field(payload, "pull_request")
    if is_map(pr), do: {:ok, pr}, else: {:error, :missing_pull_request}
  end

  defp extract_merged(pr) do
    merged = get_field(pr, "merged")
    {:ok, merged == true}
  end

  defp extract_is_draft(pr) do
    draft = get_field(pr, "draft") || get_field(pr, "is_draft")
    {:ok, draft == true}
  end

  # Build dedupe key from X-GitHub-Delivery header / payload delivery_id
  defp dedupe_key(%{"delivery_id" => id}) when is_binary(id) and id != "",
    do: {:ok, "github:webhook:#{id}"}

  defp dedupe_key(%{"delivery" => id}) when is_binary(id) and id != "",
    do: {:ok, "github:webhook:#{id}"}

  defp dedupe_key(_payload), do: {:error, :missing_delivery_id}

  # Check dedupe in the integration_dedupe projection
  defp check_dedupe(dedupe_key) do
    snapshot = ProjectionStore.snapshot()
    case get_in(snapshot, [:integration_dedupe, dedupe_key]) do
      nil -> :ok
      _existing -> {:error, :duplicate}
    end
  end

  # Record dedupe entry after successful processing
  defp record_dedupe(dedupe_key, task_id) do
    # Write a lightweight dedupe event so the projection catches it.
    # We append to an integration stream; the integration_dedupe projection
    # will record the dedupe_key -> task_id mapping idempotently.
    snapshot = ProjectionStore.snapshot()
    existing = get_in(snapshot, [:integration_dedupe, dedupe_key])

    unless existing do
      # Emit IntegrationCommandIngested so the projection stores the dedupe key.
      # This mirrors the pattern in IntegrationIngestion but scoped to webhook events.
      :ok = try_record_dedupe_event(dedupe_key, task_id)
    end
  end

  defp try_record_dedupe_event(dedupe_key, task_id) do
    alias ForemanServer.EventStore

    EventStore.append(%{
      stream_id: "integration:#{dedupe_key}",
      event_type: "IntegrationCommandIngested",
      payload: %{
        source: "github",
        external_id: dedupe_key,
        project_id: nil,
        event_type: "pull_request",
        occurred_at: DateTime.utc_now(),
        payload: %{},
        idempotency_key: dedupe_key,
        dedupe_key: dedupe_key,
        external_link: nil,
        task_id: task_id,
        command_type: "webhook"
      },
      metadata: %{
        source: "gh-webhook-handler",
        correlation_id: dedupe_key,
        idempotency_key: dedupe_key
      }
    })
  rescue
    _error ->
      # If event store append fails (e.g. no event log), skip dedupe recording.
      # The handler already returned success to GitHub; GitHub will not retry.
      :ok
  end

  # Find the run context matching this PR by pr_url or branch_name.
  defp find_matching_context(pr_url, branch_name) do
    snapshot = ProjectionStore.snapshot()

    # Try pr_url first, then branch_name
    context =
      find_run_by_pr_url(snapshot, pr_url) ||
        find_run_by_branch(snapshot, branch_name)

    case context do
      %{run_id: run_id, task_id: task_id, project_id: _project_id, branch_name: _bn, pr_url: _pu} = ctx
      when is_binary(run_id) and is_binary(task_id) ->
        {:ok, %{ctx | phase: "webhook"}}

      _ ->
        {:error, :no_matching_run}
    end
  end

  defp find_run_by_pr_url(snapshot, pr_url) do
    snapshot.runs
    |> Map.values()
    |> Enum.find_value(fn run ->
      run_pr_url = Map.get(run, :pr_url)
      if run_pr_url != nil and run_pr_url != "" and run_pr_url == pr_url do
        build_context(snapshot, run)
      end
    end)
  end

  defp find_run_by_branch(snapshot, branch_name) do
    snapshot.runs
    |> Map.values()
    |> Enum.find_value(fn run ->
      run_branch = Map.get(run, :branch_name) || Map.get(run, :branch)
      if run_branch != nil and run_branch != "" and run_branch == branch_name do
        build_context(snapshot, run)
      end
    end)
  end

  defp build_context(snapshot, run) do
    run_id = Map.get(run, :run_id)
    task_id = Map.get(run, :task_id) || Map.get(run, :task_id)
    task = Map.get(snapshot.tasks, task_id, %{})
    project_id = Map.get(run, :project_id) || Map.get(task, :project_id)
    project = Map.get(snapshot.projects, project_id, %{})

    %{
      run_id: run_id,
      task_id: task_id,
      project_id: project_id,
      project_path: Map.get(project, :path),
      pr_url: Map.get(run, :pr_url),
      pr_state: Map.get(run, :pr_state),
      branch_name: Map.get(run, :branch_name) || Map.get(run, :branch),
      phase: Map.get(run, :current_phase) || "pr-monitor"
    }
  end

  # Convert webhook payload to the same normalized shape that GhChecker.observe_pr/2 returns.
  defp normalize_webhook_observation(pr_payload, action, merged, is_draft) do
    %{
      state: state_from_webhook(action, merged, is_draft),
      url: get_field(pr_payload, "html_url") || get_field(pr_payload, "url"),
      merged_at: get_field(pr_payload, "merged_at"),
      merge_commit_sha: merge_commit_sha(pr_payload),
      head_ref_oid: get_field(pr_payload, ["head", "sha"]) || get_field(pr_payload, "head_sha"),
      head_ref_name: get_field(pr_payload, ["head", "ref"]) || get_field(pr_payload, "head_ref"),
      base_ref_name: get_field(pr_payload, ["base", "ref"]) || get_field(pr_payload, "base_ref")
    }
  end

  defp state_from_webhook("closed", true, _is_draft), do: :merged
  defp state_from_webhook("closed", false, _is_draft), do: :closed
  defp state_from_webhook(_action, _merged, true), do: :draft
  defp state_from_webhook("opened", _merged, _is_draft), do: :open
  defp state_from_webhook("synchronize", _merged, _is_draft), do: :open
  defp state_from_webhook("ready_for_review", _merged, _is_draft), do: :open
  defp state_from_webhook("converted_to_draft", _merged, _is_draft), do: :draft
  defp state_from_webhook(_action, _merged, _is_draft), do: :open

  defp merge_commit_sha(pr_payload) do
    case get_field(pr_payload, "merge_commit") do
      %{} = commit -> get_field(commit, "oid") || get_field(commit, "sha")
      _ -> get_field(pr_payload, "merge_commit_sha")
    end
  end

  defp get_field(map, keys) when is_list(keys) do
    Enum.reduce(keys, map, fn key, acc -> get_single_field(acc, key) end)
  end

  defp get_field(map, key) do
    get_single_field(map, key)
  end

  defp get_single_field(nil, _key), do: nil
  defp get_single_field(%{} = map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
  defp get_single_field(_not_map, _key), do: nil

  defp result_issued_count(%{merged: n}) when n > 0, do: 2
  defp result_issued_count(%{closed: n}) when n > 0, do: 2
  defp result_issued_count(%{updated: n}) when n > 0, do: 1
  defp result_issued_count(%{skipped: n}) when n > 0, do: 0
  defp result_issued_count(%{errors: n}) when n > 0, do: 0
  defp result_issued_count(_), do: 0

  # Constant-time string comparison to avoid timing attacks on HMAC verification.
  if function_exported?(:crypto, :strong_rand_bytes, 1) do
    defp safe_string_compare(a, b) when byte_size(a) == byte_size(b) do
      a_byte = :binary.bin_to_list(a)
      b_byte = :binary.bin_to_list(b)
      0 == Enum.sum(Enum.zip_with(a_byte, b_byte, fn x, y -> if x == y, do: 0, else: 1 end))
    end
    defp safe_string_compare(_a, _b), do: false
  else
    defp safe_string_compare(a, b), do: a == b
  end
end
