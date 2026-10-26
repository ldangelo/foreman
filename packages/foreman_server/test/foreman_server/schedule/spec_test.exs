defmodule ForemanServer.Schedule.SpecTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  import StreamData, only: [constant: 1, integer: 1, one_of: 1]

  alias ForemanServer.Schedule.Spec

  @anchor "2026-01-01T00:00:00Z"

  defp dt(iso) do
    {:ok, dt, 0} = DateTime.from_iso8601(iso)
    dt
  end

  defp unix(iso), do: iso |> dt() |> DateTime.to_unix()

  defp parse!(input, opts \\ []) do
    assert {:ok, spec} = Spec.parse(input, opts)
    spec
  end

  defp cron!(expr), do: parse!(%{"cron" => expr})

  defp every!(every, anchor \\ @anchor), do: parse!(%{"every" => every, "anchor" => anchor})

  describe "parse/2 interval" do
    test "normalises units and keeps the anchor" do
      assert %Spec{kind: :interval, every_seconds: 1800, anchor: anchor, timezone: "UTC"} =
               every!("30m")

      assert anchor == dt(@anchor)
      assert %Spec{every_seconds: 3_600} = every!("1h")
      assert %Spec{every_seconds: 86_400} = every!("1d")
      assert %Spec{every_seconds: 600} = every!("600s")
    end

    test "round-trips through to_map/1 in the canonical unit" do
      for every <- ~w(30m 1h 2d 600s 90m) do
        spec = every!(every)
        assert {:ok, ^spec} = Spec.parse(Spec.to_map(spec))
      end

      assert %{"every" => "1h"} = every!("60m") |> Spec.to_map()
      assert %{"every" => "90m"} = every!("90m") |> Spec.to_map()
    end

    test "default_anchor fills a missing anchor; an explicit anchor wins" do
      created = dt("2026-03-03T10:20:30Z")
      assert %Spec{anchor: ^created} = parse!(%{"every" => "1h"}, default_anchor: created)

      assert %Spec{anchor: explicit} =
               parse!(%{"every" => "1h", "anchor" => @anchor}, default_anchor: created)

      assert explicit == dt(@anchor)
    end

    test "anchors are normalised to whole-second UTC" do
      assert %Spec{anchor: anchor} = every!("1h", "2026-01-01T05:00:00.789+05:00")
      assert anchor == dt("2026-01-01T00:00:00Z")
    end

    test "typed errors name the field" do
      assert {:error, {:invalid_schedule_spec, :every, :invalid_format}} =
               Spec.parse(%{"every" => "30"})

      assert {:error, {:invalid_schedule_spec, :every, :invalid_format}} =
               Spec.parse(%{"every" => "0m"})

      assert {:error, {:invalid_schedule_spec, :every, :invalid_format}} =
               Spec.parse(%{"every" => "1w"})

      assert {:error, {:invalid_schedule_spec, :every, :invalid_type}} =
               Spec.parse(%{"every" => 30})

      assert {:error, {:invalid_schedule_spec, :anchor, :invalid_format}} =
               Spec.parse(%{"every" => "1h", "anchor" => "yesterday"})
    end

    test "the minimum interval comes from config (default 300 seconds)" do
      assert {:error, {:invalid_schedule_spec, :every, :below_minimum}} =
               Spec.parse(%{"every" => "4m"})

      assert {:error, {:invalid_schedule_spec, :every, :below_minimum}} =
               Spec.parse(%{"every" => "299s"})

      assert {:ok, %Spec{every_seconds: 300}} = Spec.parse(%{"every" => "5m"})

      original = Application.get_env(:foreman_server, :schedule, [])
      on_exit(fn -> Application.put_env(:foreman_server, :schedule, original) end)

      Application.put_env(
        :foreman_server,
        :schedule,
        Keyword.put(original, :min_interval_seconds, 3_600)
      )

      assert {:error, {:invalid_schedule_spec, :every, :below_minimum}} =
               Spec.parse(%{"every" => "30m"})
    end

    test "an interval longer than 366 days is rejected" do
      assert {:ok, %Spec{every_seconds: 31_622_400}} = Spec.parse(%{"every" => "366d"})

      assert {:error, {:invalid_schedule_spec, :every, :above_maximum}} =
               Spec.parse(%{"every" => "367d"})

      assert {:error, {:invalid_schedule_spec, :every, :above_maximum}} =
               Spec.parse(%{"every" => "3000000d"})
    end
  end

  describe "parse/2 shape" do
    test "atom- and string-keyed input are equivalent; conflicting keys raise" do
      assert Spec.parse(%{every: "1h", anchor: @anchor}) ==
               Spec.parse(%{"every" => "1h", "anchor" => @anchor})

      assert Spec.parse(%{"every" => "1h", every: "1h"}) == Spec.parse(%{"every" => "1h"})

      assert_raise ArgumentError, ~r/conflicting values/, fn ->
        Spec.parse(%{"every" => "1h", every: "2h"})
      end
    end

    test "exactly one of every/cron; unknown keys and non-maps are rejected" do
      assert {:error, {:invalid_schedule_spec, :every, :required}} = Spec.parse(%{})

      assert {:error, {:invalid_schedule_spec, :cron, :exclusive}} =
               Spec.parse(%{"every" => "1h", "cron" => "0 * * * *"})

      assert {:error, {:invalid_schedule_spec, :spec, {:unknown_field, "bogus"}}} =
               Spec.parse(%{"every" => "1h", "bogus" => 1})

      assert {:error, {:invalid_schedule_spec, :spec, :not_a_map}} = Spec.parse("0 * * * *")
    end

    test "timezone: UTC spellings normalise, anything else is unsupported" do
      assert %Spec{timezone: "UTC"} = parse!(%{"cron" => "0 * * * *", "timezone" => "Etc/UTC"})
      assert %Spec{timezone: "UTC"} = parse!(%{"cron" => "0 * * * *", "timezone" => "utc"})

      assert {:error, {:invalid_schedule_spec, :timezone, :unsupported_timezone}} =
               Spec.parse(%{"cron" => "0 * * * *", "timezone" => "America/New_York"})

      assert {:error, {:invalid_schedule_spec, :timezone, :invalid_type}} =
               Spec.parse(%{"cron" => "0 * * * *", "timezone" => 5})
    end

    test "anchor is interval-only" do
      assert {:error, {:invalid_schedule_spec, :anchor, :not_applicable}} =
               Spec.parse(%{"cron" => "0 * * * *", "anchor" => @anchor})
    end
  end

  describe "parse/2 cron" do
    test "names normalise to numbers and round-trip" do
      spec = cron!("0 9 * JAN-MAR MON-FRI")
      assert %{"cron" => "0 9 * 1-3 1-5", "timezone" => "UTC"} = Spec.to_map(spec)
      assert {:ok, ^spec} = Spec.parse(Spec.to_map(spec))
      assert cron!("0 9 * * sun").cron_fields.dow == MapSet.new([0])
      assert cron!("0 9 * * 7").cron_fields.dow == MapSet.new([0])
    end

    test "lists, ranges and steps produce the right sets" do
      f = cron!("0,30 */6 1-10/3 1,6 *").cron_fields
      assert f.minute == MapSet.new([0, 30])
      assert f.hour == MapSet.new([0, 6, 12, 18])
      assert f.dom == MapSet.new([1, 4, 7, 10])
      assert f.month == MapSet.new([1, 6])
      assert f.dom_restricted?
      refute f.dow_restricted?
    end

    test "restricted flags follow Vixie: a leading * is unrestricted" do
      f = cron!("0 0 */2 * 1").cron_fields
      refute f.dom_restricted?
      assert f.dow_restricted?
    end

    test "each malformed class returns its own reason" do
      cases = [
        {"61 * * * *", :out_of_range},
        {"* 24 * * *", :out_of_range},
        {"* * 0 * *", :out_of_range},
        {"* * * 13 *", :out_of_range},
        {"* * * * 8", :out_of_range},
        {"5-1 * * * *", :reversed_range},
        {"*/0 * * * *", :zero_step},
        {"*/x * * * *", :invalid_value},
        {"1,,2 * * * *", :empty_field},
        {"abc * * * *", :invalid_value},
        {"* * * * * *", :wrong_field_count},
        {"* * * *", :wrong_field_count},
        {"", :required},
        {"0 0 30 2 *", :never_fires},
        {"0 0 31 4,6,9,11 *", :never_fires}
      ]

      for {expr, reason} <- cases do
        assert {:error, {:invalid_schedule_spec, :cron, ^reason}} = Spec.parse(%{"cron" => expr}),
               "expected #{inspect(reason)} for #{inspect(expr)}"
      end
    end

    test "vendor syntax is rejected explicitly" do
      for expr <- [
            "@daily",
            "@reboot",
            "0 0 L * *",
            "0 0 15W * *",
            "0 0 * * 5#2",
            "? * * * *",
            "0 0 5L * *",
            "5/15 * * * *",
            "0 0 * * 1L"
          ] do
        assert {:error, {:invalid_schedule_spec, :cron, :unsupported_syntax}} =
                 Spec.parse(%{"cron" => expr}),
               "expected unsupported_syntax for #{inspect(expr)}"
      end
    end

    test "Feb 29 is satisfiable (leap years), Feb 30 is not" do
      assert {:ok, _} = Spec.parse(%{"cron" => "0 0 29 2 *"})
    end
  end

  describe "next_after/2" do
    test "weekday cron skips the weekend" do
      spec = cron!("0 9 * * 1-5")
      # 2026-01-02 is a Friday.
      assert {:ok, next} = Spec.next_after(spec, dt("2026-01-02T10:00:00Z"))
      assert next == dt("2026-01-05T09:00:00Z")
      assert Date.day_of_week(DateTime.to_date(next)) == 1
    end

    test "strictly after: an instant exactly on a slot yields the following slot" do
      spec = cron!("*/15 * * * *")
      assert {:ok, ~U[2026-01-01 00:15:00Z]} = Spec.next_after(spec, ~U[2026-01-01 00:00:00Z])
      assert {:ok, ~U[2026-01-01 00:15:00Z]} = Spec.next_after(spec, ~U[2026-01-01 00:14:59Z])
      assert {:ok, ~U[2026-01-01 00:30:00Z]} = Spec.next_after(spec, ~U[2026-01-01 00:15:00Z])
    end

    test "dom and dow both restricted match on EITHER (Vixie OR)" do
      spec = cron!("0 0 13 * 5")
      # Friday 2026-01-02 matches by dow; Tuesday 2026-01-13 matches by dom.
      assert {:ok, ~U[2026-01-02 00:00:00Z]} = Spec.next_after(spec, ~U[2026-01-01 12:00:00Z])
      assert {:ok, ~U[2026-01-09 00:00:00Z]} = Spec.next_after(spec, ~U[2026-01-02 12:00:00Z])
      assert {:ok, ~U[2026-01-13 00:00:00Z]} = Spec.next_after(spec, ~U[2026-01-12 00:00:00Z])
    end

    test "month lengths and leap years" do
      assert {:ok, ~U[2028-02-29 00:00:00Z]} =
               Spec.next_after(cron!("0 0 29 2 *"), ~U[2026-03-01 00:00:00Z])

      # 2100 is not a leap year: from 2096-03 the next Feb 29 is 2104.
      assert {:ok, ~U[2104-02-29 00:00:00Z]} =
               Spec.next_after(cron!("0 0 29 2 *"), ~U[2096-03-01 00:00:00Z])

      assert {:ok, ~U[2026-03-31 00:00:00Z]} =
               Spec.next_after(cron!("0 0 31 * *"), ~U[2026-03-01 00:00:00Z])

      assert {:ok, ~U[2026-05-31 00:00:00Z]} =
               Spec.next_after(cron!("0 0 31 * *"), ~U[2026-04-01 00:00:00Z])
    end

    test "interval slots are anchor-aligned, O(1), and never before the anchor" do
      spec = every!("30m", "2026-01-01T00:10:00Z")
      assert {:ok, ~U[2026-01-01 00:10:00Z]} = Spec.next_after(spec, ~U[2025-06-01 00:00:00Z])
      assert {:ok, ~U[2026-01-01 00:40:00Z]} = Spec.next_after(spec, ~U[2026-01-01 00:10:00Z])
      assert {:ok, ~U[2026-01-01 00:40:00Z]} = Spec.next_after(spec, ~U[2026-01-01 00:39:59Z])
      # Ten years out still answers immediately.
      assert {:ok, next} = Spec.next_after(spec, ~U[2036-01-01 00:00:00Z])
      assert rem(DateTime.to_unix(next) - unix(@anchor) - 600, 1800) == 0
    end

    test "is total: an instant no DateTime can represent is :no_next_slot, never a raise" do
      # `parse/2` caps `every`, but the arithmetic must not lean on that cap: a spec that
      # reached storage under older rules cannot be allowed to crash a read.
      huge = %Spec{kind: :interval, every_seconds: 3_000_000 * 86_400, anchor: dt(@anchor)}
      assert {:error, :no_next_slot} = Spec.next_after(huge, dt("2026-10-25T00:00:00Z"))

      # Before the anchor the answer is the anchor itself, which is representable.
      assert {:ok, anchor} = Spec.next_after(huge, dt("2025-01-01T00:00:00Z"))
      assert anchor == dt(@anchor)

      # Neither kind may raise past the last representable second.
      last = dt("9999-12-31T23:59:59Z")
      assert {:error, :no_next_slot} = Spec.next_after(every!("1h"), last)
      assert {:error, :no_next_slot} = Spec.next_after(cron!("0 9 * * *"), last)
    end
  end

  describe "latest_slot_at_or_before/3" do
    test "interval: exactly one slot, never a burst" do
      spec = every!("1h")
      five_hours_later = unix("2026-01-01T05:00:10Z")

      assert {:ok, slot} =
               Spec.latest_slot_at_or_before(spec, dt("2026-01-01T05:00:10Z"), unix(@anchor))

      assert slot == unix("2026-01-01T05:00:00Z")
      assert slot <= five_hours_later
    end

    test ":none when nothing is due" do
      spec = every!("1h")
      last = unix("2026-01-01T01:00:00Z")
      assert :none = Spec.latest_slot_at_or_before(spec, dt("2026-01-01T01:30:00Z"), last)
      assert :none = Spec.latest_slot_at_or_before(spec, dt("2025-12-31T00:00:00Z"), nil)

      cron = cron!("0 9 * * 1-5")
      friday_slot = unix("2026-01-02T09:00:00Z")
      # Saturday: the Friday fire is the latest slot and it is already processed.
      assert :none = Spec.latest_slot_at_or_before(cron, dt("2026-01-03T12:00:00Z"), friday_slot)
    end

    test "cron: latest slot at or before now, bounded by after_slot" do
      cron = cron!("0 9 * * 1-5")

      assert {:ok, slot} = Spec.latest_slot_at_or_before(cron, dt("2026-01-04T12:00:00Z"), nil)
      assert slot == unix("2026-01-02T09:00:00Z")

      # Exactly on a slot counts (<= now).
      assert {:ok, ^slot} = Spec.latest_slot_at_or_before(cron, dt("2026-01-02T09:00:00Z"), nil)

      # after_slot is exclusive.
      assert :none = Spec.latest_slot_at_or_before(cron, dt("2026-01-04T12:00:00Z"), slot)
    end

    test "cron: a spec silent for over a year yields :none" do
      assert :none =
               Spec.latest_slot_at_or_before(cron!("0 0 29 2 *"), ~U[2026-06-01 00:00:00Z], nil)
    end
  end

  describe "missed_count/4" do
    test "interval counts slots in (after, now] arithmetically" do
      spec = every!("1h")
      assert Spec.missed_count(spec, unix(@anchor), dt("2026-01-01T05:00:10Z")) == 5

      assert Spec.missed_count(spec, unix("2026-01-01T05:00:00Z"), dt("2026-01-01T05:30:00Z")) ==
               0

      assert Spec.missed_count(spec, nil, dt("2026-01-01T05:00:10Z")) == 6
      assert Spec.missed_count(spec, unix(@anchor), dt("2026-01-01T05:00:10Z"), 3) == 3
    end

    test "cron counts matching slots" do
      spec = cron!("0 */6 * * *")

      assert Spec.missed_count(spec, unix("2026-01-01T00:00:00Z"), dt("2026-01-02T00:00:00Z")) ==
               4
    end
  end

  # ---------------------------------------------------------------------------
  # Property: agreement with a brute-force minute-by-minute reference that is
  # built from the generator's own value lists, not from Spec's parser.
  # ---------------------------------------------------------------------------

  defp field_gen(range) do
    gen all(
          values <-
            StreamData.uniq_list_of(StreamData.member_of(range), min_length: 1, max_length: 3)
        ) do
      Enum.sort(values)
    end
  end

  defp cron_gen do
    gen all(
          minutes <- field_gen(0..59),
          hours <- field_gen(0..23),
          dom <- one_of([constant(:star), field_gen(1..28)]),
          dow <- one_of([constant(:star), field_gen(0..6)])
        ) do
      expr =
        Enum.join(
          [
            Enum.join(minutes, ","),
            Enum.join(hours, ","),
            if(dom == :star, do: "*", else: Enum.join(dom, ",")),
            "*",
            if(dow == :star, do: "*", else: Enum.join(dow, ","))
          ],
          " "
        )

      {expr, %{minutes: minutes, hours: hours, dom: dom, dow: dow}}
    end
  end

  defp reference_match?(ref, %DateTime{} = t) do
    dom_ok = ref.dom == :star or t.day in ref.dom
    dow_ok = ref.dow == :star or rem(Date.day_of_week(DateTime.to_date(t)), 7) in ref.dow

    day_ok =
      case {ref.dom, ref.dow} do
        {:star, _} -> dow_ok
        {_, :star} -> dom_ok
        _ -> dom_ok or dow_ok
      end

    day_ok and t.hour in ref.hours and t.minute in ref.minutes
  end

  @base ~U[2026-02-10 03:07:00Z]

  property "latest_slot_at_or_before equals the brute-force maximum over the last 7 days" do
    check all(
            {expr, ref} <- cron_gen(),
            offset_minutes <- integer(0..(14 * 1440)),
            max_runs: 60
          ) do
      spec = cron!(expr)
      now = DateTime.add(@base, offset_minutes * 60 + 17, :second)
      floor_now = DateTime.add(@base, offset_minutes * 60, :second)

      expected =
        Enum.find_value(0..(7 * 1440 - 1), :none, fn back ->
          t = DateTime.add(floor_now, -back * 60, :second)
          if reference_match?(ref, t), do: {:ok, DateTime.to_unix(t)}
        end)

      case Spec.latest_slot_at_or_before(spec, now, DateTime.to_unix(now) - 7 * 86_400) do
        {:ok, slot} -> assert expected == {:ok, slot}
        :none -> assert expected == :none
      end
    end
  end

  property "next_after is the first brute-force match strictly after the instant" do
    check all(
            {expr, ref} <- cron_gen(),
            offset_minutes <- integer(0..(7 * 1440)),
            max_runs: 60
          ) do
      spec = cron!(expr)
      from = DateTime.add(@base, offset_minutes * 60 + 17, :second)
      start = DateTime.add(@base, offset_minutes * 60 + 60, :second)

      expected =
        Enum.find_value(0..(60 * 1440), nil, fn fwd ->
          t = DateTime.add(start, fwd * 60, :second)
          if reference_match?(ref, t), do: t
        end)

      # Specs that do not fire within the 60-day brute-force window are skipped.
      if expected do
        assert {:ok, ^expected} = Spec.next_after(spec, from)
        assert DateTime.compare(expected, from) == :gt
      end
    end
  end
end
