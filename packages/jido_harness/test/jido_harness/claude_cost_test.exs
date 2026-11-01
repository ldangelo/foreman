defmodule Jido.Harness.ClaudeCostTest do
  @moduledoc """
  The dollar cost the claude adapter reports for a run (`"cost_usd"` of the terminal event).

  The CLI prices every call with its own table and says, per model in its `result` record
  (`modelUsage.<model>.costBasis`), which table it used: `list` (its built-in prices), `managed`
  (the organisation's managed-settings prices) or `unknown` (no price for that model name, so
  `costUSD` is "a guess at the default model's rate"). A guess is not a cost.

  The two records below are REAL, not hand-made: claude 2.1.309 answering `--model Minimax-M3`, a
  LiteLLM alias it does not know, through a gateway (`total_cost_usd` 0.2919968 for 67378 input,
  71824 cache-read and 406 output tokens, which is $4 / $0.20 / $20 per million, the rates of the
  CLI's default model; the gateway's own price for the same tokens is 0.0246), and claude 2.1.308
  answering a model it prices (`claude-haiku-5-5`, `costBasis` `list`).
  """

  use ExUnit.Case, async: true

  alias Jido.Harness.Adapters.CLIMapper
  alias Jido.Harness.Event

  @fixtures Path.expand("../support/fixtures", __DIR__)

  defp result_record(fixture) do
    [@fixtures, fixture]
    |> Path.join()
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find(&(&1["type"] == "result"))
  end

  defp unknown_model_result, do: result_record("claude_live_unknown_model.jsonl")
  defp priced_model_result, do: result_record("claude_live_input.jsonl")

  # The same record with one model entry's `costBasis` replaced (`:none`: removed).
  defp with_basis(record, model, :none),
    do: update_in(record, ["modelUsage", model], &Map.delete(&1, "costBasis"))

  defp with_basis(record, model, basis),
    do: put_in(record, ["modelUsage", model, "costBasis"], basis)

  defp mapped(record, mapper), do: apply(CLIMapper, mapper, [record])

  # A run's terminal event carries the cost: `:run_completed` in a plain run, `:input_idle` in a
  # live-input run (the harness turns the last of them into the run's `:run_completed`).
  defp reported_cost(record, mapper) do
    assert [%Event{payload: %{"cost_usd" => cost}}] =
             record |> mapped(mapper) |> Enum.filter(&(&1.type in [:run_completed, :input_idle]))

    cost
  end

  for mapper <- [:claude, :claude_live] do
    describe "#{mapper}" do
      test "a model the CLI has no price for reports no cost, and still reports its tokens" do
        record = unknown_model_result()
        assert record["total_cost_usd"] == 0.2919968
        assert record["modelUsage"]["Minimax-M3"]["costBasis"] == "unknown"

        assert reported_cost(record, unquote(mapper)) == nil

        assert %Event{
                 payload: %{
                   "input_tokens" => 67_378,
                   "cache_read_input_tokens" => 71_824,
                   "output_tokens" => 406
                 }
               } = record |> mapped(unquote(mapper)) |> Enum.find(&(&1.type == :usage))
      end

      test "a model the CLI prices keeps the CLI's figure (positive control)" do
        assert reported_cost(priced_model_result(), unquote(mapper)) == 0.00365622
      end

      test "the organisation's own prices (`managed`) are a cost" do
        record = with_basis(priced_model_result(), "claude-haiku-5-5", "managed")
        assert reported_cost(record, unquote(mapper)) == 0.00365622
      end

      test "one model without a price makes the sum a guess, whatever the other models are priced at" do
        unknown_entry = unknown_model_result()["modelUsage"]["Minimax-M3"]
        record = update_in(priced_model_result(), ["modelUsage"], &Map.put(&1, "Minimax-M3", unknown_entry))

        assert map_size(record["modelUsage"]) == 2
        assert reported_cost(record, unquote(mapper)) == nil
      end

      test "a CLI that states no basis keeps reporting its figure, as every CLI did before it did" do
        without_basis = with_basis(priced_model_result(), "claude-haiku-5-5", :none)
        without_model_usage = Map.delete(priced_model_result(), "modelUsage")

        assert reported_cost(without_basis, unquote(mapper)) == 0.00365622
        assert reported_cost(without_model_usage, unquote(mapper)) == 0.00365622
      end

      test "a basis this adapter does not know is not vouched for" do
        record = with_basis(priced_model_result(), "claude-haiku-5-5", "estimated")
        assert reported_cost(record, unquote(mapper)) == nil
      end
    end
  end
end
