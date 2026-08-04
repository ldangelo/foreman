defmodule ForemanServer.AgentRuntime.Capabilities do
  @moduledoc """
  Validates the capability map returned by a
  `ForemanServer.AgentRuntime.BackendAdapter` implementation.

  ## Schema

      %{
        required(:type) => atom(),
        required(:strengths) => [term()],
        required(:weaknesses) => [term()],
        required(:supported_contexts) => [term()],
        optional(:cost_per_call) => number(),
        optional(:typical_latency_ms) => non_neg_integer()
      }

  ## Errors

  Every error is a tagged tuple identifying the offending field so a
  registration call can return it verbatim:

    * `{:missing_field, atom()}` — a required field is absent
    * `{:invalid_field, atom(), :wrong_type}` — a field has the wrong type
    * `{:unknown_field, atom()}` — the map carries a field outside the schema

  `validate/1` is pure: it never inserts, mutates, or stores the map. An
  invalid input short-circuits on the first violation; later violations in
  the same map are not reported in the same call.
  """

  @required_fields [:type, :strengths, :weaknesses, :supported_contexts]
  @optional_fields [:cost_per_call, :typical_latency_ms]
  @all_fields @required_fields ++ @optional_fields

  @type field :: atom()
  @type error_reason ::
          {:missing_field, field()}
          | {:invalid_field, field(), :wrong_type}
          | {:unknown_field, field()}

  @type t :: %{required(field()) => term()}

  @doc """
  Validate a capability map against the schema. Returns the map
  unchanged on success, or a field-specific error on the first violation.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, error_reason()}
  def validate(caps) when is_map(caps), do: do_validate(caps)
  def validate(other), do: {:error, {:invalid_field, :root, :wrong_type}}

  defp do_validate(caps) do
    with :ok <- check_required(caps),
         :ok <- check_no_unknown(caps),
         :ok <- check_types(caps) do
      {:ok, caps}
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

  defp check_types(caps) do
    cond do
      type = caps[:type] ->
        if is_atom(type), do: :ok, else: {:error, {:invalid_field, :type, :wrong_type}}

      true ->
        :ok
    end
    |> case do
      :ok -> check_list_fields(caps, :strengths)
      err -> err
    end
    |> case do
      :ok -> check_list_fields(caps, :weaknesses)
      err -> err
    end
    |> case do
      :ok -> check_list_fields(caps, :supported_contexts)
      err -> err
    end
    |> case do
      :ok -> check_optional_number(caps, :cost_per_call)
      err -> err
    end
    |> case do
      :ok -> check_optional_integer(caps, :typical_latency_ms)
      err -> err
    end
  end

  defp check_list_fields(caps, field) do
    value = Map.get(caps, field)

    if is_list(value) do
      :ok
    else
      {:error, {:invalid_field, field, :wrong_type}}
    end
  end

  defp check_optional_number(caps, field) do
    case Map.fetch(caps, field) do
      {:ok, value} when is_number(value) -> :ok
      {:ok, _} -> {:error, {:invalid_field, field, :wrong_type}}
      :error -> :ok
    end
  end

  defp check_optional_integer(caps, field) do
    case Map.fetch(caps, field) do
      {:ok, value} when is_integer(value) and value >= 0 -> :ok
      {:ok, _} -> {:error, {:invalid_field, field, :wrong_type}}
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
