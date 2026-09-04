defmodule ForemanServer.Workflow.StallPolicy do
  @moduledoc """
  Typed phase stall-detection policy parsing.

  Detection is opt-in per workflow phase through `stall_detection`; phase names are
  never interpreted as a signal.
  """

  @agent_kind "agent_no_output"
  @messaging_kind "messaging_no_progress"
  @fail_policy "fail"
  @attention_policy "attention"
  @disabled_values [false, :disabled, "disabled"]

  @type kind :: String.t()
  @type policy :: String.t()
  @type t :: %{
          kind: kind(),
          threshold_ms: pos_integer(),
          policy: policy()
        }

  @spec default_threshold_ms(kind()) :: pos_integer()
  def default_threshold_ms(@agent_kind), do: agent_threshold_ms!()
  def default_threshold_ms(@messaging_kind), do: messaging_threshold_ms!()

  @spec agent_threshold_ms! :: pos_integer()
  def agent_threshold_ms!, do: validate_threshold!(:agent_no_output_stall_threshold_ms, 900_000)

  @spec messaging_threshold_ms! :: pos_integer()
  def messaging_threshold_ms!,
    do: validate_threshold!(:messaging_no_progress_stall_threshold_ms, 1_800_000)

  @spec enabled? :: boolean()
  def enabled? do
    enabled_value?(Application.get_env(:foreman_server, :stall_detection_enabled, true))
  end

  @spec validate_threshold(atom(), pos_integer()) :: {:ok, pos_integer()} | {:error, term()}
  def validate_threshold(key, default)
      when is_atom(key) and is_integer(default) and default > 0 do
    case Application.get_env(:foreman_server, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value when value in @disabled_values -> {:error, {:stall_detection_disabled, key}}
      value -> {:error, {:invalid_stall_threshold, key, value}}
    end
  end

  @spec normalize(term()) :: {:ok, t() | nil} | {:error, term()}
  def normalize(nil), do: {:ok, nil}
  def normalize(value) when value in @disabled_values, do: {:ok, nil}

  def normalize("agent"),
    do: {:ok, %{kind: @agent_kind, threshold_ms: agent_threshold_ms!(), policy: @fail_policy}}

  def normalize(:agent), do: normalize("agent")
  def normalize("agent_no_output"), do: normalize("agent")
  def normalize(:agent_no_output), do: normalize("agent")

  def normalize("messaging"),
    do:
      {:ok,
       %{
         kind: @messaging_kind,
         threshold_ms: messaging_threshold_ms!(),
         policy: @attention_policy
       }}

  def normalize(:messaging), do: normalize("messaging")
  def normalize("messaging_no_progress"), do: normalize("messaging")
  def normalize(:messaging_no_progress), do: normalize("messaging")

  def normalize(%{} = map) do
    with {:ok, kind} <- normalize_kind(fetch_any(map, [:kind, "kind", :scope, "scope"])),
         {:ok, threshold_ms} <-
           normalize_threshold(
             fetch_any(map, [:threshold_ms, "threshold_ms", :threshold, "threshold"]),
             kind
           ),
         {:ok, policy} <- normalize_policy(fetch_any(map, [:policy, "policy"]), kind) do
      {:ok, %{kind: kind, threshold_ms: threshold_ms, policy: policy}}
    end
  end

  def normalize(value), do: {:error, {:invalid_stall_detection, value}}

  @spec normalize!(term()) :: t() | nil
  def normalize!(value) do
    case normalize(value) do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, "invalid stall_detection: #{inspect(reason)}"
    end
  end

  @spec payload_fields(term()) :: map()
  def payload_fields(value) do
    case normalize!(value) do
      nil ->
        %{}

      %{kind: kind, threshold_ms: threshold_ms, policy: policy} ->
        %{stall_detection_kind: kind, stall_threshold_ms: threshold_ms, stall_policy: policy}
    end
  end

  defp fetch_any(_map, []), do: nil

  defp fetch_any(map, [key | rest]) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> fetch_any(map, rest)
    end
  end

  defp normalize_kind(kind) when kind in ["agent", :agent, "agent_no_output", :agent_no_output],
    do: {:ok, @agent_kind}

  defp normalize_kind(kind)
       when kind in ["messaging", :messaging, "messaging_no_progress", :messaging_no_progress],
       do: {:ok, @messaging_kind}

  defp normalize_kind(other), do: {:error, {:invalid_stall_kind, other}}

  defp normalize_threshold(nil, kind), do: {:ok, default_threshold_ms(kind)}
  defp normalize_threshold(value, _kind) when is_integer(value) and value > 0, do: {:ok, value}
  defp normalize_threshold(value, _kind), do: {:error, {:invalid_stall_threshold, value}}

  defp normalize_policy(nil, @agent_kind), do: {:ok, @fail_policy}
  defp normalize_policy(nil, @messaging_kind), do: {:ok, @attention_policy}

  defp normalize_policy(policy, _kind) when policy in [@fail_policy, @attention_policy],
    do: {:ok, policy}

  defp normalize_policy(policy, _kind) when policy in [:fail, :attention],
    do: {:ok, Atom.to_string(policy)}

  defp normalize_policy(policy, _kind), do: {:error, {:invalid_stall_policy, policy}}

  defp validate_threshold!(key, default) do
    case validate_threshold(key, default) do
      {:ok, value} ->
        value

      {:error, reason} ->
        raise ArgumentError, "invalid stall threshold config: #{inspect(reason)}"
    end
  end

  defp enabled_value?(value) when value in [true, "true", :enabled, "enabled"], do: true
  defp enabled_value?(value) when value in @disabled_values, do: false

  defp enabled_value?(value),
    do: raise(ArgumentError, "invalid :stall_detection_enabled value: #{inspect(value)}")
end
