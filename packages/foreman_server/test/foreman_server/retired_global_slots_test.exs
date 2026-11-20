defmodule ForemanServer.RetiredGlobalSlotsTest do
  @moduledoc """
  Source contract for the retired global run-slot cap (TRD-010, AC-008-2): no
  production code under `lib/` names the legacy global stream or reads the retired
  `:max_concurrent_runs` application key, except the migration module, which is the
  one reader of the legacy stream and the owner of the retired-key boot warning.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../lib", __DIR__)
  @allowed [Path.join(@lib, "foreman_server/workflow/run_slots_migration.ex")]

  defp production_files do
    @lib |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.reject(&(&1 in @allowed))
  end

  defp offenders(regex) do
    for file <- production_files(),
        {line, n} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        Regex.match?(regex, line),
        do: "#{Path.relative_to(file, @lib)}:#{n}: #{String.trim(line)}"
  end

  test "nothing under lib/ names the legacy global slot stream outside the migration module" do
    assert offenders(~r/run_slots:global/) == []
  end

  test "nothing reads the retired :max_concurrent_runs application key (no global setting is read)" do
    reads = ~r/(get_env|fetch_env!?|get_all_env|put_env)\(\s*:foreman_server,\s*:max_concurrent_runs\s*[,)]/
    assert offenders(reads) == []
  end

  test "nothing calls the retired RunSlots.Config.max_concurrent_runs/0" do
    assert offenders(~r/Config\.max_concurrent_runs\(\)/) == []
  end
end
