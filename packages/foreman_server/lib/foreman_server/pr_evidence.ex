defmodule ForemanServer.PrEvidence do
  @moduledoc """
  The `evidence` sub-record of a watched PR and the one fold that maintains it.

  `Aggregates.Run.PrWatch.apply_event/3` (the aggregate) and `ForemanServer.PrWatchFold`
  (the projection) both call `apply_event/3` first, so the two records cannot disagree.
  The record is a map with the keys `checks`, `waiver`, `delivery_issue`, `findings`, `risk`
  and `report`; a record with no `evidence` reads as empty. This module fills `checks` and
  `waiver`; the other keys belong to later tasks and are only kept here.

    * `checks` - `%{head_sha, items, truncated, observed_at, digest, evidence_digest,
      observation_ref, required, policy_version}`, stored for a `PrChecksChanged` whose `checks`
      is a list and left as it was for one that has none or a non-list.
    * `waiver` - `%{head_sha, codes, policy_version, reason, waived_by, waived_at}`, `codes` a
      sorted, de-duplicated list of strings; set by `PrEvidenceWaived` and replacing any earlier one.

  Head reset: of the PR events only `PrUpdated`, `PrReady`, `PrChecksChanged` and
  `PrReviewChanged` carry a head. When one brings a `head_sha` different from the record's
  non-nil one, the current-head observation (`checks_state`, `checks_digest`, `review_decision`,
  `review_digest`, and `failing` where the record has it) is reset first, and the waiver is
  voided unless it is for the head the event brings. The evidence records stay, each with the
  `head_sha` it was recorded for: readers compare that head with the head being decided.

  Never raises: this runs inside `ProjectionStore.init/1`'s replay. Payload keys are read as
  atoms (live) or strings (replayed).
  """

  @head_events ~w(PrUpdated PrReady PrChecksChanged PrReviewChanged)
  @events @head_events ++ ["PrEvidenceWaived"]

  @max_checks 100
  @max_required 20
  @max_text 200

  @kinds ~w(check_run status_context)
  @states ~w(passing failing pending)

  @observation_resets [
    checks_state: nil,
    checks_digest: nil,
    review_decision: nil,
    review_digest: nil,
    failing: []
  ]

  @type t :: %{
          checks: map() | nil,
          waiver: map() | nil,
          delivery_issue: map() | nil,
          findings: map() | nil,
          risk: map() | nil,
          report: map() | nil
        }

  @doc "Event types this fold consumes."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "The empty evidence record."
  @spec empty() :: t()
  def empty,
    do: %{checks: nil, waiver: nil, delivery_issue: nil, findings: nil, risk: nil, report: nil}

  @doc """
  Fold one event into a watch `record` (aggregate or projection): the head reset, then the
  evidence the event carries. Any other event, or a malformed payload, returns `record`
  with at least an `evidence` key.
  """
  @spec apply_event(map(), String.t(), term()) :: map()
  def apply_event(record, type, payload) when is_map(record) and is_map(payload) do
    record = Map.put(record, :evidence, Map.merge(empty(), evidence_of(record)))

    record
    |> reset_on_head_move(type, payload)
    |> apply_evidence(type, payload)
  end

  def apply_event(record, _type, _payload) when is_map(record),
    do: Map.put(record, :evidence, Map.merge(empty(), evidence_of(record)))

  defp evidence_of(%{evidence: %{} = evidence}), do: evidence
  defp evidence_of(_record), do: %{}

  # -- head reset --------------------------------------------------------------

  defp reset_on_head_move(record, type, payload) when type in @head_events do
    head = get(payload, :head_sha)
    current = Map.get(record, :head_sha)

    if present?(head) and present?(current) and head != current do
      record
      |> reset_observation()
      |> void_waiver_unless_for(head)
    else
      record
    end
  end

  defp reset_on_head_move(record, _type, _payload), do: record

  defp reset_observation(record) do
    Enum.reduce(@observation_resets, record, fn {key, empty}, acc ->
      if Map.has_key?(acc, key), do: Map.put(acc, key, empty), else: acc
    end)
  end

  defp void_waiver_unless_for(record, head) do
    case record.evidence.waiver do
      %{head_sha: ^head} -> record
      _other -> put_evidence(record, :waiver, nil)
    end
  end

  # -- evidence ----------------------------------------------------------------

  defp apply_evidence(record, "PrChecksChanged", payload) do
    case get(payload, :checks) do
      items when is_list(items) ->
        put_evidence(record, :checks, %{
          head_sha: get(payload, :head_sha),
          items: items,
          truncated: get(payload, :checks_truncated) == true,
          observed_at: get(payload, :observed_at),
          digest: get(payload, :digest),
          evidence_digest: get(payload, :evidence_digest),
          observation_ref: get(payload, :observation_ref),
          required: get(payload, :required),
          policy_version: get(payload, :policy_version)
        })

      _none_or_not_a_list ->
        record
    end
  end

  defp apply_evidence(record, "PrEvidenceWaived", payload) do
    put_evidence(record, :waiver, %{
      head_sha: get(payload, :head_sha),
      codes: codes(get(payload, :reasons)),
      policy_version: get(payload, :policy_version),
      reason: get(payload, :reason),
      waived_by: get(payload, :approver_identity),
      waived_at: get(payload, :waived_at)
    })
  end

  defp apply_evidence(record, _type, _payload), do: record

  defp put_evidence(record, key, value),
    do: %{record | evidence: Map.put(record.evidence, key, value)}

  defp codes(reasons) when is_list(reasons),
    do: reasons |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort()

  defp codes(_other), do: []

  # -- command validation (shared with the handlers that record evidence) -------

  @doc """
  Validate and normalise the `checks` of a `run.pr.checks` command: a list of at most 100
  items, each a string-keyed map with `name`, `kind` (`check_run | status_context`), `state`
  (`passing | failing | pending`), `conclusion`, `workflow`, `started_at`, `completed_at`, text
  bounded. Atom or string keys and atom or string `kind`/`state` are accepted; the result is
  one string-keyed form, so the live and the replayed fold read identical values.
  """
  @spec validate_checks(term()) :: {:ok, [map()]} | :error
  def validate_checks(checks) when is_list(checks) and length(checks) <= @max_checks do
    each_ok(checks, &check/1)
  end

  def validate_checks(_other), do: :error

  @doc """
  Validate `required`: `nil` or a list of at most 20 entries, each a map with a `name` and a
  `kind`; returned string-keyed with the text bounded.
  """
  @spec validate_required(term()) :: {:ok, [map()] | nil} | :error
  def validate_required(nil), do: {:ok, nil}

  def validate_required(required) when is_list(required) and length(required) <= @max_required do
    each_ok(required, fn entry ->
      with true <- is_map(entry),
           {:ok, name} <- text(get(entry, :name), required: true),
           {:ok, kind} <- text(get(entry, :kind), required: true) do
        {:ok, %{"name" => name, "kind" => kind}}
      else
        _ -> :error
      end
    end)
  end

  def validate_required(_other), do: :error

  @doc "A bounded string or `nil`."
  @spec validate_text(term()) :: {:ok, String.t() | nil} | :error
  def validate_text(value), do: text(value, required: false)

  defp check(item) when is_map(item) do
    with {:ok, name} <- text(get(item, :name), required: true),
         {:ok, kind} <- enum(get(item, :kind), @kinds),
         {:ok, state} <- enum(get(item, :state), @states),
         {:ok, conclusion} <- text(get(item, :conclusion), required: false),
         {:ok, workflow} <- text(get(item, :workflow), required: false),
         {:ok, started_at} <- text(get(item, :started_at), required: false),
         {:ok, completed_at} <- text(get(item, :completed_at), required: false) do
      {:ok,
       %{
         "name" => name,
         "kind" => kind,
         "state" => state,
         "conclusion" => conclusion,
         "workflow" => workflow,
         "started_at" => started_at,
         "completed_at" => completed_at
       }}
    end
  end

  defp check(_other), do: :error

  defp enum(value, allowed) when is_atom(value) and not is_nil(value),
    do: enum(Atom.to_string(value), allowed)

  defp enum(value, allowed) when is_binary(value),
    do: if(value in allowed, do: {:ok, value}, else: :error)

  defp enum(_value, _allowed), do: :error

  defp text(nil, required: false), do: {:ok, nil}

  defp text(value, _opts) when is_binary(value) and byte_size(value) > 0 do
    if String.valid?(value), do: {:ok, String.slice(value, 0, @max_text)}, else: :error
  end

  defp text("", required: false), do: {:ok, nil}
  defp text(_value, _opts), do: :error

  defp each_ok(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        _error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      :error -> :error
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get(_other, _key), do: nil
end
