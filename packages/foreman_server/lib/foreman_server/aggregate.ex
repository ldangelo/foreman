defmodule ForemanServer.Aggregate do
  @moduledoc """
  Small event-sourced aggregate helper.

  Aggregates validate commands against state rebuilt from their stream events, then
  return compatible domain-event specs for the existing EventStore/ProjectionStore
  pipeline. Historical/imported events are tolerated by each aggregate fold.
  """

  @type state :: map()
  @type command :: %{type: String.t(), payload: map()}
  @type event_spec :: %{
          required(:stream_id) => String.t(),
          required(:event_type) => String.t(),
          required(:payload) => map(),
          optional(:expected_stream_version) => non_neg_integer()
        }

  @callback initial_state() :: state()
  @callback apply_event(state(), ForemanServer.Event.t() | map()) :: state()
  @callback handle_command(state(), command()) ::
              {:ok, event_spec()} | {:error, term()} | :unhandled

  @spec load(module(), String.t()) :: {state(), non_neg_integer()}
  def load(module, stream_id) when is_atom(module) and is_binary(stream_id) do
    events = ForemanServer.EventStore.stream(stream_id)
    {fold(module, events), length(events)}
  end

  @spec fold(module(), [ForemanServer.Event.t() | map()]) :: state()
  def fold(module, events) when is_atom(module) and is_list(events) do
    Enum.reduce(events, module.initial_state(), &module.apply_event(&2, &1))
  end

  @spec decide(module(), String.t(), String.t(), map()) ::
          {:ok, event_spec()} | {:error, term()} | :unhandled
  def decide(module, stream_id, command_type, payload)
      when is_atom(module) and is_binary(stream_id) and is_binary(command_type) and
             is_map(payload) do
    {state, version} = load(module, stream_id)

    case module.handle_command(state, %{type: command_type, payload: payload}) do
      {:ok, spec} -> {:ok, Map.put_new(spec, :expected_stream_version, version)}
      other -> other
    end
  end

  @spec event_payload(ForemanServer.Event.t() | map()) :: map()
  def event_payload(%ForemanServer.Event{payload: payload}), do: payload
  def event_payload(%{payload: payload}) when is_map(payload), do: payload
  def event_payload(%{"payload" => payload}) when is_map(payload), do: payload
  def event_payload(map) when is_map(map), do: map

  @spec event_type(ForemanServer.Event.t() | map()) :: String.t() | nil
  def event_type(%ForemanServer.Event{event_type: type}), do: type
  def event_type(%{event_type: type}), do: type
  def event_type(%{type: type}), do: type
  def event_type(%{"event_type" => type}), do: type
  def event_type(%{"type" => type}), do: type
  def event_type(_), do: nil

  @spec get(map(), atom(), term()) :: term()
  def get(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  @spec required_binary(term(), atom()) :: {:ok, String.t()} | {:error, term()}
  def required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  def required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}

  @spec put_if(map(), atom(), term()) :: map()
  def put_if(map, _key, nil), do: map
  def put_if(map, key, value), do: Map.put(map, key, value)
end
