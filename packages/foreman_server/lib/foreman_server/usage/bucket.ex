defmodule ForemanServer.Usage.Bucket do
  @moduledoc "Summed usage of a set of events plus how many of them had no cost."

  alias ForemanServer.Usage

  @type t :: %__MODULE__{
          usage: Usage.t(),
          events: non_neg_integer(),
          cost_unknown_events: non_neg_integer()
        }
  defstruct usage: %Usage{}, events: 0, cost_unknown_events: 0
end
