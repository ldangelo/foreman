defmodule ForemanServer.Events.JobsiteCommitsRecorded do
  @moduledoc "Typed event emitted when commits produced by a jobsite run are recorded."
  @enforce_keys [:jobsite_id, :commits]
  @type commit :: %{sha: String.t(), subject: String.t()}
  @type t :: %__MODULE__{jobsite_id: String.t(), commits: [commit()]}
  @derive Jason.Encoder
  defstruct [:jobsite_id, :commits]
end
