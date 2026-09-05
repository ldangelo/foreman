defmodule ForemanServer.Messaging.Config do
  @moduledoc "Resolved outbound messaging config."

  @enforce_keys [
    :enabled?,
    :provider,
    :event_classes,
    :dedupe_window_ms,
    :run_update_rate_limit_ms
  ]
  @derive {Jason.Encoder, except: [:destination]}
  defstruct [
    :enabled?,
    :provider,
    :event_classes,
    :dedupe_window_ms,
    :run_update_rate_limit_ms,
    :destination
  ]

  @type t :: %__MODULE__{
          enabled?: boolean(),
          provider: :telegram | :slack,
          event_classes: [atom()],
          dedupe_window_ms: non_neg_integer(),
          run_update_rate_limit_ms: non_neg_integer(),
          destination: map() | nil
        }
end
