defmodule ForemanServer.EventCodec do
  @moduledoc """
  Strict event reconstruction codec for typed domain events.

  `decode!/2` is the sole entry point. It maps an `event_type` (`String.t()`)
  to its struct module and rebuilds the struct from persisted data. There is
  **no permissive fallback**: an unregistered event_type raises
  `ArgumentError`.

  ## The registry is derived, never hand-maintained

  `@registry` is built at compile time by scanning
  `lib/foreman_server/events/` for modules that declare a `defstruct`. Adding
  an event struct registers it automatically; there is no second list to keep
  in sync and therefore no drift to detect.

  This replaced two hand-written maps (`@registry` and an
  `@enforce_keys_registry`) that had already drifted: 15 of 66 event structs —
  including `ProjectRegistered`, `ProjectUpdated`, `ProjectArchived`,
  `PrAssociated`, and the whole `VcsOperation*` family — existed on disk but
  were absent from the registry, so decoding them raised "unregistered
  event_type" despite the struct being present and documented. Enforced keys
  are no longer tracked separately either: `struct!/2` already enforces
  `@enforce_keys`, so the second map bought nothing but a drift surface.

  Each event source file is registered as an `@external_resource`, so adding
  or removing one recompiles this module.

  ## Decoding rules

    * A map whose `__struct__` matches the registered module is returned
      as-is (already-typed pass-through).
    * A map with a different `__struct__` raises `ArgumentError` (mismatch).
    * A plain map (no `__struct__`) is translated by iterating ONLY over
      the declared struct fields and looking each up by atom-or-string key
      in the input map. Missing enforced fields raise. Unknown input keys
      raise. Arbitrary input is never atomized.
  """

  # ------------------------------------------------------------------
  # Compile-time registry derivation
  # ------------------------------------------------------------------

  @events_glob Path.join([__DIR__, "events", "**", "*.ex"])

  @event_sources @events_glob |> Path.wildcard() |> Enum.sort()

  for source <- @event_sources do
    @external_resource source
  end

  # `@external_resource` only forces a recompile when a file already in the
  # list changes. A brand-new event source is not in that list, so without
  # this hook `mix compile` would leave the derived registry stale and the new
  # event would silently fail to decode. `__mix_recompile__?/0` is Mix's
  # supported escape hatch for compile-time state derived from a glob.
  @event_sources_fingerprint :erlang.md5(Enum.join(@event_sources, "\n"))

  @doc false
  def __mix_recompile__? do
    current = @events_glob |> Path.wildcard() |> Enum.sort()
    :erlang.md5(Enum.join(current, "\n")) != @event_sources_fingerprint
  end

  # Each event source yields {event_type, module, enforce_keys}. Both the
  # type->module registry and the enforced-key lookup come from this single
  # scan, so neither can drift from the structs on disk.
  @event_specs (@event_sources
                |> Enum.map(&File.read!/1)
                |> Enum.filter(&String.contains?(&1, "defstruct"))
                |> Enum.flat_map(fn body ->
                  enforce_keys =
                    case Regex.run(~r/@enforce_keys\s*\[([^\]]*)\]/, body) do
                      [_full, inner] ->
                        ~r/:([a-z_][A-Za-z0-9_]*[?!]?)/
                        |> Regex.scan(inner)
                        |> Enum.map(fn [_, key] -> String.to_atom(key) end)

                      nil ->
                        []
                    end

                  ~r/defmodule\s+ForemanServer\.Events\.([A-Za-z0-9_]+)\s+do/
                  |> Regex.scan(body)
                  |> Enum.map(fn [_full, short_name] ->
                    {short_name, Module.concat(ForemanServer.Events, short_name), enforce_keys}
                  end)
                end))

  @registry Map.new(@event_specs, fn {type, module, _keys} -> {type, module} end)

  @enforce_keys_registry Map.new(@event_specs, fn {_type, module, keys} -> {module, keys} end)

  if map_size(@registry) == 0 do
    raise CompileError,
      description:
        "ForemanServer.EventCodec derived an empty event registry from " <>
          "#{@events_glob}. The glob or the events directory layout changed."
  end

  @type event_type :: String.t()
  @type data :: map()
  @type typed_event :: struct()

  @doc """
  Strictly decode a persisted event into its typed struct.

  Raises `ArgumentError` if `event_type` is not registered, the data
  carries a mismatched struct, an enforced key is missing, or an input
  key does not correspond to a declared struct field.
  """
  @spec decode!(event_type(), data()) :: typed_event()
  def decode!(event_type, data) when is_binary(event_type) and is_map(data) do
    module = registered_module!(event_type)

    case data do
      %{__struct__: ^module} = struct ->
        struct

      %{__struct__: other_module} ->
        raise ArgumentError,
              "EventCodec mismatch: event_type=#{inspect(event_type)} expects " <>
                "#{inspect(module)}, got #{inspect(other_module)}"

      plain_map when is_map(plain_map) ->
        build_struct(module, plain_map, event_type)
    end
  end

  def decode!(event_type, data) do
    raise ArgumentError,
          "ForemanServer.EventCodec.decode!/2 expects (binary, map); got " <>
            "(#{inspect(event_type)}, #{inspect(data)})"
  end

  @doc "Decode from a `%RecordedEvent{}` (replay path)."
  @spec decode_recorded!(struct()) :: typed_event()
  def decode_recorded!(%{event_type: type, data: data}), do: decode!(type, data)

  @doc "Registered event types. Diagnostic only."
  @spec registered() :: [event_type()]
  def registered, do: Map.keys(@registry)

  # ------------------------------------------------------------------
  # Internal
  # ------------------------------------------------------------------

  defp registered_module!(event_type) do
    case Map.fetch(@registry, event_type) do
      {:ok, module} ->
        module

      :error ->
        raise ArgumentError,
              "ForemanServer.EventCodec: unregistered event_type #{inspect(event_type)}. " <>
                "The registry is derived from lib/foreman_server/events/ at compile time, " <>
                "so add a module ForemanServer.Events.#{event_type} declaring a defstruct."
    end
  end

  defp build_struct(module, plain_map, event_type) do
    struct_keys = struct_field_names(module)
    enforce_keys = Map.fetch!(@enforce_keys_registry, module)
    declared_atom_keys = struct_keys
    declared_string_keys = Enum.map(struct_keys, &Atom.to_string/1)

    reject_duplicate_forms!(plain_map, declared_string_keys, event_type)
    reject_unknown_keys!(plain_map, declared_atom_keys, declared_string_keys, event_type)

    # Build pairs ONLY for fields actually present in the input. Absent
    # fields keep their declared default via `struct!/2`.
    pairs =
      plain_map
      |> Enum.flat_map(fn
        {:__struct__, _} ->
          []

        {k, v} when is_atom(k) ->
          if Enum.member?(declared_atom_keys, k), do: [{k, v}], else: []

        {k, v} when is_binary(k) ->
          if Enum.member?(declared_string_keys, k) do
            # Safe: we verified k is one of our declared string keys, so
            # the corresponding atom is guaranteed to exist.
            [{String.to_existing_atom(k), v}]
          else
            []
          end

        _ ->
          []
      end)

    missing_enforced = enforce_keys -- Keyword.keys(pairs)

    case missing_enforced do
      [] ->
        :ok

      keys ->
        raise ArgumentError,
              "EventCodec: event_type=#{inspect(event_type)} missing enforced keys: " <>
                "#{inspect(keys)}"
    end

    struct!(module, pairs)
  end

  defp reject_duplicate_forms!(plain_map, declared_string_keys, event_type) do
    duplicates =
      plain_map
      |> Map.keys()
      |> Enum.flat_map(fn
        k when is_atom(k) ->
          string_form = Atom.to_string(k)

          if string_form in declared_string_keys and Map.has_key?(plain_map, string_form) do
            [k]
          else
            []
          end

        _ ->
          []
      end)

    case duplicates do
      [] ->
        :ok

      keys ->
        raise ArgumentError,
              "EventCodec: event_type=#{inspect(event_type)} contains both atom and " <>
                "string forms of: #{inspect(keys)}"
    end
  end

  defp reject_unknown_keys!(plain_map, declared_atom_keys, declared_string_keys, event_type) do
    unknown_keys =
      plain_map
      |> Map.keys()
      |> Enum.reject(fn
        :__struct__ -> true
        k when is_atom(k) -> k in declared_atom_keys
        k when is_binary(k) -> k in declared_string_keys
        _ -> false
      end)

    case unknown_keys do
      [] ->
        :ok

      keys ->
        raise ArgumentError,
              "EventCodec: event_type=#{inspect(event_type)} has unknown fields: " <>
                "#{inspect(keys)}; declared: #{inspect(declared_atom_keys)}"
    end
  end

  defp struct_field_names(module) do
    module.__struct__()
    |> Map.from_struct()
    |> Map.keys()
  end
end
