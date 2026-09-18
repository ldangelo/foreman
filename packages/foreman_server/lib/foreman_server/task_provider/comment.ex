defmodule ForemanServer.TaskProvider.Comment do
  @moduledoc "Typed result returned after a provider comment/work-log write."

  @enforce_keys [:provider_issue_id, :status]
  @type t :: %__MODULE__{
          provider_issue_id: String.t(),
          status: String.t(),
          provider_metadata: map()
        }
  @derive Jason.Encoder
  defstruct [:provider_issue_id, :status, provider_metadata: %{}]
end
