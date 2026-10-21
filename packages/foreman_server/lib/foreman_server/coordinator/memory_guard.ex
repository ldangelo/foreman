defmodule ForemanServer.Coordinator.MemoryGuard do
  @moduledoc """
  Keeps a standing preference stored by the coordinator from becoming a rule
  that enables automatic merging or approving.

  Spike S1 observed a coordinator "remembering" that it should merge when CI is
  green. The merge gate is operator-only; a memory note that says otherwise
  would be read back into every later prompt. Foreman therefore refuses notes
  that read as merge/approve automation, instead of trusting the prompt to
  prevent them. Operators can still write any note through the memory API.
  """

  @patterns [
    ~r/auto[\s_-]*(merge|approv)/i,
    ~r/(merge|approv)\w*\b[^.\n]{0,60}\bautomatic/i,
    ~r/\b(always|never|automatically|without)\b[^.\n]{0,40}\b(merge|approv)/i,
    ~r/\b(merge|approv)\w*\b[^.\n]{0,40}\b(without|no)\s+(review|approval|asking|operator|human)/i,
    ~r/\bmerge_approve\b|\brun\.pr\.merge\b/i
  ]

  @spec check(String.t()) :: :ok | {:error, :merge_automation}
  def check(text) when is_binary(text) do
    if Enum.any?(@patterns, &Regex.match?(&1, text)), do: {:error, :merge_automation}, else: :ok
  end
end
