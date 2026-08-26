defmodule ForemanServer.TermOrJsonSerializer do
  @moduledoc """
  Hybrid serializer that reads both formats but writes only binary terms.

  - **Read**: If data starts with Erlang magic byte `<<131>>`, deserialize as a binary term
    (TermSerializer format). Otherwise, decode as a JSON string (JsonSerializer format).
    This provides backward compatibility with events already stored in the database.
  - **Write**: Always serialize to Erlang binary term format (TermSerializer).

  The Erlang external term format magic byte is `<<131>>`. JSON strings never start with
  this byte, so the two formats are unambiguously distinguishable.
  """

  @behaviour EventStore.Serializer

  # Erlang external term format magic byte
  @erlang_magic_byte 131

  @doc """
  Serialize any Elixir term to Erlang binary term format.
  """
  @impl true
  def serialize(term) do
    :erlang.term_to_binary(term)
  end

  @doc """
  Deserialize data from either format.

  - `<<131, _::binary>>` — Erlang binary term → `:erlang.binary_to_term`
  - otherwise           — JSON string → `Jason.decode!/1`
  """
  @impl true
  def deserialize(binary, _config) when is_binary(binary) do
    if erlang_term?(binary) do
      :erlang.binary_to_term(binary)
    else
      # JSON string from the old JsonSerializer — decode to Elixir term
      Jason.decode!(binary, keys: :strings)
    end
  end

  def deserialize(other, _config) do
    other
  end

  defp erlang_term?(<<@erlang_magic_byte, _::binary>>), do: true
  defp erlang_term?(_), do: false
end
