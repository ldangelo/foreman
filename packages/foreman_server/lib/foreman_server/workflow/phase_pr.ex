defmodule ForemanServer.Workflow.PhasePR do
  @moduledoc """
  Creates or reconciles a phase-scoped GitHub PR for a completed workflow phase.

  The request is typed and explicit: base branch is the recorded run base branch,
  head branch is the Foreman run branch, and no defaults are invented. Results
  are phase records, not final run PR associations.
  """

  require Logger

  defmodule Request do
    @moduledoc "Typed phase PR request."
    @enforce_keys [
      :run_id,
      :phase_id,
      :phase_index,
      :phase_name,
      :base_branch,
      :head_branch,
      :cwd
    ]
    defstruct [
      :run_id,
      :phase_id,
      :phase_index,
      :phase_name,
      :base_branch,
      :head_branch,
      :cwd,
      :artifact_path,
      :now,
      :command_runner,
      existing_records: []
    ]
  end

  defmodule Record do
    @moduledoc "Typed phase PR outcome."
    @enforce_keys [
      :run_id,
      :phase_id,
      :phase_index,
      :phase_name,
      :status,
      :base_branch,
      :head_branch,
      :provider,
      :recorded_at
    ]
    defstruct [
      :run_id,
      :phase_id,
      :phase_index,
      :phase_name,
      :status,
      :pr_url,
      :pr_number,
      :base_branch,
      :head_branch,
      :provider,
      :reason,
      :recorded_at
    ]
  end

  defmodule Error do
    @moduledoc "Typed phase PR error."
    @enforce_keys [:reason, :phase_id, :base_branch, :head_branch, :details]
    defstruct [:reason, :phase_id, :base_branch, :head_branch, :details]
  end

  @type result :: {:ok, %Record{}} | {:error, %Error{}}

  @spec maybe_create(%Request{}) :: result()
  def maybe_create(%Request{} = request) do
    with :ok <- validate_request(request),
         :not_recorded <- existing_record(request),
         {:ok, ahead} <- commits_ahead(request) do
      cond do
        ahead == 0 ->
          {:ok, record(request, :noop, reason: :no_commits_ahead)}

        true ->
          create_or_reuse(request)
      end
    else
      {:ok, %Record{} = record} -> {:ok, record}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def maybe_create(other) do
    {:error,
     %Error{
       reason: :invalid_request,
       phase_id: nil,
       base_branch: nil,
       head_branch: nil,
       details: other
     }}
  end

  defp validate_request(%Request{} = request) do
    cond do
      blank?(request.base_branch) ->
        typed_error(request, :phase_pr_base_branch_unresolved, request)

      blank?(request.head_branch) ->
        typed_error(request, :phase_pr_head_branch_unresolved, request)

      blank?(request.cwd) ->
        typed_error(request, :phase_pr_worktree_unresolved, request)

      true ->
        :ok
    end
  end

  defp existing_record(%Request{} = request) do
    request.existing_records
    |> Enum.find(fn record ->
      Map.get(record, :phase_id) == request.phase_id and
        Map.get(record, :status) in ["created", "existing", :created, :existing]
    end)
    |> case do
      nil -> :not_recorded
      record -> {:ok, record_from_existing(request, record)}
    end
  end

  defp commits_ahead(request) do
    case run(request, "git", [
           "rev-list",
           "--count",
           request.base_branch <> ".." <> request.head_branch
         ]) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {count, _} -> {:ok, count}
          :error -> typed_error(request, :unparsable_rev_list, output)
        end

      {output, exit_code} ->
        typed_error(request, :rev_list_failed, %{
          exit_code: exit_code,
          output: String.trim(output)
        })
    end
  end

  defp create_or_reuse(request) do
    with :none <- matching_pr(request, "open"),
         :none <- matching_pr(request, "closed"),
         :ok <- push_head(request) do
      open_pr(request)
    else
      {:ok, %{state: "open"} = pr} ->
        {:ok, record(request, :existing, pr_url: pr.url, pr_number: pr.number)}

      {:ok, %{state: "closed"} = pr} ->
        typed_error(request, :matching_pr_closed, pr)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp push_head(request) do
    Logger.info("PhasePR.run_id=#{request.run_id} git push -u origin #{request.head_branch}")

    case run(request, "git", ["push", "-u", "origin", request.head_branch]) do
      {_output, 0} ->
        :ok

      {output, exit_code} ->
        typed_error(request, :git_push_failed, %{
          exit_code: exit_code,
          output: String.trim(output)
        })
    end
  end

  defp open_pr(request) do
    title = "feat(phase): #{request.phase_name}"

    body =
      "Foreman run `#{request.run_id}` phase `#{request.phase_name}` complete.\n" <>
        if(request.artifact_path, do: "\nArtifact: #{request.artifact_path}\n", else: "")

    args = [
      "pr",
      "create",
      "--base",
      request.base_branch,
      "--head",
      request.head_branch,
      "--title",
      title,
      "--body",
      body
    ]

    case run(request, "gh", args) do
      {output, 0} ->
        url = pr_url_from_output(output) || String.trim(output)
        {:ok, record(request, :created, pr_url: url, pr_number: pr_number_from_url(url))}

      {output, exit_code} ->
        typed_error(request, :gh_pr_create_failed, %{
          exit_code: exit_code,
          output: String.trim(output)
        })
    end
  end

  defp matching_pr(request, state) do
    args = [
      "pr",
      "list",
      "--state",
      state,
      "--head",
      request.head_branch,
      "--base",
      request.base_branch,
      "--json",
      "url,number",
      "--limit",
      "1"
    ]

    case run(request, "gh", args) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, [%{"url" => url} = pr | _]} ->
            {:ok, %{state: state, url: url, number: pr["number"]}}

          {:ok, []} ->
            :none

          {:ok, other} ->
            typed_error(request, :unexpected_pr_list_payload, other)

          {:error, error} ->
            typed_error(request, :unparsable_pr_list, inspect(error))
        end

      {_output, _exit_code} ->
        # `gh pr list` is best-effort reconciliation. Creation remains the loud
        # authority and will surface provider failures with command output.
        :none
    end
  end

  defp record(request, status, opts) do
    %Record{
      run_id: request.run_id,
      phase_id: request.phase_id,
      phase_index: request.phase_index,
      phase_name: request.phase_name,
      status: Atom.to_string(status),
      pr_url: Keyword.get(opts, :pr_url),
      pr_number: Keyword.get(opts, :pr_number),
      base_branch: request.base_branch,
      head_branch: request.head_branch,
      provider: "github",
      reason: keyword_reason(opts),
      recorded_at: recorded_at(request)
    }
  end

  defp record_from_existing(request, existing) do
    %Record{
      run_id: request.run_id,
      phase_id: request.phase_id,
      phase_index: request.phase_index,
      phase_name: request.phase_name,
      status: to_string(Map.get(existing, :status)),
      pr_url: Map.get(existing, :pr_url),
      pr_number: Map.get(existing, :pr_number),
      base_branch: Map.get(existing, :base_branch) || request.base_branch,
      head_branch: Map.get(existing, :head_branch) || request.head_branch,
      provider: Map.get(existing, :provider) || "github",
      reason: Map.get(existing, :reason),
      recorded_at: Map.get(existing, :recorded_at) || recorded_at(request)
    }
  end

  defp run(request, executable, args) do
    runner = request.command_runner || (&System.cmd/3)
    opts = [cd: request.cwd, stderr_to_stdout: true]
    runner.(executable, args, opts)
  end

  defp typed_error(request, reason, details) do
    {:error,
     %Error{
       reason: reason,
       phase_id: request.phase_id,
       base_branch: request.base_branch,
       head_branch: request.head_branch,
       details: details
     }}
  end

  defp keyword_reason(opts) do
    case Keyword.get(opts, :reason) do
      nil -> nil
      reason -> to_string(reason)
    end
  end

  defp recorded_at(%{now: %DateTime{} = now}), do: DateTime.to_iso8601(now)
  defp recorded_at(_request), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp pr_url_from_output(output) do
    case Regex.run(~r"https://github\.com/[^\s]+", output) do
      [url | _] -> String.trim(url)
      nil -> nil
    end
  end

  defp pr_number_from_url(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)(?:\D|$)}, url) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp pr_number_from_url(_url), do: nil

  defp blank?(value), do: not is_binary(value) or value == ""
end
