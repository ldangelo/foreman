defmodule ForemanServer.Workflow.PromptRenderer do
  @moduledoc """
  Renders a workflow phase prompt template by substituting context variables.

  Substitution is a deterministic, single-pass scan: `{{key}}` tokens are
  replaced with `Map.get(context, :key) |> to_string()`. Unknown keys are
  left intact so a missing variable surfaces visibly in the rendered output
  rather than being silently dropped.
  """

  @variable_regex ~r/\{\{\s*([a-zA-Z_][a-zA-Z0-9_.]*)\s*\}\}/

  @spec render(Path.t() | String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def render(path, context) when is_binary(path) and is_map(context) do
    with {:ok, contents} <- File.read(path) do
      {:ok, substitute(contents, context)}
    end
  end

  def render_string(template, context) when is_binary(template) and is_map(context) do
    {:ok, substitute(template, context)}
  end

  defp substitute(template, context) do
    Regex.replace(@variable_regex, template, fn _, key ->
      lookup(context, key)
    end)
  end

  defp lookup(context, key) do
    cond do
      Map.has_key?(context, String.to_atom(key)) ->
        context |> Map.get(String.to_atom(key)) |> stringify()

      Map.has_key?(context, key) ->
        stringify(Map.get(context, key))

      true ->
        "{{" <> key <> "}}"
    end
  end

  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
