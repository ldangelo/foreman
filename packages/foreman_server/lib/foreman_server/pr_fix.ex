defmodule ForemanServer.PrFix do
  @moduledoc """
  Plans a PR fix thread (E9-S3): from the run, its watched PR and the requested kind
  (`ci | comments | conflicts`) it builds the options of the follow-up jobsite and its
  prompt. Pure planning plus read-only reads (`ProjectionStore`, `git worktree list`,
  `gh`): nothing here starts a process - `ForemanServer.PrWatcher` does that.

  The jobsite attaches to the PR's head branch at its tip on `origin`
  (`strategy: {:branch, head}`, `sync_remote: "origin"`), runs with `push: true`
  (publishing exactly that branch to `origin`), carries the originating bead id, and
  uses the agent the run used:

    * provider and model: the run's last persisted provider session
      (`WorkerSessionBound`, E0-S1), else `config :foreman_server, :pr_fix, agent:`;
      the model falls back to the project's `thread_model` (via `Jobsite.Spec`);
    * `resume_session`: that session's id, only when the fix will run at the SAME
      working-directory path as the original run (provider sessions are cwd-bound; spike
      E9-SP2 proved pi refuses to resume from another directory). The original worktree is
      gone after cleanup, so the jobsite recreates it at that path (`path:`). When the path
      is taken by something else, or no session id was persisted, no session is resumed and
      the prompt carries the context instead - `resumed_session: false`.

  Typed errors: `{:pr_not_watched, url}`, `{:pr_not_open, status}`, `:branch_unknown`,
  `{:branch_unsafe, name}`, `{:project_unresolved, id}`, `{:fetch_failed, reason}`,
  and whatever `Jobsite.Spec.from_json/2` rejects (`%Jobsite.Error{}`).
  """

  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.Jobsite.{Error, Git, Spec}
  alias ForemanServer.Overwatch.WorkerLogPolicy
  alias ForemanServer.PrFix.Prompt
  alias ForemanServer.ProjectionStore

  @type kind :: String.t()
  @type plan :: %{
          jobsite_opts: keyword(),
          prompt: String.t(),
          resumed_session: boolean(),
          head_branch: String.t()
        }

  @branch_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/
  @templates %{
    "ci" => :fix_ci,
    "comments" => :address_comments,
    "conflicts" => :resolve_conflicts
  }
  @max_body 2_000
  @max_data_bytes 60_000

  @doc """
  Plan the fix of `kind` for `pr_url` on `run_id`.

  Options (test seams): `:fetch_fun` (`pr_url -> {:ok, PrStatus.t()} | {:error, term()}`,
  default reads checks, reviews, comments and threads), `:log_fetcher`
  (`(pr_url, PrStatus.check() -> {:ok, String.t()} | {:error, term()})`, default
  `gh run view --log-failed`), `:note` (operator guidance, trusted).
  """
  @spec plan(kind(), String.t(), String.t(), keyword()) :: {:ok, plan()} | {:error, term()}
  def plan(kind, run_id, pr_url, opts \\ []) when kind in ["ci", "comments", "conflicts"] do
    with {:ok, run} <- fetch(ProjectionStore.run(run_id), {:run_not_found, run_id}),
         {:ok, record} <- watched_record(run_id, pr_url),
         {:ok, head} <- head_branch(record),
         {:ok, base} <- safe_branch(record.base_branch),
         {:ok, project} <- project(run),
         {:ok, repo_path} <- repo_path(run, project, record),
         {:ok, status} <- read_pr(pr_url, opts),
         worktree = original_worktree(run_id, record, head),
         {:ok, attach} <- attach(repo_path, head, worktree),
         agent = agent(run, attach.resume?),
         prompt = render(kind, record, status, head, base, pr_url, opts),
         {:ok, spec_opts} <- spec_opts(run, repo_path, head, prompt, agent, attach, kind) do
      {:ok,
       %{
         jobsite_opts: spec_opts,
         prompt: prompt,
         resumed_session: attach.resume? and not is_nil(agent.session_id),
         head_branch: head
       }}
    end
  end

  # -- inputs --------------------------------------------------------------

  defp fetch(nil, error), do: {:error, error}
  defp fetch(value, _error), do: {:ok, value}

  defp watched_record(run_id, pr_url) do
    case Enum.find(ProjectionStore.pr_watch(run_id), &(&1.pr_url == pr_url)) do
      nil -> {:error, {:pr_not_watched, pr_url}}
      %{watching: false} -> {:error, {:pr_not_watched, pr_url}}
      %{status: status} = record when status in ["open", "conflicted"] -> {:ok, record}
      %{status: status} -> {:error, {:pr_not_open, status}}
    end
  end

  defp head_branch(%{branch_name: name}) when is_binary(name) and name != "",
    do: safe_branch(name)

  defp head_branch(_record), do: {:error, :branch_unknown}

  defp safe_branch(name) when is_binary(name) do
    if Regex.match?(@branch_pattern, name) and not String.contains?(name, "..") do
      {:ok, name}
    else
      {:error, {:branch_unsafe, name}}
    end
  end

  defp safe_branch(_name), do: {:error, :branch_unknown}

  defp project(%{project_id: project_id}) do
    case ProjectionStore.project_projection(project_id) do
      %{path: path} = project when is_binary(path) and path != "" -> {:ok, project}
      _ -> {:error, {:project_unresolved, project_id}}
    end
  end

  # The repository the PR was opened in (E12): a record without `repo_id` is the
  # run's primary, i.e. the project's own path; a non-primary PR's fix runs against
  # THAT repository's checkout, never the primary's.
  defp repo_path(run, _project, %{repo_id: repo_id}) when is_binary(repo_id) and repo_id != "" do
    case ProjectionStore.project_repository(run.project_id, repo_id) do
      %{path: path} when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, {:repo_unresolved, repo_id}}
    end
  end

  defp repo_path(_run, project, _record), do: {:ok, project.path}

  defp read_pr(pr_url, opts) do
    fetch = Keyword.get(opts, :fetch_fun, &PrStatus.fetch(&1, threads: true))

    case fetch.(pr_url) do
      {:ok, %PrStatus{status: state} = status} when state in [:open, :conflicted] -> {:ok, status}
      {:ok, %PrStatus{status: state}} -> {:error, {:pr_not_open, Atom.to_string(state)}}
      {:error, reason} -> {:error, {:fetch_failed, reason}}
    end
  end

  # -- worktree attach and session resume -----------------------------------------

  # Only this PR's repository's worktrees are candidates: an entry with no `repo_id`
  # belongs to the run's primary (E12), so another repo's worktree is never reused.
  defp original_worktree(run_id, record, head) do
    repo_id = Map.get(record, :repo_id)

    entries =
      run_id
      |> ProjectionStore.worktrees_for_run()
      |> Enum.filter(&(blank_to_nil(&1[:repo_id]) == blank_to_nil(repo_id)))

    Enum.find(entries, &(&1[:branch] == head)) || List.last(entries)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Where the fix runs and whether the provider session can follow it.
  defp attach(repo_path, head, original) do
    original_path = original && original[:worktree_path]

    case Git.worktree_list(repo_path) do
      {:ok, worktrees} ->
        case Enum.find(worktrees, &(&1.branch == head)) do
          %{path: path} -> {:ok, %{path: nil, resume?: path == original_path}}
          nil -> attach_new(original_path)
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp attach_new(original_path) when is_binary(original_path) do
    if File.exists?(original_path),
      do: {:ok, %{path: nil, resume?: false}},
      else: {:ok, %{path: original_path, resume?: true}}
  end

  defp attach_new(nil), do: {:ok, %{path: nil, resume?: false}}

  defp agent(run, resume?) do
    cfg = Application.get_env(:foreman_server, :pr_fix, [])
    default = Keyword.get(cfg, :agent, %{"provider" => "claude"})

    session =
      run
      |> Map.get(:provider_sessions, [])
      |> Enum.filter(&(is_binary(&1[:provider]) and is_binary(&1[:provider_session_id])))
      |> List.last()

    provider = (session && session.provider) || default["provider"]

    %{
      provider: provider,
      model: (session && session[:model]) || default["model"],
      effort: default["effort"],
      session_id: if(resume? and session, do: session.provider_session_id)
    }
  end

  # -- prompt ------------------------------------------------------------------

  defp render(kind, record, status, head, base, pr_url, opts) do
    {values, data} = prompt_data(kind, status, record, pr_url, opts)

    Prompt.render(
      Map.fetch!(@templates, kind),
      %{
        "head_branch" => head,
        "base_branch" => base,
        "pr_url" => pr_url,
        "note" => Keyword.get(opts, :note) || "",
        "data" => truncate(data, @max_data_bytes)
      }
      |> Map.merge(values)
    )
  end

  defp prompt_data("ci", %PrStatus{} = status, _record, pr_url, opts) do
    failing = Enum.filter(status.checks, &(&1.state == :failing))

    lines =
      Enum.map(failing, fn check ->
        "- #{check.name} [#{check.conclusion || "failed"}] #{check.url || ""}"
      end)

    logs = failing |> Enum.map(&log_excerpt(pr_url, &1, opts)) |> Enum.reject(&is_nil/1)

    lines = if lines == [], do: ["(none reported failing at fetch time)"], else: lines

    {%{}, Enum.join(["Failing checks:" | lines] ++ ["" | logs], "\n")}
  end

  defp prompt_data("comments", %PrStatus{} = status, _record, _pr_url, _opts) do
    threads =
      for %{resolved: false} = thread <- status.threads || [] do
        comments =
          thread.comments
          |> Enum.map(&"  #{&1.author || "unknown"}: #{String.slice(&1.body, 0, @max_body)}")
          |> Enum.join("\n")

        "Thread #{thread.path || "(no file)"}:#{thread.line || "?"}#{if thread.outdated, do: " (outdated)", else: ""}\n#{comments}"
      end

    conversation =
      Enum.map(
        status.comments,
        &"#{&1.author || "unknown"}: #{String.slice(&1.body, 0, @max_body)}"
      )

    decision = if status.review_decision, do: Atom.to_string(status.review_decision), else: "none"

    {%{"review_decision" => decision},
     Enum.join(
       ["Unresolved review threads:" | empty_as_none(threads)] ++
         ["", "Conversation comments:" | empty_as_none(conversation)],
       "\n\n"
     )}
  end

  defp prompt_data("conflicts", %PrStatus{} = status, _record, _pr_url, _opts) do
    {%{}, "Merge state reported by GitHub: #{status.merge_state_status || "unknown"}"}
  end

  defp empty_as_none([]), do: ["(none)"]
  defp empty_as_none(list), do: list

  defp log_excerpt(pr_url, check, opts) do
    fetcher = Keyword.get(opts, :log_fetcher, &default_log/2)

    case fetcher.(pr_url, check) do
      {:ok, text} when is_binary(text) and text != "" ->
        "Log excerpt for #{check.name} (tail):\n" <> tail(text)

      _unavailable ->
        nil
    end
  end

  defp tail(text) do
    limit = Application.get_env(:foreman_server, :pr_fix, [])[:log_tail_bytes] || 20_000
    size = byte_size(text)

    excerpt =
      if size > limit,
        do: "…" <> binary_part(text, size - limit, limit),
        else: text

    excerpt |> String.replace(~r/[^\x00-\x7F]|\x00/u, "?") |> WorkerLogPolicy.redact()
  end

  defp default_log(pr_url, %{url: url}) when is_binary(url) do
    with [_, run_id] <- Regex.run(~r{/actions/runs/(\d+)}, url),
         [_, repo] <- Regex.run(~r{github\.com/([^/]+/[^/]+)/pull/}, pr_url),
         gh when is_binary(gh) <- System.find_executable("gh"),
         {output, 0} <-
           System.cmd(gh, ["run", "view", run_id, "--log-failed", "-R", repo],
             stderr_to_stdout: true
           ) do
      {:ok, output}
    else
      _ -> {:error, :log_unavailable}
    end
  end

  defp default_log(_pr_url, _check), do: {:error, :log_unavailable}

  defp truncate(text, max) when byte_size(text) > max,
    do: binary_part(text, 0, max) <> "\n…(truncated)"

  defp truncate(text, _max), do: text

  # -- jobsite options -----------------------------------------------------------------

  defp spec_opts(run, repo_path, head, prompt, agent, attach, kind) do
    cfg = Application.get_env(:foreman_server, :pr_fix, [])

    spec =
      %{
        "project_id" => run.project_id,
        "prompt" => prompt,
        "agent" => agent_map(agent),
        "strategy" => %{"branch" => head},
        "push" => true,
        "max_iterations" => Keyword.get(cfg, :max_iterations, 1),
        "name" => "pr-fix-#{kind}-#{run.run_id}"
      }
      |> put_if("sandbox", Keyword.get(cfg, :sandbox))
      |> put_if("resume_session", agent.session_id)
      |> put_if("bead_id", bead_id(run))

    with {:ok, opts} <- Spec.from_json(spec) do
      {:ok,
       opts
       |> Keyword.put(:repo_path, repo_path)
       |> Keyword.put(:sync_remote, "origin")
       |> put_path(attach.path)}
    end
  end

  defp agent_map(agent) do
    %{"provider" => agent.provider}
    |> put_if("model", agent.model)
    |> put_if("effort", agent.effort)
  end

  defp bead_id(run) do
    case ProjectionStore.task_projection(run.task_id) do
      %{external_id: id} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp put_path(opts, nil), do: opts
  defp put_path(opts, path), do: Keyword.put(opts, :path, path)
end
