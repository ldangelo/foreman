defmodule ForemanServer.Events.PrAssociated do
  @moduledoc "Emitted when a run is associated with a PR URL."

  @enforce_keys [:run_id, :pr_url, :pr_number, :sequence]
  @type t :: %__MODULE__{
          run_id: String.t(),
          pr_url: String.t(),
          pr_number: String.t() | nil,
          association_id: String.t() | nil,
          sequence: non_neg_integer()
        }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :pr_url,
    :pr_number,
    :association_id,
    sequence: 0
  ]

  @spec from_payload(map()) :: t()
  def from_payload(payload) do
    %__MODULE__{
      run_id: require_binary(payload, :run_id),
      pr_url: require_binary(payload, :pr_url),
      pr_number: get(payload, :pr_number),
      association_id: get(payload, :association_id),
      sequence: get(payload, :sequence, 0)
    }
  end

  # --- Private helpers --------------------------------------------------------

  defp get(payload, atom_key, default \\ nil) do
    Map.get(payload, atom_key) || Map.get(payload, Atom.to_string(atom_key)) || default
  end

  defp require_binary(payload, atom_key) do
    value = get(payload, atom_key)
    if is_binary(value) and value != "", do: value, else: raise("missing required: #{atom_key}")
  end
end
