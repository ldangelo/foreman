defmodule ForemanServer.Agents.JidoAiRunner do
  @moduledoc """
  Runs `jido_ai` reasoning strategies (ReAct, Chain-of-Thought) on top of the
  req_llm HTTP client.

  TRD-2026-4212be7e / JAI-T001 / TRD-039.

  `jido_ai` is an unconditional dependency, so there is no placeholder or
  degraded path: a strategy either executes and returns a
  `ForemanServer.Agents.JidoAiRunner.Result`, or the caller gets a
  `ForemanServer.Agents.JidoAiRunner.Error` saying why it did not.

    * `:react` runs `Jido.AI.Reasoning.ReAct.run/3`, which returns a bare map
      with `:result`, `:termination_reason`, `:usage`, `:final_token` and
      `:trace`. Only `:final_answer` with a binary result is success;
      `:failed`, `:cancelled` and `:max_iterations` (the loop gave up without an
      answer) are `:strategy_failed`; anything else is
      `:unexpected_result_shape`.
    * `:cot` makes one real model call with the Chain-of-Thought system prompt
      (`Jido.AI.Reasoning.ChainOfThought` exposes the prompt and step parser but
      no run entrypoint: its strategy needs a running agent server).

  Genuine crashes inside the strategies are not rescued; they surface to the
  caller.

  ## Usage

      ForemanServer.Agents.JidoAiRunner.run(:react, "What is 2 + 2?")
      ForemanServer.Agents.JidoAiRunner.run(:cot, "Explain photosynthesis.",
        model: "openai:gpt-4o")
  """

  require Logger

  alias ForemanServer.Agents.JidoAiRunner.{Error, Result}
  alias Jido.AI.Reasoning.ChainOfThought
  alias Jido.AI.Reasoning.ReAct

  @type strategy :: :react | :cot

  @doc """
  Run the given `:react` or `:cot` strategy against `prompt`.

  Options: `:model` (default `"auto"`), `:max_tokens`, `:timeout_ms`.
  """
  @spec run(atom(), String.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(strategy, prompt, opts \\ []) when is_atom(strategy) and is_binary(prompt) do
    model = Keyword.get(opts, :model, "auto")

    Logger.info("jido_ai strategy=#{strategy} model=#{model}")

    case strategy do
      :react -> run_react(prompt, opts)
      :cot -> run_cot(prompt, opts)
      other -> {:error, Error.new(:unknown_strategy, "unknown strategy #{inspect(other)}")}
    end
  end

  defp run_react(prompt, opts) do
    config =
      %{model: opts |> Keyword.get(:model, "auto") |> resolve_model()}
      |> put_present(:max_tokens, Keyword.get(opts, :max_tokens))
      |> put_present(:timeout_ms, Keyword.get(opts, :timeout_ms))

    prompt |> ReAct.run(config, []) |> react_outcome()
  end

  defp react_outcome(%{termination_reason: :final_answer, result: output} = raw)
       when is_binary(output) do
    {:ok,
     %Result{
       strategy: :react,
       output: output,
       termination_reason: :final_answer,
       usage: usage_or_nil(Map.get(raw, :usage)),
       trace: Map.get(raw, :trace),
       final_token: Map.get(raw, :final_token)
     }}
  end

  defp react_outcome(%{termination_reason: :failed, result: reason}) do
    {:error, Error.new(:strategy_failed, "react run failed", reason)}
  end

  defp react_outcome(%{termination_reason: :cancelled, result: reason}) do
    {:error, Error.new(:strategy_failed, "react run cancelled", reason)}
  end

  defp react_outcome(%{termination_reason: :max_iterations, result: reason}) do
    {:error,
     Error.new(
       :strategy_failed,
       "react run hit the iteration limit without a final answer",
       reason
     )}
  end

  defp react_outcome(raw) do
    {:error,
     Error.new(
       :unexpected_result_shape,
       "Jido.AI.Reasoning.ReAct.run/3 returned an unrecognised result",
       raw
     )}
  end

  defp run_cot(prompt, opts) do
    llm_opts =
      [
        model: opts |> Keyword.get(:model, "auto") |> resolve_model(),
        system_prompt: ChainOfThought.default_system_prompt()
      ]
      |> put_present(:max_tokens, Keyword.get(opts, :max_tokens))
      |> put_present(:timeout, Keyword.get(opts, :timeout_ms))

    case Jido.AI.generate_text(prompt, llm_opts) do
      {:ok, response} -> cot_outcome(response)
      {:error, reason} -> {:error, Error.new(:strategy_failed, "cot model call failed", reason)}
      other -> {:error, unexpected_cot(other)}
    end
  end

  defp cot_outcome(%{message: %{}} = response) do
    case Jido.AI.Turn.extract_text(response) do
      "" ->
        {:error, unexpected_cot(response)}

      output ->
        {:ok,
         %Result{
           strategy: :cot,
           output: output,
           termination_reason: :final_answer,
           usage: usage_or_nil(Map.get(response, :usage))
         }}
    end
  end

  defp cot_outcome(other), do: {:error, unexpected_cot(other)}

  defp unexpected_cot(raw) do
    Error.new(
      :unexpected_result_shape,
      "Jido.AI.generate_text/2 returned an unrecognised result",
      raw
    )
  end

  # The runner's own "auto" sentinel (the default when no `:model` opt is
  # given) must resolve through `config :jido_ai, model_aliases: %{auto: ...}`
  # (an atom-keyed alias, per `Jido.AI.ModelAliases`) so it routes through
  # LiteLLM. Any other value is treated as an explicit ReqLLM model spec
  # (e.g. "openai:gpt-4o") and passed through unchanged.
  defp resolve_model("auto"), do: :auto
  defp resolve_model(model), do: model

  defp usage_or_nil(%{} = usage) when map_size(usage) > 0, do: usage
  defp usage_or_nil(_), do: nil

  defp put_present(config, _key, nil), do: config
  defp put_present(config, key, value) when is_map(config), do: Map.put(config, key, value)
  defp put_present(config, key, value) when is_list(config), do: Keyword.put(config, key, value)
end
