defmodule ForemanServer.PrReport.Publisher do
  @moduledoc """
  TRD-021: publishes the risk report of a PR head as ONE comment of the run, bound to the head
  and the risk digest, and supersedes it when the head moves.

  ## Trigger (the production path)

  A `ProjectionStore` subscriber (`init/1` subscribes with `replay_existing: false` and stops
  with `{:projection_subscribe_failed, reason}` on an error, as `PrWatcher` does). It reacts to
  `PrRiskRecorded` and to the operator's `PrReportRequested` (TRD-030, `publish_requested/2`)
  and never to a comment, review or webhook event. `PrRiskRecorded` is appended by the system command
  `run.pr.risk`, which `PrObservation` builds for every observed PR and `PrWatcher.Observer`
  dispatches (`pr_observation.ex`, `risk_commands/7`); a poll, a webhook and the watcher's
  subscription all reach it through `PrWatcher.refresh/2`. Posting a comment appends no event
  that starts another observation, so the publisher cannot feed itself.

  The event is a trigger and the source of the report body (the projection keeps only the
  risk record's summary); `publish/2` reads the CURRENT watch record before it acts.

  ## Eligibility (`publish/2`)

  The step publishes only when the PR is open (`open` or `conflicted`) and watched, the
  project is gated (`PrEvidence.project_policy/1` answers a non-nil policy: an error or `nil`
  publishes nothing, because publication follows the gate switch), the record's risk is the
  trigger's, for the record's current head, and `evidence.report` does not already name that
  head and digest (published, or refused: a refusal is retried by the operator command of
  TRD-030 only). Otherwise it answers `{:skipped, why}` and records nothing.

  ## Publication

  Under the publisher's `Task.Supervisor`, one task in flight per `{run_id, pr_url}` with the
  newest trigger remembered, so a burst publishes once. The task resolves the redaction list
  (`ProjectEnvironment.fetch_secrets/1`: an error is the refusal `redaction_failed`, never a
  render under a partial list), renders (`PrReport.render/2`) and runs the keyed effect
  (`Effect.run(:pr_comment, ...)`) whose function lists the PR's comments once and then

    1. adopts: a comment the token's user wrote whose marker names this run, head and digest
       is the result and nothing is written (this is also how a crash after the write finds
       its own comment: the repeatable effect key alone does not stop a second post);
    2. else edits: the latest comment of this run written by the token's user, for another
       head or digest, is replaced through `GitHub.PrComment.update/3`; its old head is the
       `superseded` of the outcome;
    3. else creates one (`GitHub.PrComment.create/3`).

  The outcome is the system command `run.pr.comment_published` (`PrCommentPublished`,
  `evidence.report`): `published`, or `refused` with `redaction_failed`, `effect_refused`,
  `gh_failed` or `publisher_error` (the publication raised). The render refusals `invalid_record` and `report_too_large` and an identity
  the effect key cannot carry are `effect_refused`: the closed reason set has no other home
  for them. Nothing is retried here; nothing in this module blocks, cancels or refuses a run
  or reads the merge gate.

  `publish/2` is the one publish step: the start-up scan of TRD-035 reuses it. `post/2` is its
  publication half without the eligibility check.

  Configuration: `config :foreman_server, :pr_report_publisher, enabled: boolean` (read as
  `enabled != false`; `config/test.exs` sets `false`). Options of `start_link/1`, passed to
  `publish/2`: `:command_runner` and `:timeout_ms` (for `gh`, see `GitHub.PrComment`),
  `:secrets_fun` (`project_id -> {:ok, [String.t()]} | {:error, term()}`, default
  `ProjectEnvironment.fetch_secrets/1`) and `:now_fun` (`-> ms`).
  """

  use GenServer

  alias ForemanServer.CommandGateway
  alias ForemanServer.Coordinator.Redact
  alias ForemanServer.GitHub.PrComment, as: GhComment
  alias ForemanServer.Idempotency.Effect
  alias ForemanServer.Idempotency.Reconcilers.PrComment, as: CommentEffect

  alias ForemanServer.{
    EventStore,
    PrEvidence,
    PrObservation,
    PrReport,
    ProjectEnvironment,
    ProjectionStore
  }

  require Logger

  @open_statuses ~w(open conflicted)
  @max_detail 500

  @type result ::
          {:skipped, atom()}
          | {:published, map()}
          | {:refused, atom(), String.t()}
          | {:error, term()}

  # -- public API ------------------------------------------------------------

  @doc "Whether the publisher is enabled in configuration (default true)."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:foreman_server, :pr_report_publisher, [])[:enabled] != false
  end

  @doc "Start the publisher. Options: `:name` (default the module) and those of the moduledoc."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Number of publications in flight."
  @spec inflight(GenServer.server()) :: non_neg_integer()
  def inflight(server \\ __MODULE__), do: GenServer.call(server, :inflight)

  @doc """
  The publish step for one `PrRiskRecorded` payload (atom or string keys): checks eligibility
  against the current watch record and publishes. See the moduledoc.
  """
  @spec publish(map(), keyword()) :: result()
  def publish(trigger, opts \\ []) when is_map(trigger) and is_list(opts) do
    with {:ok, t} <- trigger(trigger),
         :ok <- eligible(t) do
      guarded_post(t, opts)
    end
  end

  @doc """
  The publication alone: redact, render, run the keyed effect and record the outcome, without
  the eligibility check of `publish/2`. For the callers that decide eligibility themselves
  (the operator's retry of a refused report, TRD-030).
  """
  @spec post(map(), keyword()) :: result()
  def post(trigger, opts \\ []) when is_map(trigger) and is_list(opts) do
    with {:ok, t} <- trigger(trigger), do: guarded_post(t, opts)
  end

  @doc """
  The publish step for one `PrReportRequested` payload (TRD-030, the operator's retry): the
  eligibility of `publish/2` except that a REFUSED report of the head and digest is retried (a
  published one is not), then the publication of the report of the risk record the request
  names. The record is read from the run's event stream (the request carries its head and digest
  only, and the projection keeps a summary): a record the stream does not hold is
  `{:error, {:risk_record_unreadable, why}}` and nothing is written.
  """
  @spec publish_requested(map(), keyword()) :: result()
  def publish_requested(request, opts \\ []) when is_map(request) and is_list(opts) do
    with {:ok, t} <- trigger(request),
         :ok <- eligible(t, true),
         {:ok, risk} <- read_risk_record(t) do
      guarded_post(%{t | risk: risk}, opts)
    end
  end

  defp read_risk_record(t) do
    case EventStore.read_stream_forward("run:#{t.run_id}", 0, 99_999_999) do
      {:ok, events} ->
        events
        |> Enum.filter(&risk_event?(&1, t))
        |> List.last()
        |> case do
          nil -> {:error, {:risk_record_unreadable, :not_in_stream}}
          %{data: data} -> {:ok, data}
        end

      {:error, reason} ->
        {:error, {:risk_record_unreadable, reason}}
    end
  end

  defp risk_event?(%{event_type: "PrRiskRecorded", data: data}, t) when is_map(data),
    do:
      get(data, :pr_url) == t.pr_url and get(data, :head_sha) == t.head_sha and
        get(data, :digest) == t.digest

  defp risk_event?(_event, _t), do: false

  # A raise or throw inside the publication (the secret store, the effect function, a runner)
  # is a typed refusal, not a silent task crash: the detail names the kind of failure only,
  # never a message that could carry a secret.
  defp guarded_post(t, opts) do
    do_post(t, opts)
  rescue
    error -> refuse_failure(t, "raised #{inspect(error.__struct__)}", opts)
  catch
    kind, _value -> refuse_failure(t, "#{kind}", opts)
  end

  defp refuse_failure(t, what, opts),
    do: refuse(t, :publisher_error, "the publication #{what}", [], opts)

  # -- GenServer ---------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    case ProjectionStore.subscribe(replay_existing: false) do
      :ok ->
        {:ok, %{supervisor: supervisor, opts: opts, running: %{}, flights: %{}, pending: %{}}}

      {:error, reason} ->
        {:stop, {:projection_subscribe_failed, reason}}
    end
  end

  @impl true
  def handle_info({:projection_event, %{event_type: "PrRiskRecorded"} = event}, state) do
    payload = event_payload(event)

    case key(payload) do
      nil -> {:noreply, state}
      key -> {:noreply, enqueue(state, key, payload)}
    end
  end

  def handle_info({:projection_event, %{event_type: "PrReportRequested"} = event}, state) do
    payload = event_payload(event)

    case key(payload) do
      nil -> {:noreply, state}
      key -> {:noreply, enqueue(state, key, {:request, payload})}
    end
  end

  def handle_info({:projection_event, _other}, state), do: {:noreply, state}

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    log_result(result)
    {:noreply, finish(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    Logger.error("PrReport.Publisher task crashed: #{inspect(reason)}")
    {:noreply, finish(state, ref)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:inflight, _from, state), do: {:reply, map_size(state.running), state}

  # One task per `{run_id, pr_url}`; a trigger that arrives meanwhile replaces the one waiting.
  defp enqueue(state, key, trigger) do
    if Map.has_key?(state.running, key),
      do: %{state | pending: Map.update(state.pending, key, trigger, &newest(&1, trigger))},
      else: start(state, key, trigger)
  end

  # The newest trigger waits, except that a waiting operator request is not replaced by a risk
  # trigger for the same head and digest (that one would be skipped as already reported).
  defp newest({:request, old}, new) when is_map(new) do
    if get(old, :head_sha) == get(new, :head_sha) and get(old, :digest) == get(new, :digest),
      do: {:request, old},
      else: new
  end

  defp newest(_old, new), do: new

  defp start(state, key, trigger) do
    opts = state.opts
    task = Task.Supervisor.async_nolink(state.supervisor, fn -> run_trigger(trigger, opts) end)

    %{
      state
      | running: Map.put(state.running, key, task.ref),
        flights: Map.put(state.flights, task.ref, key)
    }
  end

  defp run_trigger({:request, request}, opts), do: publish_requested(request, opts)
  defp run_trigger(payload, opts), do: publish(payload, opts)

  defp finish(state, ref) do
    {key, flights} = Map.pop(state.flights, ref)
    state = %{state | flights: flights, running: Map.delete(state.running, key)}

    case Map.pop(state.pending, key) do
      {nil, _pending} -> state
      {payload, pending} -> start(%{state | pending: pending}, key, payload)
    end
  end

  defp log_result({:error, reason}),
    do: Logger.error("PrReport.Publisher could not record an outcome: #{inspect(reason)}")

  defp log_result(_result), do: :ok

  # -- eligibility -------------------------------------------------------------

  defp trigger(payload) do
    t = %{
      run_id: get(payload, :run_id),
      pr_url: get(payload, :pr_url),
      project_id: get(payload, :project_id),
      task_id: get(payload, :task_id),
      repo_id: get(payload, :repo_id),
      head_sha: get(payload, :head_sha),
      digest: get(payload, :digest),
      risk: payload
    }

    if Enum.all?(
         [t.run_id, t.pr_url, t.project_id, t.task_id, t.head_sha, t.digest],
         &(is_binary(&1) and &1 != "")
       ),
       do: {:ok, t},
       else: {:skipped, :invalid_trigger}
  end

  defp eligible(t, retry? \\ false) do
    with {:ok, record} <- watch_record(t),
         :ok <- open_and_watched(record),
         :ok <- gated(record.project_id),
         :ok <- current_risk(record, t) do
      not_yet_reported(record, t, retry?)
    end
  end

  defp watch_record(t) do
    case Enum.find(ProjectionStore.pr_watch(t.run_id), &(&1.pr_url == t.pr_url)) do
      nil -> {:skipped, :not_watched}
      record -> {:ok, record}
    end
  end

  defp open_and_watched(%{watching: true, status: status}) when status in @open_statuses, do: :ok
  defp open_and_watched(_record), do: {:skipped, :not_open_or_not_watched}

  defp gated(project_id) do
    case PrEvidence.project_policy(project_id) do
      {:ok, %{}} -> :ok
      {:ok, nil} -> {:skipped, :ungated}
      {:error, _reason} -> {:skipped, :policy_unavailable}
    end
  end

  defp current_risk(record, %{head_sha: head, digest: digest}) do
    case record do
      %{head_sha: ^head, evidence: %{risk: %{head_sha: ^head, digest: ^digest}}} -> :ok
      _other -> {:skipped, :risk_not_current}
    end
  end

  # A risk trigger is skipped for a head and digest already reported, published or refused (a
  # refusal is retried by the operator's request only); the request retries a refused one and
  # skips only a published one.
  defp not_yet_reported(record, %{head_sha: head, digest: digest}, retry?) do
    statuses = if retry?, do: ["published"], else: ["published", "refused"]

    case record.evidence.report do
      %{head_sha: ^head, digest: ^digest, status: status} ->
        if status in statuses, do: {:skipped, :already_reported}, else: :ok

      _other ->
        :ok
    end
  end

  # -- publication -------------------------------------------------------------

  defp do_post(t, opts) do
    secrets_fun = Keyword.get(opts, :secrets_fun, &ProjectEnvironment.fetch_secrets/1)

    case secrets_fun.(t.project_id) do
      {:ok, secrets} when is_list(secrets) ->
        render(t, secrets, opts)

      {:error, reason} ->
        refuse(
          t,
          :redaction_failed,
          "the redaction list could not be resolved: #{tag(reason)}",
          [],
          opts
        )

      _other ->
        refuse(t, :redaction_failed, "the redaction list could not be resolved", [], opts)
    end
  end

  defp render(t, secrets, opts) do
    case PrReport.render(t.risk, secrets: secrets) do
      {:ok, body} ->
        run_effect(t, body, secrets, opts)

      {:error, :redaction_failed} ->
        refuse(
          t,
          :redaction_failed,
          "a secret value would have survived redaction in the report",
          secrets,
          opts
        )

      {:error, :redaction_unavailable} ->
        refuse(t, :redaction_failed, "the redaction list is unusable", secrets, opts)

      {:error, reason} ->
        refuse(t, :effect_refused, "the report was not rendered: #{tag(reason)}", secrets, opts)
    end
  end

  defp run_effect(t, body, secrets, opts) do
    if Enum.all?([t.run_id, t.head_sha, t.digest], &Effect.key_part?/1) do
      gh = Keyword.take(opts, [:command_runner, :timeout_ms])
      meta = CommentEffect.intent(t.run_id, t.pr_url, t.head_sha, t.digest)
      key = CommentEffect.key(t.run_id, t.head_sha, t.digest)

      case Effect.run(:pr_comment, key, fn -> write(t, body, gh) end, meta) do
        {:ok, %{comment_id: _} = outcome} ->
          publish_outcome(t, outcome, opts)

        {:error, {:post_failed, error}} ->
          refuse(
            t,
            :gh_failed,
            "gh failed: #{inspect(error, limit: 20, printable_limit: 200)}",
            secrets,
            opts
          )

        {:error, refusal} ->
          refuse(
            t,
            :effect_refused,
            "the effect was refused: #{inspect(refusal, limit: 20, printable_limit: 200)}",
            secrets,
            opts
          )

        _other ->
          refuse(
            t,
            :effect_refused,
            "the effect answered with an unexpected result",
            secrets,
            opts
          )
      end
    else
      refuse(
        t,
        :effect_refused,
        "the run, head or digest cannot be part of an effect key",
        secrets,
        opts
      )
    end
  end

  # The effect function: one list of the PR's comments, then adopt, edit or create.
  defp write(t, body, gh) do
    case GhComment.list(t.pr_url, gh) do
      {:ok, comments} -> t |> own_reports(comments) |> adopt_edit_or_create(t, body, gh)
      {:error, error} -> {:error, {:post_failed, error}}
    end
  end

  # The comments of this run that the token's own user wrote, oldest first: a marker typed by
  # anyone else proves nothing.
  defp own_reports(t, comments) do
    for comment <- comments,
        comment.viewer_did_author,
        {:ok, marker} <- [PrReport.parse_marker(comment.body)],
        marker.run_id == t.run_id,
        do: {comment, marker}
  end

  defp adopt_edit_or_create(own, t, body, gh) do
    case Enum.find(own, fn {_c, m} -> m.head_sha == t.head_sha and m.digest == t.digest end) do
      {comment, _marker} ->
        adopt(comment)

      nil ->
        # a hidden (minimised) comment tells nobody: only a visible one is edited; the same
        # head and digest above may match a hidden one (a person hid it: do not repost it)
        case own |> Enum.reject(fn {c, _m} -> c.minimized end) |> List.last() do
          {comment, marker} -> edit(comment, marker, body, gh)
          nil -> create(t, body, gh)
        end
    end
  end

  defp adopt(%{url: url}) when is_binary(url) do
    case GhComment.parse_comment_url(url) do
      {:ok, _owner, _name, id} ->
        {:ok, %{comment_id: id, comment_url: url, superseded: nil, action: :adopted}}

      {:error, error} ->
        {:error, {:post_failed, error}}
    end
  end

  defp adopt(comment), do: {:error, {:post_failed, no_url(comment)}}

  defp edit(%{url: url}, marker, body, gh) when is_binary(url) do
    case GhComment.update(url, body, gh) do
      {:ok, written} ->
        {:ok,
         %{
           comment_id: written.rest_id,
           comment_url: written.url,
           superseded: marker.head_sha,
           action: :edited
         }}

      {:error, error} ->
        {:error, {:post_failed, error}}
    end
  end

  defp edit(comment, _marker, _body, _gh), do: {:error, {:post_failed, no_url(comment)}}

  defp create(t, body, gh) do
    case GhComment.create(t.pr_url, body, gh) do
      {:ok, written} ->
        {:ok,
         %{
           comment_id: written.rest_id,
           comment_url: written.url,
           superseded: nil,
           action: :created
         }}

      {:error, error} ->
        {:error, {:post_failed, error}}
    end
  end

  # An own comment GitHub listed without a URL cannot be edited or numbered; writing another
  # would put a second report on the PR.
  defp no_url(comment), do: {:gh_unexpected_payload, {:comment_without_url, comment.id}}

  # -- recording ---------------------------------------------------------------

  defp publish_outcome(t, outcome, opts) do
    case record(t, "published", outcome, opts) do
      :ok -> {:published, outcome}
      {:error, _reason} = error -> error
    end
  end

  defp refuse(t, reason, detail, secrets, opts) do
    detail =
      detail |> then(&Redact.text(nil, &1, secrets: secrets)) |> String.slice(0, @max_detail)

    case record(t, "refused", %{reason: Atom.to_string(reason), detail: detail}, opts) do
      :ok -> {:refused, reason, detail}
      {:error, _reason} = error -> error
    end
  end

  defp record(t, status, fields, opts) do
    recorded_at = now(opts)

    command_id =
      "pr_comment_published:#{t.run_id}:#{PrObservation.url_hash(t.pr_url)}:#{t.head_sha}:#{t.digest}" <>
        if(status == "refused", do: ":refused:#{recorded_at}", else: ":#{recorded_at}")

    payload =
      fields
      |> Map.take([:comment_id, :comment_url, :superseded, :reason, :detail])
      |> Map.merge(%{
        run_id: t.run_id,
        pr_url: t.pr_url,
        project_id: t.project_id,
        task_id: t.task_id,
        repo_id: t.repo_id,
        head_sha: t.head_sha,
        digest: t.digest,
        status: status,
        recorded_at: recorded_at
      })

    command = %{
      type: "run.pr.comment_published",
      command_id: command_id,
      aggregate_id: "run:#{t.run_id}",
      payload: payload
    }

    case CommandGateway.dispatch_system(command) do
      {:ok, _spec} -> :ok
      {:error, reason} -> {:error, {:outcome_not_recorded, status, reason}}
      {:error, reason, detail} -> {:error, {:outcome_not_recorded, status, {reason, detail}}}
    end
  end

  # -- helpers -----------------------------------------------------------------

  defp now(opts), do: Keyword.get(opts, :now_fun, fn -> System.system_time(:millisecond) end).()

  defp tag(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp tag(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: Atom.to_string(elem(reason, 0))

  defp tag(_reason), do: "unknown"

  defp key(payload) do
    case {get(payload, :run_id), get(payload, :pr_url)} do
      {run_id, url} when is_binary(run_id) and run_id != "" and is_binary(url) and url != "" ->
        {run_id, url}

      _other ->
        nil
    end
  end

  # Projection events carry their payload as `data` (appended events) or `payload` (applied).
  defp event_payload(%{data: data}) when is_map(data), do: data
  defp event_payload(%{payload: payload}) when is_map(payload), do: payload
  defp event_payload(_event), do: %{}

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
