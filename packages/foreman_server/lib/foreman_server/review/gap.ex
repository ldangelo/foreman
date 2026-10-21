defmodule ForemanServer.Review.Gap do
  @moduledoc "One shortfall of delivered work against its request, found by the reviewer."

  alias ForemanServer.Review.Verdict

  @enforce_keys [:title, :description, :dimension, :severity]
  @type t :: %__MODULE__{
          title: String.t(),
          description: String.t(),
          dimension: Verdict.dimension(),
          severity: :major | :minor
        }
  defstruct [:title, :description, :dimension, :severity]
end
