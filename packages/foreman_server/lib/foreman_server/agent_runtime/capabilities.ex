defmodule ForemanServer.AgentRuntime.Capabilities do
  @moduledoc """
  Validates and normalizes the capability map returned by a
  `ForemanServer.AgentRuntime.BackendAdapter` implementation.

  ## Schema

      %{
        required(:type) => atom(),
        required(:strengths) => [atom()],
        required(:weaknesses) => [atom()],
        required(:supported_contexts) => [atom()],
        optional(:cost_per_call) => float(),
        optional(:typical_latency_ms) => non_neg_integer()
      }

  List-valued required fields MUST contain atoms (per PRD AC-006-1); the
  runtime matches `supported_contexts` against `opts[:task_type]` and
  router signals against `strengths`/`weaknesses`, both of which are
  atoms at the call site.

  ## Normalization

  `:cost_per_call` is documented as a float but is leniently accepted as
  an integer and normalized to a float (`1` becomes `1.0`). This avoids
  silently accepting genuinely invalid entries (strings, atoms, nil)
  while smoothing over the common case where adapters declare `1` for
  "one unit of cost".

  `:typical_latency_ms` is a `non_neg_integer` and is not normalized.

  ## Errors

  Every error is a tagged tuple identifying the offending field so a
  registration call can return it verbatim:

    * `{:missing_field, atom()}` — a required field is absent
    * `{:invalid_field, atom(), :wrong_type}` — a field has the wrong type
    * `{:unknown_field, atom()}` — the map carries a field outside the schema

  `validate/1` is pure: it never inserts, mutates, or stores the map. An
  invalid input short-circuits on the first violation; later violations
  in the same map are not reported in the same call.
  """

  @required_fields [:type, :strengths, :weaknesses, :supported_contexts]
  @optional_fields [:cost_per_call, :typical_latency_ms]
  @all_fields @required_fields ++ @optional_fields

  @type field :: atom()
  @type error_reason ::
          {:missing_field, field()}
          | {:invalid_field, field(), :wrong_type}
          | {:unknown_field, field()}

  @type t :: %{
          required(:type) => atom(),
          required(:strengths) => [atom()],
          required(:weaknesses) => [atom()],
          required(:supported_contexts) => [atom()],
          optional(:cost_per_call) => float(),
          optional(:typical_latency_ms) => non_neg_integer()
        }

  @doc """
  Validate and normalize a capability map against the schema. Returns
  the normalized map on success, or a field-specific error on the first
  violation.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, error_reason()}
  def validate(caps) when is_map(caps), do: do_validate(caps)
  def validate(_root), do: {:error, {:invalid_field, :root, :wrong_type}}

  defp do_validate(caps) do
    with :ok <- check_required(caps),
         :ok <- check_no_unknown(caps),
         {:ok, normalized} <- check_and_normalize(caps) do
      {:ok, normalized}
    end
  end

  defp check_required(caps) do
    case Enum.find(@required_fields, fn field -> not Map.has_key?(caps, field) end) do
      nil -> :ok
      missing -> {:error, {:missing_field, missing}}
    end
  end

  defp check_no_unknown(caps) do
    case Enum.find(Map.keys(caps), fn key -> key not in @all_fields end) do
      nil -> :ok
      unknown -> {:error, {:unknown_field, unknown}}
    end
  end

  defp check_and_normalize(caps) do
    with :ok <- check_atom_field(caps, :type),
         :ok <- check_atom_list(caps, :strengths),
         :ok <- check_atom_list(caps, :weaknesses),
         :ok <- check_atom_list(caps, :supported_contexts),
         {:ok, normalized} <- normalize_cost_per_call(caps),
         :ok <- check_typical_latency(normalized) do
      {:ok, normalized}
    end
  end

  defp check_atom_field(caps, field) do
    case Map.fetch(caps, field) do
      {:ok, value} when is_atom(value) -> :ok
      {:ok, _} -> {:error, {:invalid_field, field, :wrong_type}}
      :error -> :ok
    end
  end

  defp check_atom_list(caps, field) do
    case Map.fetch(caps, field) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_atom/1) do
          :ok
        else
          {:error, {:invalid_field, field, :wrong_type}}
        end

      {:ok, _} ->
        {:error, {:invalid_field, field, :wrong_type}}

      :error ->
        :ok
    end
  end

  defp normalize_cost_per_call(caps) do
    case Map.fetch(caps, :cost_per_call) do
      :error ->
        {:ok, caps}

      {:ok, value} when is_float(value) ->
        {:ok, caps}

      {:ok, value} when is_integer(value) ->
        {:ok, Map.put(caps, :cost_per_call, value * 1.0)}

      {:ok, _} ->
        {:error, {:invalid_field, :cost_per_call, :wrong_type}}
    end
  end

  defp check_typical_latency(caps) do
    case Map.fetch(caps, :typical_latency_ms) do
      {:ok, value} when is_integer(value) and value >= 0 -> :ok
      {:ok, _} -> {:error, {:invalid_field, :typical_latency_ms, :wrong_type}}
      :error -> :ok
    end
  end

  @doc """
  Returns the list of required capability fields.
  """
  @spec required_fields() :: [field()]
  def required_fields, do: @required_fields

  @doc """
  Returns the list of optional capability fields.
  """
  @spec optional_fields() :: [field()]
  def optional_fields, do: @optional_fields
end
