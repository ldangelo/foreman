defmodule ForemanServer.AgentRuntime.JidoHarness.FailureCause do
  @moduledoc """
  The real cause of a failed harness run, carried next to its normalized code.

  `ErrorCodes`/`RunResult.normalize/1` collapse a run's failure to a code such
  as `{:other, :execution}`; the message, exit status or timeout kind the
  provider reported is dropped there. A killed `pi` and a failed review phase
  both reached the thread card, the notification and the coordinator report as
  that one opaque tuple. The workflow door's worker now returns
  `{:error, %FailureCause{}}`, so the original code survives in `:code` and the
  cause survives in `:detail`: a single-line, secret-redacted, bounded string.

  `render/1` is the one place a failure reason becomes the text persisted on
  `PhaseFailed`/`RunFailed`/`TaskExecutionFailed`; any other reason is rendered
  with `inspect/1` exactly as before.
  """

  alias ForemanServer.Overwatch.WorkerLogPolicy
  alias Jido.Harness.{Error, Event, RunResult}

  @max_detail_bytes 500

  @enforce_keys [:code, :detail]
  defstruct [:code, :detail]

  @type t :: %__MODULE__{code: term(), detail: String.t()}

  @doc """
  Builds the cause of a failed `RunResult`. `code` is the reason `RunResult.normalize/1`
  returned for it (the second element of its `{:error, _}`); `secrets` are the configured values to scrub from the text.
  """
  @spec from_run_result(RunResult.t(), term(), [String.t()]) :: t()
  def from_run_result(%RunResult{} = result, code, secrets) when is_list(secrets) do
    %__MODULE__{code: code, detail: result |> describe() |> sanitize(secrets)}
  end

  @doc """
  The text of any failure as it may be persisted or shown: `secrets` scrubbed, one
  line, bounded. The one pipeline `from_run_result/3` uses, public so another failure
  reporter (the review evaluator's provider/await/start errors) shares it instead of
  growing a second.
  """
  @spec sanitize(String.t(), [String.t()]) :: String.t()
  def sanitize(text, secrets) when is_binary(text) and is_list(secrets) do
    text
    |> WorkerLogPolicy.redact(secrets)
    |> one_line()
    |> truncate()
  end

  @doc "Text persisted for a failure reason: the cause for a `%FailureCause{}`, `inspect/1` otherwise."
  @spec render(term()) :: String.t()
  def render(%__MODULE__{code: code, detail: detail}), do: "#{inspect(code)}: #{detail}"
  def render(reason), do: inspect(reason)

  defp describe(%RunResult{error: %Error{} = error}) do
    base = "#{error.category}: #{Error.message(error)}"

    [base, details_text(error.details), cause_text(error.cause)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp describe(%RunResult{status: :failed, error: nil} = result) do
    case last_failure_text(result.events) do
      nil -> "run failed without detail"
      text -> "failed: " <> text
    end
  end

  defp describe(%RunResult{status: :failed, error: error}), do: "failed: " <> inspect(error)
  defp describe(%RunResult{status: :cancelled}), do: "run was cancelled"
  defp describe(%RunResult{status: status}), do: "run ended with status #{status}"

  defp details_text(details) when map_size(details) == 0, do: ""

  defp details_text(details),
    do: "(details: #{inspect(details, limit: 10, printable_limit: 200)})"

  defp cause_text(nil), do: ""
  defp cause_text(cause), do: "(cause: #{inspect(cause, limit: 10, printable_limit: 200)})"

  defp last_failure_text(events) do
    events
    |> Enum.filter(
      &match?(%Event{type: :run_failed, payload: %{"error" => e}} when is_binary(e), &1)
    )
    |> List.last()
    |> case do
      %Event{payload: %{"error" => text}} -> text
      nil -> nil
    end
  end

  defp one_line(text), do: String.replace(text, ~r/\s+/, " ")

  defp truncate(text) when byte_size(text) <= @max_detail_bytes, do: text
  defp truncate(text), do: String.slice(text, 0, @max_detail_bytes) <> "..."
end
