defmodule ForemanServer.Workflow.ManifestWriter do
  @moduledoc """
  Canonical serializer for workflow manifests.

  Emits manifests that the `Interpreter` can parse back, enforcing the
  structural constraints of the manifest DSL:

    * Top-level: only scalar keys (`name`, `description`) plus `phases:`
    * `phases:` at indent 0 with a YAML list of phase entries
    * Phase entries at indent 1 (`- name: ...`)
    * Phase properties at indent 2
    * Single-level nested maps at indent 3

  Any input requiring a construct outside the above (deeply-nested maps,
  lists as property values, extra top-level maps) is rejected with an
  `{:error, {:unsupported_construct, detail}}` tuple.
  """

  @required_top_level_keys ["name", "phases"]

  @typep error_detail ::
           {:top_level_list
            | :top_level_map
            | :missing_required
            | :phase_not_map
            | :phase_missing_name
            | :phase_empty_name
            | :list_at_phase_property
            | :deep_nesting, term()}

  @typep error_reason :: {:unsupported_construct, error_detail()}

  @doc """
  Serialize a manifest map to a canonical YAML string.

  Returns `{:ok, yaml_string}` when the input conforms to the manifest DSL,
  or `{:error, {:unsupported_construct, detail}}` when a non-serializable
  construct is encountered.
  """
  @spec write(map()) :: {:ok, String.t()} | {:error, error_reason()}
  def write(manifest) when is_map(manifest) do
    with {:ok, :ok} <- validate_required_keys(manifest),
         {:ok, :ok} <- validate_top_level_structure(manifest),
         {:ok, :ok} <- validate_phases(manifest["phases"]) do
      {:ok, build_yaml(manifest)}
    else
      {:ok, {:error, _} = e} -> e
      {:error, _} = e -> e
    end
  end

  # --- Validation ---

  defp validate_required_keys(manifest) do
    case Enum.find(@required_top_level_keys, fn key ->
           not Map.has_key?(manifest, key) or blank?(manifest[key])
         end) do
      nil -> {:ok, :ok}
      missing -> {:error, {:unsupported_construct, {:missing_required, missing}}}
    end
  end

  defp blank?(""), do: true
  defp blank?(nil), do: true
  defp blank?(_), do: false

  defp validate_top_level_structure(manifest) do
    result =
      manifest
      |> Map.drop(@required_top_level_keys)
      |> Enum.find_value(:ok, fn
        {_key, value} when is_binary(value) or is_number(value) or is_boolean(value) ->
          false

        {key, value} when is_list(value) ->
          {:error, {:unsupported_construct, {:top_level_list, key}}}

        {key, value} when is_map(value) ->
          {:error, {:unsupported_construct, {:top_level_map, key}}}
      end)

    {:ok, result}
  end

  defp validate_phases(nil), do: {:ok, :ok}

  defp validate_phases(phases) when is_list(phases) do
    result =
      phases
      |> Enum.with_index()
      |> Enum.find_value(:ok, fn
        {phase, index} when is_map(phase) ->
          validate_phase(phase, index)

        {_not_map, index} ->
          {:error, {:unsupported_construct, {:phase_not_map, index}}}
      end)

    {:ok, result}
  end

  defp validate_phase(phase, index) do
    name = phase["name"]

    cond do
      not Map.has_key?(phase, "name") or blank?(name) ->
        if name == "",
          do: {:error, {:unsupported_construct, {:phase_empty_name, index}}},
          else: {:error, {:unsupported_construct, {:phase_missing_name, index}}}

      true ->
        :ok
    end
    |> case do
      :ok -> validate_phase_properties(phase)
      error -> error
    end
  end

  defp validate_phase_properties(phase) do
    phase
    |> Map.drop(["name"])
    |> Enum.find_value(:ok, fn
      {_key, value} when is_binary(value) or is_number(value) or is_boolean(value) ->
        false

      {_key, %{} = v} ->
        validate_nested_map(v)

      {key, value} when is_list(value) ->
        {:error, {:unsupported_construct, {:list_at_phase_property, key}}}
    end)
  end

  defp validate_nested_map(map) do
    map
    |> Map.values()
    |> Enum.find_value(false, fn
      %{} -> {:error, {:unsupported_construct, {:deep_nesting, "nested_map"}}}
      _ -> false
    end)
  end

  # --- YAML building ---
  # Indent levels: 0 = 0 spaces, 1 = 2 spaces, 2 = 4 spaces,
  # 3 = 6 spaces, 4 = 8 spaces (per Interpreter.parse_nested_map expectations)

  defp build_yaml(manifest) do
    lines = []
    lines = append(lines, 0, "name: #{scalar(manifest["name"])}")
    lines = append(lines, 0, "description: #{scalar(manifest["description"] || "")}")
    lines = append(lines, 0, "phases:")

    manifest["phases"]
    |> Enum.reduce(lines, fn phase, acc ->
      build_phase(phase, acc)
    end)
    |> Enum.join("\n")
  end

  # Phase entries: `- name: <value>` at indent 1 (2 spaces)
  defp build_phase(phase, lines) do
    lines = append(lines, 1, "- name: #{scalar(phase["name"])}")

    phase
    |> Map.drop(["name"])
    |> Enum.reduce(lines, fn {key, value}, acc ->
      build_property(key, value, acc)
    end)
  end

  # Properties at indent 2 (4 spaces); nested maps at indent 3 (6 spaces)
  defp build_property(key, value, lines) do
    case value do
      v when is_binary(v) or is_number(v) or is_boolean(v) ->
        append(lines, 2, "#{key}: #{scalar(v)}")

      %{} = v ->
        acc = append(lines, 2, "#{key}:")

        Enum.reduce(v, acc, fn {k, vv}, acc2 ->
          append(acc2, 3, "#{k}: #{scalar(vv)}")
        end)
    end
  end

  defp append(lines, indent, content) do
    lines ++ [String.duplicate("  ", indent) <> content]
  end

  defp scalar(true), do: "true"
  defp scalar(false), do: "false"
  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_integer(value), do: Integer.to_string(value)
end
