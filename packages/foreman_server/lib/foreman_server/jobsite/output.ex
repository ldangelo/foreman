defmodule ForemanServer.Jobsite.Output do
  @moduledoc """
  Structured output extraction from an agent's final iteration text.

  `extract/2` finds the LAST `<tag>…</tag>` pair (last, not first, so a tag
  quoted in earlier reasoning does not win) and, for `object/1`, decodes it
  as JSON and validates it against the given Zoi schema.
  """

  alias ForemanServer.Jobsite.Error

  @enforce_keys [:kind, :tag]
  @type kind :: :object | :string
  @type t :: %__MODULE__{kind: kind(), tag: String.t(), schema: Zoi.schema() | nil, max_retries: non_neg_integer()}
  defstruct [:kind, :tag, :schema, max_retries: 0]

  @doc "A JSON object extracted from `<tag>…</tag>` and validated against `schema` (a Zoi schema)."
  @spec object(keyword()) :: t()
  def object(opts) do
    %__MODULE__{
      kind: :object,
      tag: Keyword.fetch!(opts, :tag),
      schema: Keyword.fetch!(opts, :schema),
      max_retries: Keyword.get(opts, :max_retries, 0)
    }
  end

  @doc "Raw text extracted from `<tag>…</tag>`, trimmed, with no further decoding."
  @spec string(keyword()) :: t()
  def string(opts) do
    %__MODULE__{kind: :string, tag: Keyword.fetch!(opts, :tag), max_retries: Keyword.get(opts, :max_retries, 0)}
  end

  @spec extract(t(), String.t()) :: {:ok, term()} | {:error, Error.t()}
  def extract(%__MODULE__{tag: tag} = spec, text) do
    pattern = ~r/<#{Regex.escape(tag)}>(.*?)<\/#{Regex.escape(tag)}>/s

    case Regex.scan(pattern, text) do
      [] ->
        {:error, Error.new(:output_tag_missing, "no <#{tag}> tag found in output", %{tag: tag})}

      matches ->
        [_full, captured] = List.last(matches)
        decode(spec, String.trim(captured))
    end
  end

  defp decode(%__MODULE__{kind: :string}, captured), do: {:ok, captured}

  defp decode(%__MODULE__{kind: :object, schema: schema, tag: tag}, captured) do
    with {:ok, decoded} <- Jason.decode(captured),
         {:ok, parsed} <- Zoi.parse(schema, atomize_known_keys(decoded, schema)) do
      {:ok, parsed}
    else
      {:error, reason} ->
        {:error,
         Error.new(:output_invalid, "output failed validation", %{tag: tag, raw_matched: captured, reason: inspect(reason)})}
    end
  end

  # `Jason.decode/1` produces string keys; a `Zoi.object/1` schema declares
  # atom keys. Rather than `Jason.decode(text, keys: :atoms)` — which mints a
  # new atom for every distinct key an agent ever emits, an unbounded-growth
  # hazard since the input is model-generated — convert only the keys the
  # schema already declares (existing, compiled-time atoms) and leave any
  # other key as a string, which `Zoi.parse/2` then rejects as unrecognized.
  defp atomize_known_keys(%{} = map, %Zoi.Types.Map{fields: fields}) do
    known = Map.new(fields, fn {key, _schema} -> {Atom.to_string(key), key} end)
    Map.new(map, fn {k, v} -> {Map.get(known, k, k), v} end)
  end

  defp atomize_known_keys(value, _schema), do: value
end
