defmodule Workflow.MissingRequiredPhaseError do
  defexception [:message]
end

defmodule ForemanServer.Workflow.Interpreter do
  @moduledoc """
  Loads workflow YAML files and validates their required phase structure.
  """
  @required_top_level_keys ~w(name phases)
  @required_phase_keys ~w(name)
  @allowed_phase_actions ~w(prompt command bash)
  @spec load(Path.t()) :: {:ok, map()} | {:error, term()}

  def load(path) when is_binary(path) do
    try do
      load!(path)
    rescue
      e in [
        File.Error,
        ArgumentError,
        KeyError,
        CaseClauseError,
        Workflow.MissingRequiredPhaseError
      ] ->
        {:error, {:manifest_load_failed, path, Exception.message(e)}}
    end
  end

  @spec load!(Path.t()) :: {:ok, map()}
  def load!(path) when is_binary(path) do
    unless File.regular?(path) do
      raise ArgumentError, "workflow template not found: #{path}"
    end

    workflow =
      path
      |> File.read!()
      |> parse_yaml!(path)

    validate_required_fields!(workflow, path)
    {:ok, workflow}
  end

  defp parse_yaml!(contents, path) do
    contents
    |> tokenize_lines()
    |> parse_root!(path)
  end

  defp tokenize_lines(contents) do
    contents
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce([], fn {line, line_number}, acc ->
      trimmed = String.trim(line)

      if trimmed == "" or String.starts_with?(trimmed, "#") do
        acc
      else
        [
          %{
            indent: indent_width(line),
            content: String.trim_leading(line),
            line: line_number
          }
          | acc
        ]
      end
    end)
    |> Enum.reverse()
  end

  defp parse_root!(lines, path) do
    {workflow, remaining} = parse_root_entries(lines, %{}, path)

    case remaining do
      [] ->
        workflow

      [%{line: line_number}] ->
        raise ArgumentError,
              "unsupported YAML content in #{path} at line #{line_number}; expected a top-level mapping"
    end
  end

  defp parse_root_entries([%{indent: 0, content: content} | rest], acc, path) do
    case split_mapping(content) do
      {"phases", ""} ->
        {phases, remaining} = parse_phase_entries(rest, [], path)
        parse_root_entries(remaining, Map.put(acc, "phases", phases), path)

      {key, value} ->
        parse_root_entries(rest, Map.put(acc, key, parse_scalar(value)), path)

      :error ->
        raise ArgumentError, "unsupported top-level YAML entry in #{path}: #{content}"
    end
  end

  defp parse_root_entries([], acc, _path), do: {acc, []}
  defp parse_root_entries(lines, acc, _path), do: {acc, lines}

  defp parse_phase_entries(
         [%{indent: 2, content: "- " <> content, line: line_number} | rest],
         acc,
         path
       ) do
    phase = parse_phase_head!(content, line_number, path)
    {complete_phase, remaining} = parse_phase_properties(rest, phase, path)
    parse_phase_entries(remaining, [complete_phase | acc], path)
  end

  defp parse_phase_entries(lines, acc, _path), do: {Enum.reverse(acc), lines}

  defp parse_phase_head!(content, line_number, path) do
    case split_mapping(content) do
      {key, value} ->
        Map.put(%{}, key, parse_scalar(value))

      :error ->
        raise ArgumentError,
              "unsupported phase entry in #{path} at line #{line_number}: #{content}"
    end
  end

  defp parse_phase_properties(
         [%{indent: 4, content: content, line: line_number} | rest],
         acc,
         path
       ) do
    case split_mapping(content) do
      {key, ""} ->
        {nested_map, remaining} = parse_nested_map(rest, %{}, 6, path)
        parse_phase_properties(remaining, Map.put(acc, key, nested_map), path)

      {key, value} ->
        parse_phase_properties(rest, Map.put(acc, key, parse_scalar(value)), path)

      :error ->
        raise ArgumentError,
              "unsupported phase property in #{path} at line #{line_number}: #{content}"
    end
  end

  defp parse_phase_properties(lines, acc, _path), do: {acc, lines}

  defp parse_nested_map(
         [%{indent: expected_indent, content: content, line: line_number} | rest],
         acc,
         expected_indent,
         path
       ) do
    case split_mapping(content) do
      {key, value} ->
        parse_nested_map(rest, Map.put(acc, key, parse_scalar(value)), expected_indent, path)

      :error ->
        raise ArgumentError,
              "unsupported nested YAML entry in #{path} at line #{line_number}: #{content}"
    end
  end

  defp parse_nested_map(lines, acc, _expected_indent, _path), do: {acc, lines}

  defp validate_required_fields!(workflow, path) do
    missing_top_level_keys =
      Enum.filter(@required_top_level_keys, fn key ->
        missing_or_blank?(Map.get(workflow, key))
      end)

    phases = Map.get(workflow, "phases")

    cond do
      missing_top_level_keys != [] ->
        raise Workflow.MissingRequiredPhaseError,
          message:
            "workflow template #{path} must define top-level keys \"name\" and \"phases\", and \"phases\" must contain at least one entry with a \"name\" key"

      not is_list(phases) ->
        raise Workflow.MissingRequiredPhaseError,
          message:
            "workflow template #{path} must define \"phases\" as a list of named phase entries"

      true ->
        validate_phases!(phases, path)
    end
  end

  defp validate_phases!(phases, path) do
    named_count =
      Enum.count(phases, fn phase -> is_map(phase) and present?(Map.get(phase, "name")) end)

    if named_count == 0 do
      raise Workflow.MissingRequiredPhaseError,
        message:
          "workflow template #{path} must define at least one phase entry with a \"name\" key"
    end

    phases
    |> Enum.with_index()
    |> Enum.each(fn {phase, index} -> validate_phase!(phase, index, path) end)
  end

  defp validate_phase!(phase, index, path) do
    cond do
      not is_map(phase) ->
        raise Workflow.MissingRequiredPhaseError,
          message:
            "workflow template #{path} phase #{index} must be a mapping with a \"name\" key"

      true ->
        missing_required =
          Enum.filter(@required_phase_keys, fn key ->
            missing_or_blank?(Map.get(phase, key))
          end)

        if missing_required != [] do
          raise Workflow.MissingRequiredPhaseError,
            message:
              "workflow template #{path} phase #{index} must define a non-empty \"name\" key"
        else
          validate_phase_actions!(phase, index, path)
          validate_worktree!(phase, index, path)
        end
    end
  end

  defp validate_worktree!(phase, index, path) do
    case Map.get(phase, "worktree") do
      nil ->
        :ok

      worktree when is_map(worktree) ->
        validate_worktree_map!(phase, index, path, worktree)

      _other ->
        raise Workflow.MissingRequiredPhaseError,
          message:
            "workflow template #{path} phase #{index} (#{phase["name"]}) \"worktree\" must be a mapping"
    end
  end

  defp validate_worktree_map!(phase, index, path, worktree) do
    case Map.get(worktree, "enabled") do
      nil ->
        :ok

      true ->
        :ok

      false ->
        :ok

      "true" ->
        :ok

      "false" ->
        :ok

      _other ->
        raise Workflow.MissingRequiredPhaseError,
          message:
            "workflow template #{path} phase #{index} (#{phase["name"]}) \"worktree.enabled\" must be a boolean"
    end

    validate_worktree_string_field!(worktree, "base", phase, index, path)
    validate_worktree_string_field!(worktree, "branch", phase, index, path)
    validate_worktree_path!(worktree, phase, index, path)
    validate_worktree_cleanup!(worktree, phase, index, path)
    :ok
  end

  defp validate_worktree_string_field!(worktree, key, phase, index, path) do
    case Map.get(worktree, key) do
      nil ->
        :ok

      "" ->
        raise Workflow.MissingRequiredPhaseError,
          message:
            "workflow template #{path} phase #{index} (#{phase["name"]}) \"worktree.#{key}\" must be a non-empty string"

      value when is_binary(value) ->
        :ok

      _other ->
        raise Workflow.MissingRequiredPhaseError,
          message:
            "workflow template #{path} phase #{index} (#{phase["name"]}) \"worktree.#{key}\" must be a non-empty string"
    end
  end

  defp validate_worktree_path!(worktree, phase, index, path) do
    case Map.get(worktree, "path") do
      nil ->
        :ok

      "" ->
        raise Workflow.MissingRequiredPhaseError,
          message:
            "workflow template #{path} phase #{index} (#{phase["name"]}) \"worktree.path\" must be a non-empty relative path (no leading slash, no \"..\" traversal)"

      value when is_binary(value) ->
        cond do
          String.starts_with?(value, "/") ->
            raise Workflow.MissingRequiredPhaseError,
              message:
                "workflow template #{path} phase #{index} (#{phase["name"]}) \"worktree.path\" must be relative (absolute paths rejected)"

          path_has_traversal?(value) ->
            raise Workflow.MissingRequiredPhaseError,
              message:
                "workflow template #{path} phase #{index} (#{phase["name"]}) \"worktree.path\" must not contain \"..\" traversal"

          true ->
            :ok
        end

      _other ->
        raise Workflow.MissingRequiredPhaseError,
          message:
            "workflow template #{path} phase #{index} (#{phase["name"]}) \"worktree.path\" must be a non-empty relative path"
    end
  end

  defp path_has_traversal?(value) do
    value
    |> Path.split()
    |> Enum.any?(fn segment -> segment == ".." end)
  end

  defp validate_worktree_cleanup!(worktree, phase, index, path) do
    case Map.get(worktree, "cleanup") do
      nil ->
        :ok

      value when value in ["always", "never"] ->
        :ok

      _other ->
        raise Workflow.MissingRequiredPhaseError,
          message:
            "workflow template #{path} phase #{index} (#{phase["name"]}) \"worktree.cleanup\" must be one of: always, never"
    end
  end

  defp validate_phase_actions!(phase, index, path) do
    actions =
      @allowed_phase_actions
      |> Enum.filter(fn action -> present?(Map.get(phase, action)) end)

    case actions do
      [] ->
        raise Workflow.MissingRequiredPhaseError,
          message:
            "workflow template #{path} phase #{index} (#{phase["name"]}) must define exactly one of: prompt, command, bash"

      [single] ->
        validate_phase_action_value!(phase, index, single, path)

      _multiple ->
        raise Workflow.MissingRequiredPhaseError,
          message:
            "workflow template #{path} phase #{index} (#{phase["name"]}) must define exactly one of: prompt, command, bash (found #{length(actions)})"
    end
  end

  defp validate_phase_action_value!(phase, index, action, path) do
    value = Map.get(phase, action)

    case action do
      "command" ->
        unless is_binary(value) and String.starts_with?(value, "/") do
          raise Workflow.MissingRequiredPhaseError,
            message:
              "workflow template #{path} phase #{index} (#{phase["name"]}) \"command\" must be a non-empty slash invocation beginning with \"/\""
        end

      "bash" ->
        :ok

      _ ->
        :ok
    end

    validate_required_file_key!(phase, index, path)
  end

  defp validate_required_file_key!(phase, index, path) do
    case Map.get(phase, "requiredFile") do
      nil ->
        :ok

      "" ->
        raise Workflow.MissingRequiredPhaseError,
          message:
            "workflow template #{path} phase #{index} (#{phase["name"]}) \"requiredFile\" must be a non-empty dotted context key"

      key when is_binary(key) ->
        validate_dotted_key!(key, phase, index, path)

      _other ->
        raise Workflow.MissingRequiredPhaseError,
          message:
            "workflow template #{path} phase #{index} (#{phase["name"]}) \"requiredFile\" must be a non-empty dotted context key"
    end
  end

  defp validate_dotted_key!(key, phase, index, path) do
    segments = String.split(key, ".")

    cond do
      segments == [] ->
        raise Workflow.MissingRequiredPhaseError,
          message:
            "workflow template #{path} phase #{index} (#{phase["name"]}) \"requiredFile\" must be a non-empty dotted context key"

      Enum.any?(segments, fn segment -> segment == "" end) ->
        raise Workflow.MissingRequiredPhaseError,
          message:
            "workflow template #{path} phase #{index} (#{phase["name"]}) \"requiredFile\" must be a non-empty dotted context key with no empty segments"

      true ->
        :ok
    end
  end

  defp split_mapping(content) do
    case String.split(content, ":", parts: 2) do
      [key, value] ->
        {String.trim(key), String.trim_leading(value)}

      _other ->
        :error
    end
  end

  defp parse_scalar(value) do
    value
    |> strip_quotes()
    |> cast_scalar()
  end

  defp strip_quotes(value) do
    if String.length(value) >= 2 and
         ((String.starts_with?(value, "\"") and String.ends_with?(value, "\"")) or
            (String.starts_with?(value, "'") and String.ends_with?(value, "'"))) do
      value
      |> String.slice(1, String.length(value) - 2)
    else
      value
    end
  end

  defp cast_scalar("true"), do: true
  defp cast_scalar("false"), do: false

  defp cast_scalar(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> value
    end
  end

  defp missing_or_blank?(value) when value in [nil, ""], do: true
  defp missing_or_blank?([]), do: true
  defp missing_or_blank?(_value), do: false

  defp present?(value), do: not missing_or_blank?(value)

  defp indent_width(line) do
    line
    |> String.to_charlist()
    |> Enum.take_while(fn character -> character == ?\s end)
    |> length()
  end
end

defmodule Workflow.Interpreter do
  @moduledoc false

  defdelegate load!(path), to: ForemanServer.Workflow.Interpreter
end
