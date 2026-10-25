defmodule ForemanServer.Schedule.Spec do
  @moduledoc """
  Pure, validated schedule specification and its slot arithmetic.

  A spec is either an **interval** (`%{"every" => "30m"}`) or a standard
  5-field **cron** expression (`%{"cron" => "0 9 * * 1-5"}`), plus an optional
  `timezone` and (interval only) an ISO-8601 `anchor`.

  ## Slots

  A *slot* is one scheduled instant, expressed as integer **unix seconds** so
  it can be embedded in deterministic command ids. Nothing in this module reads
  a clock: every function takes `now`/`from` explicitly.

    * `next_after/2` - the first slot strictly after an instant.
    * `latest_slot_at_or_before/3` - the single greatest slot in
      `(after_slot, now]`. Asking for ONE slot is the collapse-missed-slots
      primitive: a long outage yields one candidate, never a burst.
    * `missed_count/4` - how many slots fall in `(after_slot, now]`, for
      visibility on skipped-fire events only.

  ## Interval grammar

  `\\A(\\d+)([smhd])\\z`, positive, at least
  `config :foreman_server, :schedule, min_interval_seconds:` (default 300).
  Slots are `anchor + k * every` (`k >= 0`) and are computed arithmetically,
  never by iteration. Without an anchor, slots align to the Unix epoch; the
  `Schedule` aggregate always stores creation time as the anchor.

  ## Cron grammar

  Five whitespace-separated fields: minute hour day-of-month month day-of-week.
  Per field: `*`, a value, a list `a,b`, a range `a-b`, and steps `*/n` or
  `a-b/n`. Months accept `JAN-DEC` and weekdays `SUN-SAT` (case-insensitive);
  day-of-week `7` is Sunday. When BOTH day-of-month and day-of-week are
  restricted (do not start with `*`) a day matches if EITHER matches (Vixie
  cron). Everything else (`@daily`, `?`, `L`, `W`, `#`, a seconds field) is
  rejected with `reason: :unsupported_syntax`; expressions that can never fire
  (`0 0 30 2 *`) are rejected with `:never_fires`.

  ## Timezones

  UTC only. There is no tz database in the dependency set (see the
  documentation of the `:timezone` key). `"UTC"` and `"Etc/UTC"` are accepted
  and normalised to `"UTC"`; any other zone is
  `{:invalid_schedule_spec, :timezone, :unsupported_timezone}`. Cron times are
  therefore UTC wall-clock times and there is no DST behaviour to define.

  ## Why not `Crontab`

  `crontab` 1.2.0 is a transitive dependency, evaluated and not adopted: it
  ANDs day-of-month with day-of-week (Vixie ORs them), accepts a larger syntax
  (`@daily`, `L`, `W`, seconds) that Foreman must reject, and works on
  `NaiveDateTime`. Wrapping it would need the same field parsing and validation
  written here plus a second implementation of next-run search.
  """

  @enforce_keys [:kind]
  defstruct [:kind, :every_seconds, :anchor, :cron, :cron_fields, timezone: "UTC"]

  @type cron_fields :: %{
          minute: MapSet.t(non_neg_integer()),
          hour: MapSet.t(non_neg_integer()),
          dom: MapSet.t(pos_integer()),
          month: MapSet.t(pos_integer()),
          dow: MapSet.t(non_neg_integer()),
          dom_restricted?: boolean(),
          dow_restricted?: boolean()
        }

  @type t :: %__MODULE__{
          kind: :interval | :cron,
          every_seconds: pos_integer() | nil,
          anchor: DateTime.t() | nil,
          cron: String.t() | nil,
          cron_fields: cron_fields() | nil,
          timezone: String.t()
        }

  @type reason ::
          :not_a_map
          | {:unknown_field, String.t()}
          | :required
          | :exclusive
          | :invalid_type
          | :invalid_format
          | :below_minimum
          | :above_maximum
          | :wrong_field_count
          | :empty_field
          | :invalid_value
          | :out_of_range
          | :reversed_range
          | :zero_step
          | :unsupported_syntax
          | :never_fires
          | :not_applicable
          | :unsupported_timezone

  @type parse_error :: {:invalid_schedule_spec, atom(), reason()}

  @known_keys ~w(every cron anchor timezone)
  @default_min_interval 300
  @search_days 9 * 366
  @latest_window_days 366
  @unit_seconds %{"s" => 1, "m" => 60, "h" => 3_600, "d" => 86_400}
  # An interval longer than a leap year keeps `anchor + k * every` far below the
  # year-9999 limit of `DateTime.from_unix!/1`.
  @max_interval_seconds 366 * 86_400
  @months ~w(JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC)
  @weekdays ~w(SUN MON TUE WED THU FRI SAT)
  @cron_ranges [
    {:minute, 0, 59},
    {:hour, 0, 23},
    {:dom, 1, 31},
    {:month, 1, 12},
    {:dow, 0, 7}
  ]

  # ---------------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------------

  @doc """
  Parse user input (string- or atom-keyed) into a normalised spec.

  Options: `:default_anchor` (`DateTime`) is used for an interval spec that
  carries no `anchor`.

  Raises `ArgumentError` when the same key is present as both an atom and a
  string (an ambiguous caller bug, not user input).
  """
  @spec parse(term(), keyword()) :: {:ok, t()} | {:error, parse_error()}
  def parse(input, opts \\ [])

  def parse(input, opts) when is_map(input) do
    with :ok <- reject_unknown_keys(input),
         every = fetch(input, "every"),
         cron = fetch(input, "cron"),
         {:ok, tz} <- parse_timezone(fetch(input, "timezone")) do
      case {every, cron} do
        {nil, nil} -> error(:every, :required)
        {_, nil} -> parse_interval(every, fetch(input, "anchor"), tz, opts)
        {nil, _} -> parse_cron_spec(cron, fetch(input, "anchor"), tz)
        {_, _} -> error(:cron, :exclusive)
      end
    end
  end

  def parse(_input, _opts), do: error(:spec, :not_a_map)

  @doc """
  Normalised public form stored on events: string keys and string values.
  `parse(to_map(spec))` rebuilds an identical spec.
  """
  @spec to_map(t()) :: %{String.t() => String.t()}
  def to_map(%__MODULE__{kind: :interval} = spec) do
    base = %{"every" => format_every(spec.every_seconds), "timezone" => spec.timezone}

    case spec.anchor do
      nil -> base
      %DateTime{} = anchor -> Map.put(base, "anchor", DateTime.to_iso8601(anchor))
    end
  end

  def to_map(%__MODULE__{kind: :cron} = spec),
    do: %{"cron" => spec.cron, "timezone" => spec.timezone}

  defp fetch(input, key) do
    atom_key = String.to_existing_atom(key)

    case {Map.fetch(input, key), Map.fetch(input, atom_key)} do
      {{:ok, a}, {:ok, b}} when a != b ->
        raise ArgumentError,
              "conflicting values for schedule spec key #{inspect(key)} (atom and string)"

      {{:ok, value}, _} ->
        value

      {_, {:ok, value}} ->
        value

      _ ->
        nil
    end
  end

  defp reject_unknown_keys(input) do
    unknown =
      input
      |> Map.keys()
      |> Enum.map(&key_to_string/1)
      |> Enum.reject(&(&1 in @known_keys))

    case unknown do
      [] -> :ok
      [first | _] -> {:error, {:invalid_schedule_spec, :spec, {:unknown_field, first}}}
    end
  end

  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key), do: inspect(key)

  defp parse_timezone(nil), do: {:ok, "UTC"}

  defp parse_timezone(tz) when is_binary(tz) do
    if String.downcase(String.trim(tz)) in ["utc", "etc/utc"],
      do: {:ok, "UTC"},
      else: error(:timezone, :unsupported_timezone)
  end

  defp parse_timezone(_), do: error(:timezone, :invalid_type)

  defp parse_interval(every, anchor, tz, opts) when is_binary(every) do
    with {:ok, seconds} <- parse_every(every),
         {:ok, anchor} <- parse_anchor(anchor, Keyword.get(opts, :default_anchor)) do
      {:ok, %__MODULE__{kind: :interval, every_seconds: seconds, anchor: anchor, timezone: tz}}
    end
  end

  defp parse_interval(_every, _anchor, _tz, _opts), do: error(:every, :invalid_type)

  defp parse_every(every) do
    case Regex.run(~r/\A(\d+)([smhd])\z/, String.trim(every)) do
      [_, digits, unit] ->
        seconds = String.to_integer(digits) * Map.fetch!(@unit_seconds, unit)

        cond do
          seconds <= 0 -> error(:every, :invalid_format)
          seconds < min_interval_seconds() -> error(:every, :below_minimum)
          seconds > @max_interval_seconds -> error(:every, :above_maximum)
          true -> {:ok, seconds}
        end

      _ ->
        error(:every, :invalid_format)
    end
  end

  defp parse_anchor(nil, nil), do: {:ok, nil}
  defp parse_anchor(nil, %DateTime{} = default), do: {:ok, normalise_anchor(default)}

  defp parse_anchor(%DateTime{} = anchor, _default), do: {:ok, normalise_anchor(anchor)}

  defp parse_anchor(anchor, _default) when is_binary(anchor) do
    case DateTime.from_iso8601(anchor) do
      {:ok, dt, _offset} -> {:ok, normalise_anchor(dt)}
      {:error, _} -> error(:anchor, :invalid_format)
    end
  end

  defp parse_anchor(_anchor, _default), do: error(:anchor, :invalid_type)

  # Whole seconds, UTC: the stored form must round-trip exactly.
  defp normalise_anchor(%DateTime{} = dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
  end

  defp parse_cron_spec(cron, anchor, tz) when is_binary(cron) do
    cond do
      anchor != nil ->
        error(:anchor, :not_applicable)

      true ->
        with {:ok, normalised, fields} <- parse_cron(cron) do
          {:ok, %__MODULE__{kind: :cron, cron: normalised, cron_fields: fields, timezone: tz}}
        end
    end
  end

  defp parse_cron_spec(_cron, _anchor, _tz), do: error(:cron, :invalid_type)

  defp parse_cron(cron) do
    trimmed = String.trim(cron)

    cond do
      trimmed == "" -> error(:cron, :required)
      String.starts_with?(trimmed, "@") -> error(:cron, :unsupported_syntax)
      true -> parse_cron_fields(String.split(trimmed, ~r/\s+/))
    end
  end

  defp parse_cron_fields(parts) when length(parts) != 5 do
    if Enum.any?(parts, &unsupported_token?/1),
      do: error(:cron, :unsupported_syntax),
      else: error(:cron, :wrong_field_count)
  end

  defp parse_cron_fields(parts) do
    results =
      parts
      |> Enum.zip(@cron_ranges)
      |> Enum.map(fn {text, {name, min, max}} ->
        {name, text, parse_field(name, text, min, max)}
      end)

    case Enum.find(results, fn {_, _, r} -> match?({:error, _}, r) end) do
      {_, _, {:error, reason}} ->
        error(:cron, reason)

      nil ->
        sets = Map.new(results, fn {name, _text, {:ok, set}} -> {name, set} end)
        [_, _, dom_text, _, dow_text] = Enum.map(results, fn {_, text, _} -> text end)

        fields = %{
          minute: sets.minute,
          hour: sets.hour,
          dom: sets.dom,
          month: sets.month,
          dow: normalise_dow(sets.dow),
          dom_restricted?: not String.starts_with?(dom_text, "*"),
          dow_restricted?: not String.starts_with?(dow_text, "*")
        }

        normalised =
          Enum.map_join(results, " ", fn {name, text, _} -> normalise_text(name, text) end)

        if satisfiable?(fields),
          do: {:ok, normalised, fields},
          else: error(:cron, :never_fires)
    end
  end

  defp unsupported_token?(token),
    do: String.match?(token, ~r/[?#@]|\d[LlWw]\z|\A[LlWw]\z/)

  defp parse_field(name, text, min, max) do
    cond do
      text == "" ->
        {:error, :empty_field}

      String.match?(text, ~r/[?#@]/) ->
        {:error, :unsupported_syntax}

      true ->
        text
        |> String.split(",")
        |> Enum.reduce_while({:ok, MapSet.new()}, fn item, {:ok, acc} ->
          case parse_item(name, item, min, max) do
            {:ok, values} -> {:cont, {:ok, MapSet.union(acc, values)}}
            {:error, _} = err -> {:halt, err}
          end
        end)
    end
  end

  defp parse_item(_name, "", _min, _max), do: {:error, :empty_field}

  defp parse_item(name, item, min, max) do
    case String.split(item, "/") do
      [range] -> parse_range(name, range, min, max, 1)
      [range, step] -> parse_stepped(name, range, step, min, max)
      _ -> {:error, :invalid_value}
    end
  end

  defp parse_stepped(name, range, step, min, max) do
    with {:ok, n} <- parse_number(step, :invalid_value),
         true <- n > 0 or {:error, :zero_step} do
      # A step needs a range or `*`: `5/15` is vendor syntax, not accepted.
      if range == "*" or String.contains?(range, "-"),
        do: parse_range(name, range, min, max, n),
        else: {:error, :unsupported_syntax}
    end
  end

  defp parse_range(_name, "*", min, max, step), do: {:ok, MapSet.new(min..max//step)}

  defp parse_range(name, range, min, max, step) do
    case String.split(range, "-") do
      [single] ->
        with {:ok, v} <- parse_value(name, single, min, max), do: {:ok, MapSet.new([v])}

      [lo, hi] ->
        with {:ok, a} <- parse_value(name, lo, min, max),
             {:ok, b} <- parse_value(name, hi, min, max) do
          if a > b, do: {:error, :reversed_range}, else: {:ok, MapSet.new(a..b//step)}
        end

      _ ->
        {:error, :invalid_value}
    end
  end

  defp parse_value(name, text, min, max) do
    with {:ok, n} <- resolve_value(name, text) do
      if n < min or n > max, do: {:error, :out_of_range}, else: {:ok, n}
    end
  end

  defp resolve_value(:month, text) do
    case Enum.find_index(@months, &(&1 == String.upcase(text))) do
      nil -> parse_number(text, :invalid_value)
      index -> {:ok, index + 1}
    end
  end

  defp resolve_value(:dow, text) do
    case Enum.find_index(@weekdays, &(&1 == String.upcase(text))) do
      nil -> parse_number(text, :invalid_value)
      index -> {:ok, index}
    end
  end

  defp resolve_value(_name, text) do
    if String.match?(text, ~r/\A[A-Za-z]+\z/) and not String.match?(text, ~r/\A[LlWw]\z/),
      do: {:error, :invalid_value},
      else: parse_number(text, :invalid_value)
  end

  defp parse_number(text, reason) do
    case Regex.run(~r/\A\d+\z/, text) do
      [_] ->
        {:ok, String.to_integer(text)}

      _ ->
        if text =~ ~r/\A(\d+)?[LlWw]\z/,
          do: {:error, :unsupported_syntax},
          else: {:error, reason}
    end
  end

  defp normalise_dow(set), do: set |> Enum.map(&rem(&1, 7)) |> MapSet.new()

  # Names become numbers so equal schedules have one stored form.
  defp normalise_text(name, text) when name in [:month, :dow] do
    Regex.replace(~r/[A-Za-z]{3}/, text, fn name_text ->
      table = if name == :month, do: @months, else: @weekdays
      base = if name == :month, do: 1, else: 0

      case Enum.find_index(table, &(&1 == String.upcase(name_text))) do
        nil -> name_text
        index -> Integer.to_string(index + base)
      end
    end)
  end

  defp normalise_text(_name, text), do: text

  # A day-of-month-only expression needs some month that has that day.
  defp satisfiable?(%{dom_restricted?: true, dow_restricted?: false} = fields) do
    Enum.any?(fields.month, fn month ->
      Enum.any?(fields.dom, &(&1 <= days_in_month(2024, month)))
    end)
  end

  defp satisfiable?(_fields), do: true

  defp min_interval_seconds do
    :foreman_server
    |> Application.get_env(:schedule, [])
    |> Keyword.get(:min_interval_seconds, @default_min_interval)
  end

  defp error(field, reason), do: {:error, {:invalid_schedule_spec, field, reason}}

  defp format_every(seconds) do
    cond do
      rem(seconds, 86_400) == 0 -> "#{div(seconds, 86_400)}d"
      rem(seconds, 3_600) == 0 -> "#{div(seconds, 3_600)}h"
      rem(seconds, 60) == 0 -> "#{div(seconds, 60)}m"
      true -> "#{seconds}s"
    end
  end

  # ---------------------------------------------------------------------------
  # Slots
  # ---------------------------------------------------------------------------

  @doc """
  First slot strictly after `from`.

  `{:error, :no_next_slot}` only for a cron expression with no match inside the
  search horizon (about nine years); `parse/2` rejects expressions that can
  never fire, so this is not expected for stored specs.
  """
  @spec next_after(t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, :no_next_slot}
  def next_after(%__MODULE__{kind: :interval} = spec, %DateTime{} = from) do
    from_unix = DateTime.to_unix(from)
    anchor = anchor_unix(spec)
    every = spec.every_seconds

    k = if from_unix < anchor, do: 0, else: div(from_unix - anchor, every) + 1
    {:ok, DateTime.from_unix!(anchor + k * every)}
  end

  def next_after(%__MODULE__{kind: :cron} = spec, %DateTime{} = from) do
    start = div(DateTime.to_unix(from), 60) * 60 + 60
    first_day = start |> DateTime.from_unix!() |> DateTime.to_date()
    start_minute = rem(div(start, 60), 1440)

    Enum.find_value(0..@search_days, {:error, :no_next_slot}, fn offset ->
      date = Date.add(first_day, offset)
      from_minute = if offset == 0, do: start_minute, else: 0

      with true <- day_matches?(spec.cron_fields, date),
           {:ok, minute_of_day} <- first_minute_at_or_after(spec.cron_fields, from_minute) do
        {:ok, slot_datetime(date, minute_of_day)}
      else
        _ -> nil
      end
    end)
  end

  @doc """
  The greatest slot `s` with `after_slot < s <= now`, or `:none`.

  Exactly one slot is ever returned. `after_slot` is unix seconds or `nil`
  (no lower bound; interval slots still start at the anchor). A cron spec is
  searched back at most 366 days; a schedule that has not matched in a year is
  effectively never.
  """
  @spec latest_slot_at_or_before(t(), DateTime.t(), integer() | nil) ::
          {:ok, integer()} | :none
  def latest_slot_at_or_before(%__MODULE__{kind: :interval} = spec, %DateTime{} = now, after_slot) do
    now_unix = DateTime.to_unix(now)
    anchor = anchor_unix(spec)
    every = spec.every_seconds

    if now_unix < anchor do
      :none
    else
      slot = anchor + div(now_unix - anchor, every) * every
      if is_nil(after_slot) or slot > after_slot, do: {:ok, slot}, else: :none
    end
  end

  def latest_slot_at_or_before(%__MODULE__{kind: :cron} = spec, %DateTime{} = now, after_slot) do
    now_minute_unix = div(DateTime.to_unix(now), 60) * 60
    last_day = now |> DateTime.to_date()
    now_minute = rem(div(now_minute_unix, 60), 1440)

    Enum.find_value(0..@latest_window_days, :none, fn offset ->
      date = Date.add(last_day, -offset)
      to_minute = if offset == 0, do: now_minute, else: 1439

      with true <- day_matches?(spec.cron_fields, date),
           {:ok, minute_of_day} <- last_minute_at_or_before(spec.cron_fields, to_minute) do
        slot = date |> slot_datetime(minute_of_day) |> DateTime.to_unix()
        # The greatest candidate is at or below the lower bound: nothing is due.
        if is_nil(after_slot) or slot > after_slot, do: {:ok, slot}, else: {:halt, :none}
      else
        _ -> nil
      end
    end)
    |> case do
      {:halt, :none} -> :none
      other -> other
    end
  end

  @doc """
  Number of slots in `(after_slot, now]`, counted up to `cap`. Visibility only:
  the planner never iterates these slots.
  """
  @spec missed_count(t(), integer() | nil, DateTime.t(), pos_integer()) :: non_neg_integer()
  def missed_count(spec, after_slot, now, cap \\ 1000)

  def missed_count(%__MODULE__{kind: :interval} = spec, after_slot, %DateTime{} = now, cap) do
    now_unix = DateTime.to_unix(now)
    anchor = anchor_unix(spec)
    every = spec.every_seconds

    if now_unix < anchor do
      0
    else
      k_max = div(now_unix - anchor, every)

      k_min =
        if is_nil(after_slot) or after_slot < anchor,
          do: 0,
          else: div(after_slot - anchor, every) + 1

      min(max(k_max - k_min + 1, 0), cap)
    end
  end

  def missed_count(%__MODULE__{kind: :cron} = spec, after_slot, %DateTime{} = now, cap) do
    now_unix = DateTime.to_unix(now)
    start = after_slot || now_unix - @latest_window_days * 86_400

    count_cron(spec, start, now_unix, 0, cap)
  end

  defp count_cron(_spec, _from, _now, count, cap) when count >= cap, do: count

  defp count_cron(spec, from_unix, now_unix, count, cap) do
    case next_after(spec, DateTime.from_unix!(from_unix)) do
      {:ok, slot} ->
        slot_unix = DateTime.to_unix(slot)

        if slot_unix <= now_unix,
          do: count_cron(spec, slot_unix, now_unix, count + 1, cap),
          else: count

      {:error, :no_next_slot} ->
        count
    end
  end

  @doc "Unix-seconds slot to UTC `DateTime`."
  @spec slot_to_datetime(integer()) :: DateTime.t()
  def slot_to_datetime(slot) when is_integer(slot), do: DateTime.from_unix!(slot)

  defp anchor_unix(%__MODULE__{anchor: nil}), do: 0
  defp anchor_unix(%__MODULE__{anchor: %DateTime{} = anchor}), do: DateTime.to_unix(anchor)

  defp slot_datetime(date, minute_of_day) do
    DateTime.new!(
      date,
      Time.new!(div(minute_of_day, 60), rem(minute_of_day, 60), 0),
      "Etc/UTC"
    )
  end

  defp day_matches?(fields, %Date{} = date) do
    dom_ok = MapSet.member?(fields.dom, date.day)
    dow_ok = MapSet.member?(fields.dow, rem(Date.day_of_week(date), 7))

    day_ok =
      if fields.dom_restricted? and fields.dow_restricted?,
        do: dom_ok or dow_ok,
        else: dom_ok and dow_ok

    day_ok and MapSet.member?(fields.month, date.month)
  end

  defp first_minute_at_or_after(fields, from_minute) do
    minutes = minutes_of_day(fields)

    case Enum.find(minutes, &(&1 >= from_minute)) do
      nil -> :none
      minute -> {:ok, minute}
    end
  end

  defp last_minute_at_or_before(fields, to_minute) do
    minutes = fields |> minutes_of_day() |> Enum.reverse()

    case Enum.find(minutes, &(&1 <= to_minute)) do
      nil -> :none
      minute -> {:ok, minute}
    end
  end

  defp minutes_of_day(fields) do
    for h <- Enum.sort(fields.hour), m <- Enum.sort(fields.minute), do: h * 60 + m
  end

  defp days_in_month(year, month), do: Date.days_in_month(Date.new!(year, month, 1))
end
