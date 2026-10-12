defmodule ForemanServer.Events.JobsiteCompleted do
  @moduledoc "Typed event emitted when a jobsite run finishes successfully."
  @enforce_keys [:jobsite_id, :iterations_run]
  @type t :: %__MODULE__{
          jobsite_id: String.t(),
          iterations_run: non_neg_integer(),
          branch: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:jobsite_id, :iterations_run, :branch]
end
