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

  defp handle_observation(context, %{state: :merged} = observation, command_handler) do
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

  defp handle_observation(context, %{state: :closed} = observation, command_handler) do
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

  defp handle_observation(context, %{state: :draft} = observation, command_handler) do
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

  defp handle_observation(context, %{state: :open} = observation, command_handler) do
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

  defp handle_observation(_context, _observation, _command_handler), do: empty_summary()

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

  defp normalize_observation(observation) do
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
