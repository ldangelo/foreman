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

  `publish/2` is the one publish step: the start-up scan reuses its eligibility. `post/2` is its
  publication half without the eligibility check.

  ## Start-up scan (TRD-035)

  `init/1` subscribes first, then returns `{:continue, :scan}`: the scan reads
  `ProjectionStore.watched_prs/0` for records that are watched and open, hold a risk record for
  their current head and no `evidence.report` (published or refused) for that head and digest, and
  publishes each through the same task path as an event (`publish_from_stream/3`: the
  eligibility of `publish/2`, so an ungated project or an unreadable policy is skipped, then the
  report of the stream's risk record, then `post/2`, the single flight and the keyed effect with
  adoption by marker). A refused report is never retried here, only by the operator command.
  At most two publications run at the same time while the scan drains its queue; the
  application start waits for nothing. A scan item whose PR has a publication in flight stays
  queued and is started when that publication finishes. A read of the projection that fails
  (timeout, raise) is retried up to three times, `:scan_retry_ms` apart, then logged as an error.

  Configuration: `config :foreman_server, :pr_report_publisher, enabled: boolean` (read as
  `enabled != false`; `config/test.exs` sets `false`). Options of `start_link/1`, passed to
  `publish/2`: `:command_runner` and `:timeout_ms` (for `gh`, see `GitHub.PrComment`),
  `:secrets_fun` (`project_id -> {:ok, [String.t()]} | {:error, term()}`, default
  `ProjectEnvironment.fetch_secrets/1`), `:now_fun` (`-> ms`) and `:scan` (default `true`; the
  application starts the publisher without it, so the start-up scan always runs there: a test
  that exercises only the live trigger passes `false`), `:scan_reader` (`-> [record]`, default
  `ProjectionStore.watched_prs/0`) and `:scan_retry_ms` (default 1000).
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
  @scan_concurrency 2
  @scan_attempts 3
  @scan_retry_ms 1_000

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
  def publish_requested(request, opts \\ []) when is_map(request) and is_list(opts),
    do: publish_from_stream(request, true, opts)

  # The eligibility of `publish/2` (`retry?` lets a refused report through), then the report of
  # the risk record the stream holds for the head and digest.
  defp publish_from_stream(payload, retry?, opts) do
    with {:ok, t} <- trigger(payload),
         :ok <- eligible(t, retry?),
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
        state = %{
          supervisor: supervisor,
          opts: opts,
          running: %{},
          flights: %{},
          pending: %{},
          scan_queue: []
        }

        {:ok, state, if(Keyword.get(opts, :scan, true), do: {:continue, :scan}, else: :infinity)}

      {:error, reason} ->
        {:stop, {:projection_subscribe_failed, reason}}
    end
  end

  # TRD-035: the events appended while the publisher was down never reach the subscription, so
  # after it has subscribed it scans the projection for the PRs that still need a report. The
  # scan runs here, after `init/1` returned (the supervision tree never waits for it), only
  # reads the projection, and a failure of the read is logged, not a crash.
  @impl true
  def handle_continue(:scan, state), do: {:noreply, run_scan(state, 1)}

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

  def handle_info({:scan_retry, attempt}, state), do: {:noreply, run_scan(state, attempt)}

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    log_result(result)
    {:noreply, finish(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    Logger.error("PrReport.Publisher task crashed: #{crash_kind(reason)}")
    {:noreply, finish(state, ref)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # What kind of crash, never its stacktrace (frames carry function arguments).
  defp crash_kind({%{__struct__: module}, stacktrace}) when is_list(stacktrace),
    do: inspect(module)

  defp crash_kind({kind, _value}) when kind in [:throw, :exit, :error], do: Atom.to_string(kind)
  defp crash_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp crash_kind(_reason), do: "unknown"

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

  defp run_trigger({:request, request}, opts) do
    result = publish_requested(request, opts)

    # The command is accepted whatever the project's gate says, so a request that publishes
    # nothing says why, once.
    with {:skipped, why} <- result do
      Logger.info(
        "PrReport.Publisher: the requested report of run #{get(request, :run_id)} was not " <>
          "published (#{why}): it publishes only for a project whose required_checks gate is " <>
          "on, for the PR's current risk record"
      )
    end

    result
  end

  defp run_trigger({:scan, payload}, opts), do: publish_from_stream(payload, false, opts)
  defp run_trigger(payload, opts), do: publish(payload, opts)

  defp finish(state, ref) do
    {key, flights} = Map.pop(state.flights, ref)
    state = %{state | flights: flights, running: Map.delete(state.running, key)}

    state =
      case Map.pop(state.pending, key) do
        {nil, _pending} -> state
        {payload, pending} -> start(%{state | pending: pending}, key, payload)
      end

    pump_scan(state)
  end

  # The scan starts a publish only while fewer than `@scan_concurrency` are in flight, so a
  # burst of PRs never starts unbounded `gh` calls; each finished task starts the next. An item
  # whose PR already has a publication in flight (a live trigger or an operator request, which
  # may be for another digest and publish nothing) stays queued, in order, and the finish of that
  # publication pumps it again: the scan never drops an item it could not start. The queue holds
  # at most one item per PR (`read_scan/1`) and nothing else adds to it.
  defp pump_scan(state) do
    {queue, state} = drain_scan(state.scan_queue, [], state)
    %{state | scan_queue: queue}
  end

  defp drain_scan([], kept, state), do: {Enum.reverse(kept), state}

  defp drain_scan([{key, payload} = item | rest], kept, state) do
    cond do
      map_size(state.running) >= @scan_concurrency ->
        {Enum.reverse(kept, [item | rest]), state}

      Map.has_key?(state.running, key) ->
        drain_scan(rest, [item | kept], state)

      true ->
        drain_scan(rest, kept, start(state, key, {:scan, payload}))
    end
  end

  # One read of the watched PRs: `{:ok, queue}` or `{:error, kind}`. A timeout is an exit and a
  # broken projection a raise; neither crashes the publisher.
  defp read_scan(opts) do
    reader = Keyword.get(opts, :scan_reader, &ProjectionStore.watched_prs/0)

    queue =
      for record <- reader.(),
          payload = scan_candidate(record),
          key = key(payload),
          do: {key, payload}

    {:ok, Enum.uniq_by(queue, &elem(&1, 0))}
  rescue
    _error -> {:error, :raise}
  catch
    kind, _value -> {:error, kind}
  end

  # Up to `@scan_attempts` reads, `:scan_retry_ms` apart, then a logged error: a read that fails
  # once must not cost the whole scan until the next restart.
  defp run_scan(state, attempt) do
    case read_scan(state.opts) do
      {:ok, queue} ->
        pump_scan(%{state | scan_queue: queue})

      {:error, kind} when attempt < @scan_attempts ->
        Logger.warning(
          "PrReport.Publisher start-up scan read failed (#{kind}), attempt #{attempt}: retrying"
        )

        delay = Keyword.get(state.opts, :scan_retry_ms, @scan_retry_ms)
        Process.send_after(self(), {:scan_retry, attempt + 1}, delay)
        state

      {:error, kind} ->
        Logger.error(
          "PrReport.Publisher start-up scan failed (#{kind}) after #{attempt} attempts: " <>
            "no report is published by the scan until the next start"
        )

        state
    end
  end

  # A watched, open record holding a risk record for its current head and no report for that
  # head and digest. Whether the project is gated is decided by the publication step itself.
  defp scan_candidate(%{watching: true, status: status, head_sha: head, evidence: evidence} = rec)
       when status in @open_statuses and is_binary(head) and is_map(evidence) do
    with %{head_sha: ^head, digest: digest} when is_binary(digest) <- Map.get(evidence, :risk),
         false <- reported?(Map.get(evidence, :report), head, digest) do
      %{
        run_id: rec.run_id,
        pr_url: rec.pr_url,
        project_id: rec.project_id,
        task_id: rec.task_id,
        repo_id: Map.get(rec, :repo_id),
        head_sha: head,
        digest: digest
      }
    else
      _other -> nil
    end
  end

  defp scan_candidate(_record), do: nil

  # published or refused: a refusal is retried by the operator command only
  defp reported?(%{head_sha: head, digest: digest}, head, digest), do: true
  defp reported?(_report, _head, _digest), do: false

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
          refuse(t, :gh_failed, "gh failed: #{describe(error, secrets)}", secrets, opts)

        {:error, refusal} ->
          refuse(
            t,
            :effect_refused,
            "the effect was refused: #{describe(refusal, secrets)}",
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

  @doc false
  # A failure term goes into a stored, operator-visible detail. Every string in it (map keys
  # included, and a printable charlist as the string it spells) is redacted against the project's
  # secrets BEFORE `inspect` escapes it or cuts it at 200 characters: a secret holding a quote or
  # a backslash would no longer match once escaped, and one straddling the cut would leave its
  # prefix behind. Total: an improper list, a struct, a tuple, a non-UTF8 binary or anything else
  # an error can carry is handled, and whatever still raises becomes a fixed detail, so a failure
  # is always recorded as the refusal it is and never as a crashed task.
  @spec failure_detail(term(), [String.t()]) :: String.t()
  def failure_detail(term, secrets) do
    term |> scrub(secrets) |> inspect(limit: 20, printable_limit: 200)
  rescue
    _error -> "unprintable"
  catch
    _kind, _value -> "unprintable"
  end

  defp describe(term, secrets), do: failure_detail(term, secrets)

  defp scrub(text, secrets) when is_binary(text), do: Redact.text(nil, text, secrets: secrets)

  defp scrub(%_{} = struct, secrets), do: struct |> Map.from_struct() |> scrub(secrets)

  defp scrub(map, secrets) when is_map(map),
    do: Map.new(map, fn {k, v} -> {scrub(k, secrets), scrub(v, secrets)} end)

  defp scrub([], _secrets), do: []

  defp scrub(list, secrets) when is_list(list) do
    if :io_lib.printable_unicode_list(list),
      do: list |> List.to_string() |> scrub(secrets),
      else: scrub_items(list, secrets)
  end

  defp scrub(tuple, secrets) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&scrub(&1, secrets)) |> List.to_tuple()

  defp scrub(other, _secrets), do: other

  # Walks a proper or improper list; an improper tail is scrubbed as a term of its own.
  defp scrub_items([head | tail], secrets),
    do: [scrub(head, secrets) | scrub_items(tail, secrets)]

  defp scrub_items([], _secrets), do: []
  defp scrub_items(tail, secrets), do: scrub(tail, secrets)

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
