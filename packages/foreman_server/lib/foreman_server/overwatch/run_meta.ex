defmodule ForemanServer.Overwatch.RunMeta do
  @moduledoc """
  Provider-reported facts about one finished harness run that the plain
  `{:ok, text} | {:error, code}` worker result cannot carry.

  Built by `JidoHarnessWorker.build_meta/2` from the `Jido.Harness.RunResult`
  BEFORE `RunResult.normalize/1` runs, because normalising a failed run
  discards everything except an error code — and a failed run still has a
  provider session worth resuming and tokens that were still spent.

  * `provider_session_id` - the provider's own session handle (for example the
    Claude CLI session UUID); `nil` when the provider reported none. This is
    NOT `WorkerStarted.session_id`, which is a Foreman-generated handle.
  * `run_status` - the harness run's terminal status.
  * `usage` - the string-keyed provider usage map, verbatim (`%{}` when absent).
  * `events_cost_usd` - dollar cost the provider reported on its final
    `:run_completed` event (`"cost_usd"`), `nil` when none was reported.
    `nil` means unknown, never zero.
  """

  @enforce_keys [:provider, :run_status]
  defstruct [
    :provider,
    :provider_session_id,
    :run_status,
    :events_cost_usd,
    usage: %{}
  ]

  @type run_status :: :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          provider: atom(),
          provider_session_id: String.t() | nil,
          run_status: run_status(),
          usage: map(),
          events_cost_usd: number() | nil
        }
end
