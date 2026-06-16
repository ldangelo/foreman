defmodule ForemanServer.WorkflowInterpreter do
  @moduledoc "Loads Foreman workflow YAML into Elixir run/phase state-machine specs."

  alias ForemanServer.{EventStore, RunActor}

  @type phase :: map()
  @type workflow :: map()

  @spec load_file(String.t()) :: {:ok, workflow()} | {:error, term()}
  def load_file(path) when is_binary(path) do
    with {:ok, content} <- File.read(path) do
      load_yaml(content)
    end
  end

  @spec load_yaml(String.t()) :: {:ok, workflow()} | {:error, term()}
  def load_yaml(content) when is_binary(content) do
    content
    |> parse_foreman_yaml()
    |> compile()
  end

  @spec compile(map()) :: {:ok, workflow()} | {:error, term()}
  def compile(%{} = raw) do
    phases = Enum.map(Map.get(raw, :phases, []), &normalize_phase/1)

    if phases == [] do
      {:error, :workflow_requires_phases}
    else
      {:ok,
       %{
         name: Map.get(raw, :name, "workflow"),
         phase_order: Enum.map(phases, & &1.name),
         phases: phases,
         models: Map.new(phases, &{&1.name, &1.models}),
         retry_rules: retry_rules(phases),
         artifacts: Map.new(phases, &{&1.name, &1.artifact}),
         mail_hooks: Map.new(phases, &{&1.name, &1.mail}),
         builtins: Enum.filter(phases, &builtin_phase?/1),
         task_phases: Map.get(raw, :task_phases, []),
         final_phases: Map.get(raw, :final_phases, [])
       }}
    end
  end

  @spec start_run(String.t(), workflow(), map()) :: {:ok, pid()} | {:error, term()}
  def start_run(run_id, workflow, opts \\ %{}) do
    RunActor.start_run(%{
      run_id: run_id,
      task_id: Map.get(opts, :task_id),
      phases: workflow.phase_order,
      max_retries: max_retry(workflow.retry_rules)
    })
  end

  @spec execute_phase(String.t(), phase(), map()) :: {:ok, map()} | {:error, term()}
  def execute_phase(run_id, phase, context \\ %{})

  def execute_phase(run_id, %{name: phase_id, command: command} = phase, context)
      when is_binary(command) do
    if String.starts_with?(command, "/") do
      complete_builtin(run_id, phase_id, phase, context)
    else
      {output, exit_code} = System.cmd("sh", ["-c", command], stderr_to_stdout: true)
      event_type = if exit_code == 0, do: "PhaseCompleted", else: "PhaseFailed"

      append_phase_event(run_id, event_type, %{
        run_id: run_id,
        phase_id: phase_id,
        output: output,
        exit_code: exit_code,
        artifact_paths: List.wrap(phase.artifact),
        report_paths: List.wrap(phase.artifact),
        kind: "bash"
      })
    end
  end

  def execute_phase(run_id, %{name: phase_id, prompt: prompt} = phase, _context) do
    append_phase_event(run_id, "PhaseCompleted", %{
      run_id: run_id,
      phase_id: phase_id,
      output: "prompt phase prepared: #{prompt}",
      exit_code: 0,
      artifact_paths: List.wrap(phase.artifact),
      report_paths: List.wrap(phase.artifact),
      kind: "prompt"
    })
  end

  defp complete_builtin(run_id, phase_id, phase, _context) do
    append_phase_event(run_id, "PhaseCompleted", %{
      run_id: run_id,
      phase_id: phase_id,
      output: "builtin #{phase.command} prepared",
      exit_code: 0,
      artifact_paths: List.wrap(phase.artifact),
      report_paths: List.wrap(phase.artifact),
      kind: "builtin"
    })
  end

  defp append_phase_event(run_id, event_type, payload) do
    with {:ok, event} <-
           EventStore.append(%{
             stream_id: "run:#{run_id}",
             event_type: event_type,
             payload: payload,
             metadata: %{correlation_id: run_id}
           }) do
      {:ok, %{event: event, payload: payload}}
    end
  end

  defp normalize_phase(raw) do
    %{
      name: Map.fetch!(raw, :name),
      prompt: Map.get(raw, :prompt),
      command: Map.get(raw, :command),
      models: Map.get(raw, :models, %{}),
      retry_with: Map.get(raw, :retry_with),
      retry_on_fail: Map.get(raw, :retry_on_fail, 0),
      artifact: Map.get(raw, :artifact),
      mail: Map.get(raw, :mail, %{}),
      tools: Map.get(raw, :tools, %{}),
      max_turns: Map.get(raw, :max_turns),
      verdict: Map.get(raw, :verdict, false)
    }
  end

  defp retry_rules(phases) do
    phases
    |> Enum.filter(&(&1.retry_with || &1.retry_on_fail > 0))
    |> Map.new(&{&1.name, %{retry_with: &1.retry_with, retry_on_fail: &1.retry_on_fail}})
  end

  defp max_retry(rules) do
    rules
    |> Map.values()
    |> Enum.map(& &1.retry_on_fail)
    |> Enum.max(fn -> 0 end)
  end

  defp builtin_phase?(phase),
    do: is_binary(phase.command) and String.starts_with?(phase.command, "/")

  defp parse_foreman_yaml(content) do
    lines =
      content
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == "" or String.trim(&1) |> String.starts_with?("#")))

    {root, _section, phase, _nested} =
      Enum.reduce(lines, {%{phases: []}, nil, nil, nil}, fn line,
                                                            {root, section, phase, nested} ->
        trimmed = String.trim(line)
        indent = String.length(line) - String.length(String.trim_leading(line))

        cond do
          indent == 0 and String.ends_with?(trimmed, ":") ->
            {flush_phase(root, phase), String.trim_trailing(trimmed, ":") |> key(), nil, nil}

          indent == 0 and String.contains?(trimmed, ":") ->
            {k, v} = split_pair(trimmed)
            {root |> flush_phase(phase) |> Map.put(key(k), scalar(v)), nil, nil, nil}

          section == :phases and String.starts_with?(trimmed, "- ") ->
            new_phase = trimmed |> String.trim_leading("- ") |> pair_to_map()
            {flush_phase(root, phase), section, new_phase, nil}

          section in [:task_phases, :final_phases] and String.starts_with?(trimmed, "- ") ->
            value = trimmed |> String.trim_leading("- ") |> scalar()
            {Map.update(root, section, [value], &(&1 ++ [value])), section, phase, nested}

          section == :phases and phase != nil and indent >= 4 and String.ends_with?(trimmed, ":") ->
            {root, section, phase, key(String.trim_trailing(trimmed, ":"))}

          section == :phases and phase != nil and indent >= 4 and String.contains?(trimmed, ":") ->
            {k, v} = split_pair(trimmed)
            k = key(k)
            value = scalar(v)

            next_phase =
              if nested do
                Map.update(phase, nested, %{k => value}, &Map.put(&1, k, value))
              else
                Map.put(phase, k, value)
              end

            {root, section, next_phase, nested}

          true ->
            {root, section, phase, nested}
        end
      end)

    flush_phase(root, phase)
  end

  defp flush_phase(root, nil), do: root
  defp flush_phase(root, phase), do: Map.update!(root, :phases, &(&1 ++ [phase]))

  defp pair_to_map(text) do
    if String.contains?(text, ":") do
      {k, v} = split_pair(text)
      %{key(k) => scalar(v)}
    else
      %{name: scalar(text)}
    end
  end

  defp split_pair(text) do
    [k, v] = String.split(text, ":", parts: 2)
    {String.trim(k), String.trim(v)}
  end

  defp key(value) do
    value
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp scalar(""), do: %{}
  defp scalar("true"), do: true
  defp scalar("false"), do: false

  defp scalar(value) do
    cond do
      String.starts_with?(value, "[") and String.ends_with?(value, "]") ->
        value
        |> String.trim_leading("[")
        |> String.trim_trailing("]")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)

      String.match?(value, ~r/^\d+$/) ->
        String.to_integer(value)

      true ->
        String.trim(value, "\"")
    end
  end
end
