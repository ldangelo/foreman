defmodule ForemanServer.Notifier do
  @moduledoc """
  Turns projected events into outbound notifications: the production producer
  for `ForemanServer.Messaging.notify/2`.

  Subscribes to `ForemanServer.ProjectionStore` (no replay: a restart must not
  re-notify history) and, for each event the `ForemanServer.Notifier.Mapping`
  table knows, decides in this order:

    1. **Project preference** (`notification_preference` project setting):
       `off` drops everything; `blocked_only` (the default when unset) delivers
       only `:blocked` rows (failures, stalls, needs-input, approvals, CI
       failing, review not met); `every_turn` also delivers `:progress` rows
       (completions, PR ready, review recorded) and enables the `:run_update`
       class for that notification even if the global config leaves it out. An
       event that names no project at all (a standalone jobsite) uses the
       default; one that names a project the projection does not know is
       skipped as `project_unresolved` and logged at warning.
    2. **Messaging config**: no enabled provider or an event class the config
       does not enable means nothing is enqueued (and no suppression event is
       written for every ignored event).
    3. **Subject**: the completion of a PR fix thread's jobsite is never
       notified (`JobsiteCompleted` of the jobsite a watched PR has in flight):
       its outcome reaches the operator through the PR's own events, and a row
       for it would announce every fix attempt. Its failure still is.
    4. **`run_update` rate limit**: at most one `:run_update` notification per
       run within `run_update_rate_limit_ms`; later ones in the window are
       dropped (this is the enforcement of that config value).
    5. **Dedupe**: the correlation id is a digest of the event type and the
       rule's `key_fields`, so a replay of the same event collapses in
       `Messaging.notify/2`'s `dedupe_window_ms` check and keeps the same
       notification id (which the dispatcher delivers at most once).

  No secret is ever put in an event. The recipient is the label `"default"`
  (the destination is resolved from config by the dispatcher), and the body is
  passed through `Messaging.Redactor`.

  `stats/1` (counters since boot) and `status/0` (are the notifier and the
  dispatcher up, is messaging enabled and its config valid) are what
  `GET /api/doctor` reports, so "enabled but nothing arrives" is visible.
  """

  use GenServer

  require Logger

  alias ForemanServer.Messaging
  alias ForemanServer.Messaging.{ConfigResolver, Config, Dispatcher, Redactor}
  alias ForemanServer.Notifier.{Mapping, Rule}
  alias ForemanServer.{ProjectionStore, ProjectSettings}

  @recipient "default"
  @default_preference "blocked_only"
  @max_field_chars 500

  @type stats :: %{
          notified: non_neg_integer(),
          errors: non_neg_integer(),
          skipped: %{optional(atom()) => non_neg_integer()},
          last_error: term()
        }

  @type state :: %{
          rules: [Rule.t()],
          clock: (-> integer()),
          last_run_update: %{String.t() => integer()},
          stats: stats()
        }

  @type outcome ::
          {:notified, String.t()}
          | {:skipped,
             :unmapped
             | :preference
             | :project_unresolved
             | :messaging_disabled
             | :pr_fix_jobsite
             | :rate_limited}
          | {:error, term()}

  @type status :: %{
          notifier: :running | :stopped,
          dispatcher: :running | :stopped,
          messaging: :disabled | {:enabled, atom()} | {:invalid, term()},
          stats: stats() | nil
        }

  @doc "Starts the notifier (registered as `ForemanServer.Notifier`; options as `new_state/1` plus `:name`, `:subscribe?`)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = new_state(opts)

    if Keyword.get(opts, :subscribe?, true) do
      case ProjectionStore.subscribe(replay_existing: false) do
        :ok -> {:ok, state}
        {:error, reason} -> {:stop, {:projection_subscribe_failed, reason}}
      end
    else
      {:ok, state}
    end
  end

  @doc """
  Builds the notifier state. Options: `:rules` (default `Mapping.rules/0`; a
  malformed configured rule raises here) and `:clock` (a zero-arity function
  returning monotonic milliseconds, injectable for the rate limit).
  """
  @spec new_state(keyword()) :: state()
  def new_state(opts \\ []) do
    %{
      rules: Keyword.get_lazy(opts, :rules, &Mapping.rules/0),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      last_run_update: %{},
      stats: %{notified: 0, errors: 0, skipped: %{}, last_error: nil}
    }
  end

  @doc """
  Counters since boot: events turned into a notification (`notified`: enqueued,
  not yet delivered), refused by `Messaging.notify/2` or an invalid config
  (`errors`, with the redacted `last_error`), and mapped events skipped, by
  reason (`preference`, `project_unresolved`, `messaging_disabled`,
  `pr_fix_jobsite`, `rate_limited`). Unmapped events are not counted: that is
  nearly every event.
  """
  @spec stats(GenServer.server()) :: stats()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @doc """
  What an operator needs to tell "nothing to notify" from "notifications are
  broken": whether the notifier and the dispatcher processes are up, whether
  messaging is enabled and its config valid (the reason is redacted and never
  holds a destination), and the notifier's counters while it runs.
  """
  @spec status() :: status()
  def status do
    %{
      notifier: process_state(__MODULE__),
      dispatcher: process_state(Dispatcher),
      messaging: messaging_status(),
      stats: current_stats()
    }
  end

  defp process_state(name), do: if(Process.whereis(name), do: :running, else: :stopped)

  defp messaging_status do
    case ConfigResolver.resolve() do
      {:ok, %Config{enabled?: false}} -> :disabled
      {:ok, %Config{provider: provider}} -> {:enabled, provider}
      {:error, reason} -> {:invalid, Redactor.redact(reason)}
    end
  end

  # The notifier can stop between `whereis` and the call; that is "stopped", not a crash here.
  defp current_stats do
    stats()
  catch
    :exit, _reason -> nil
  end

  @impl true
  def handle_call(:stats, _from, state), do: {:reply, state.stats, state}

  @impl true
  def handle_info({:projection_event, event}, state) when is_map(event) do
    case event_parts(event) do
      {type, payload} ->
        {state, outcome} = process(state, type, payload)
        log_outcome(type, outcome)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc """
  Handles one projected event: returns the new state and what happened. Public
  so the decision logic is testable without a subscription. This is where the
  payload's keys are normalised, once (`Rule.normalize_payload!/1`) and only for
  an event type the table maps (nearly every event is not: those are never
  touched): everything below reads strings only. `payload` may be a map or a
  typed event struct.
  """
  @spec process(state(), String.t(), map()) :: {state(), outcome()}
  def process(state, type, payload) when is_binary(type) and is_map(payload) do
    {state, outcome} =
      if Mapping.mapped?(state.rules, type),
        do: decide(state, type, Rule.normalize_payload!(payload)),
        else: {state, {:skipped, :unmapped}}

    {count(state, outcome), outcome}
  end

  defp decide(state, type, payload) do
    with {:ok, rule} <- lookup(state, type, payload),
         project_id = project_id(payload),
         {:ok, preference} <- preference(project_id),
         :ok <- check_preference(preference, rule.level),
         opts = messaging_opts(preference),
         {:ok, config} <- resolve_config(opts),
         :ok <- check_enabled(config, rule.class),
         :ok <- check_subject(type, payload),
         {:ok, state} <- check_rate_limit(state, rule, config, payload, project_id) do
      {state, notify(rule, type, payload, project_id, config, opts)}
    else
      {:skip, reason} -> {state, {:skipped, reason}}
      {:error, reason} -> {state, {:error, reason}}
    end
  end

  defp count(state, {:skipped, :unmapped}), do: state

  defp count(%{stats: stats} = state, {:notified, _id}),
    do: %{state | stats: %{stats | notified: stats.notified + 1}}

  defp count(%{stats: stats} = state, {:skipped, reason}),
    do: %{state | stats: %{stats | skipped: Map.update(stats.skipped, reason, 1, &(&1 + 1))}}

  defp count(%{stats: stats} = state, {:error, reason}),
    do: %{state | stats: %{stats | errors: stats.errors + 1, last_error: reason}}

  defp lookup(state, type, payload) do
    case Mapping.lookup(state.rules, type, payload) do
      {:ok, rule} -> {:ok, rule}
      :ignore -> {:skip, :unmapped}
    end
  end

  # -- preference ------------------------------------------------------------

  # An event that names no project at all (a standalone jobsite: `JobsiteStarted.project_id` is
  # nullable) has nothing to resolve, so the default applies. An event that names a project the
  # projection does not know is a dangling reference: that project can neither have opted out nor
  # be asked, so the event is skipped and counted, never delivered under the default that exists
  # for "no preference set" (AGENTS.md 5.3, absent is not malformed).
  defp preference(nil), do: {:ok, @default_preference}

  defp preference(project_id) do
    case ProjectionStore.project_settings(project_id) do
      %ProjectSettings{notification_preference: pref} when is_binary(pref) ->
        {:ok, pref}

      %ProjectSettings{notification_preference: nil} ->
        {:ok, @default_preference}

      nil ->
        Logger.warning("notifier: event names project #{project_id}, which is not known; skipped")
        {:skip, :project_unresolved}
    end
  end

  defp check_preference("off", _level), do: {:skip, :preference}
  defp check_preference("blocked_only", :progress), do: {:skip, :preference}
  defp check_preference(_preference, _level), do: :ok

  # `every_turn` must be able to deliver `run_update` even when the global
  # `event_classes` omits it, so it widens the resolved classes for this call.
  defp messaging_opts("every_turn") do
    classes =
      case ConfigResolver.resolve() do
        {:ok, %Config{event_classes: classes}} -> classes
        {:error, _} -> []
      end

    [project_config: %{messaging: %{event_classes: Enum.uniq(classes ++ [:run_update])}}]
  end

  defp messaging_opts(_preference), do: []

  defp resolve_config(opts) do
    case ConfigResolver.resolve(opts) do
      {:ok, %Config{} = config} -> {:ok, config}
      {:error, reason} -> {:error, {:messaging_config, Redactor.redact(reason)}}
    end
  end

  defp check_enabled(%Config{} = config, class) do
    if ConfigResolver.enabled_for?(config, class), do: :ok, else: {:skip, :messaging_disabled}
  end

  # -- subject ---------------------------------------------------------------

  # A PR fix thread's jobsite finishing is not a thread finishing: the fix's
  # outcome reaches the operator through the PR's own events (`PrChecksChanged`,
  # `PrFixExhausted`), and a row for it would announce every fix attempt. The
  # watched PR records the jobsite it has in flight, which is what identifies
  # one; a completion that beats that record (a jobsite that ends before
  # `PrFixStarted` lands) is announced, never silently dropped.
  defp check_subject("JobsiteCompleted", payload) do
    if pr_fix_jobsite?(string_field(payload, "jobsite_id")),
      do: {:skip, :pr_fix_jobsite},
      else: :ok
  end

  defp check_subject(_type, _payload), do: :ok

  defp pr_fix_jobsite?(nil), do: false

  defp pr_fix_jobsite?(jobsite_id) do
    Enum.any?(ProjectionStore.watched_prs(), &(get_in(&1, [:fix, :in_flight]) == jobsite_id))
  end

  # -- rate limit ------------------------------------------------------------

  defp check_rate_limit(state, %Rule{class: :run_update}, config, payload, project_id) do
    now = state.clock.()
    window = config.run_update_rate_limit_ms
    key = rate_key(payload, project_id)
    last = Map.get(state.last_run_update, key)

    if is_integer(last) and now - last < window do
      {:skip, :rate_limited}
    else
      fresh = Map.reject(state.last_run_update, fn {_key, at} -> now - at >= window end)
      {:ok, %{state | last_run_update: Map.put(fresh, key, now)}}
    end
  end

  defp check_rate_limit(state, _rule, _config, _payload, _project_id), do: {:ok, state}

  defp rate_key(payload, project_id) do
    Rule.field_value(payload, "run_id") || Rule.field_value(payload, "subject_id") ||
      Rule.field_value(payload, "jobsite_id") || project_id || "global"
  end

  # -- notify ----------------------------------------------------------------

  defp notify(rule, type, payload, project_id, config, opts) do
    attrs = %{
      provider: config.provider,
      recipient: @recipient,
      event_class: rule.class,
      severity: rule.severity,
      subject: rule.subject,
      body: body(rule, payload),
      url: url(rule, payload),
      correlation_id: correlation_id(rule, type, payload),
      run_id: string_field(payload, "run_id"),
      metadata:
        Map.reject(
          %{run_id: string_field(payload, "run_id"), project_id: project_id},
          fn {_key, value} -> is_nil(value) end
        )
    }

    case Messaging.notify(attrs, opts) do
      {:ok, notification_id} -> {:notified, notification_id}
      {:error, reason} -> {:error, Redactor.redact(reason)}
    end
  end

  defp body(rule, payload) do
    lines =
      for field <- rule.body_fields,
          text = string_field(payload, field),
          not is_nil(text),
          do: "#{field}: #{text}"

    case lines do
      [] -> rule.subject
      lines -> lines |> Enum.join("\n") |> Redactor.redact()
    end
  end

  defp url(%Rule{url_field: nil}, _payload), do: nil
  defp url(%Rule{url_field: field}, payload), do: string_field(payload, field)

  # The correlation id is part of the notification stream id, so it is a fixed
  # width digest, never raw event text.
  defp correlation_id(rule, type, payload) do
    parts = Enum.map(rule.key_fields, &key_part(payload, &1))

    parts =
      if Enum.any?(parts, &is_nil/1),
        do: [:erlang.term_to_binary(Enum.sort(Map.to_list(payload)))],
        else: parts

    digest =
      :crypto.hash(:sha256, Enum.intersperse([type | parts], <<0>>))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    "notifier:" <> digest
  end

  defp key_part(payload, field) do
    case Rule.field_value(payload, field) do
      nil -> nil
      value when is_binary(value) -> value
      value -> inspect(value)
    end
  end

  defp string_field(payload, field) do
    case Rule.field_value(payload, field) do
      nil -> nil
      value when is_binary(value) and value != "" -> truncate(value)
      value when is_integer(value) or is_atom(value) -> truncate(to_string(value))
      _ -> nil
    end
  end

  defp truncate(text) do
    if String.length(text) > @max_field_chars,
      do: String.slice(text, 0, @max_field_chars) <> "...",
      else: text
  end

  # -- event plumbing ----------------------------------------------------------

  # A project id is on most payloads; failures from jobsites and some approval
  # events carry only a run or jobsite id, which the projections resolve.
  defp project_id(payload) do
    string_field(payload, "project_id") || run_project(string_field(payload, "run_id")) ||
      jobsite_project(string_field(payload, "jobsite_id"))
  end

  defp run_project(nil), do: nil

  defp run_project(run_id) do
    case ProjectionStore.run(run_id) do
      %{project_id: project_id} when is_binary(project_id) -> project_id
      _ -> nil
    end
  end

  defp jobsite_project(nil), do: nil

  defp jobsite_project(jobsite_id) do
    case ProjectionStore.jobsite(jobsite_id) do
      %{project_id: project_id} when is_binary(project_id) -> project_id
      _ -> nil
    end
  end

  defp event_parts(%{event_type: type, data: data}) when is_binary(type) and is_map(data),
    do: {type, data}

  defp event_parts(%{event_type: type, payload: data}) when is_binary(type) and is_map(data),
    do: {type, data}

  defp event_parts(_event), do: :error

  defp log_outcome(_type, {:skipped, _reason}), do: :ok

  defp log_outcome(type, {:notified, id}),
    do: Logger.debug("notifier: #{type} -> #{id}")

  defp log_outcome(type, {:error, reason}),
    do: Logger.warning("notifier: #{type} not notified: #{inspect(reason)}")
end
