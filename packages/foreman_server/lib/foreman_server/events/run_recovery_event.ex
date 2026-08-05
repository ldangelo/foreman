defmodule ForemanServer.Events.RunRecoveryEvent do
  @moduledoc "Emitted by Recovery.do_detect/0 for each interrupted run on startup."
  @derive Jason.Encoder
  defstruct [:run_id, :reason, :last_event_at, :recovered_at]
end
