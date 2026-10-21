defmodule ForemanServer.Coordinator.Action do
  @moduledoc """
  The closed vocabulary of things a coordinator may ask Foreman to do, and the
  strict normaliser that turns one raw model-emitted JSON object into a typed
  `%Action{}`.

  The model proposes, Foreman disposes: an action is accepted only when its
  `kind` is in `kinds/0` and EVERY key is on that kind's whitelist with a value
  of the right type (AGENTS.md 5.4b: no pass-through of unknown keys). Anything
  else is `{:error, {:invalid_action, reason}}`; nothing outside this module
  can add a command the coordinator is able to run.

  `id` is deterministic: `sha256(project_id, trigger_key, canonical action)`,
  where `trigger_key` is the id of the first message the turn consumes. The
  same action re-emitted by a re-run of an interrupted turn therefore gets the
  same id, and every command id derived from it (`Coordinator.Executor`) makes
  re-execution a no-op.

  Params are string-keyed maps: the same shape live and after an event replay.
  """

  @enforce_keys [:id, :kind, :params]
  @type kind ::
          :answer
          | :ask
          | :start_thread
          | :propose_threads
          | :approve_proposed
          | :route_followup
          | :remember
          | :forget
          | :set_tuning
          | :add_repo
          | :schedule
  @type t :: %__MODULE__{id: String.t(), kind: kind(), params: %{String.t() => term()}}
  defstruct [:id, :kind, :params]

  @kinds ~w(answer ask start_thread propose_threads approve_proposed route_followup
            remember forget set_tuning add_repo schedule)a
  @kind_names Map.new(@kinds, &{Atom.to_string(&1), &1})

  @tuning_keys ~w(propose_before_start max_active_threads reuse_threads)

  @max_text 16_000
  @max_title 200
  @max_name 100
  @max_list 10

  @thread_spec %{
    "title" => {:text, @max_title, :required},
    "prompt" => {:text, @max_text, :required},
    "workflow" => {:text, @max_name, :optional},
    "task_type" => {:text, @max_name, :optional},
    "bead_id" => {:text, @max_name, :optional},
    "reuse_thread_id" => {:text, 200, :optional},
    "quote" => {:text, @max_text, :optional}
  }

  @specs %{
    answer: %{"text" => {:text, @max_text, :required}},
    ask: %{
      "question" => {:text, @max_text, :required},
      "options" => {:text_list, 8, :optional}
    },
    start_thread: @thread_spec,
    propose_threads: %{"threads" => {:objects, @thread_spec, :required}},
    approve_proposed: %{"task_ids" => {:text_list, @max_list, :required}},
    route_followup: %{
      "thread_id" => {:text, 200, :required},
      "message" => {:text, @max_text, :required}
    },
    remember: %{
      "name" => {:text, @max_name, :required},
      "description" => {:text, 500, :optional},
      "content" => {:text, @max_text, :required}
    },
    forget: %{"name" => {:text, @max_name, :required}},
    set_tuning: %{
      "key" => {{:enum, @tuning_keys}, :required},
      "value" => {:tuning_value, :required},
      "quote" => {:text, @max_text, :optional}
    },
    add_repo: %{
      "path" => {:text, 1_000, :required},
      "name" => {:text, @max_name, :optional},
      "quote" => {:text, @max_text, :optional}
    },
    schedule: %{
      "spec" => {:text, 500, :required},
      "prompt" => {:text, @max_text, :optional},
      "quote" => {:text, @max_text, :optional}
    }
  }

  @type reason ::
          :not_an_object
          | :missing_kind
          | {:unknown_kind, String.t()}
          | {:unknown_keys, kind(), [String.t()]}
          | {:invalid_param, kind(), String.t(), atom()}

  @doc "The closed set of action kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Tuning keys `set_tuning` accepts."
  @spec tuning_keys() :: [String.t()]
  def tuning_keys, do: @tuning_keys

  @doc """
  Normalise one raw (string- or atom-keyed) action object. `trigger_key`
  anchors the deterministic id (see moduledoc).
  """
  @spec normalize(term(), String.t(), String.t()) ::
          {:ok, t()} | {:error, {:invalid_action, reason()}}
  def normalize(raw, project_id, trigger_key) when is_map(raw) do
    raw = stringify(raw)

    with {:ok, kind} <- kind(raw),
         {:ok, params} <- params(kind, Map.delete(raw, "kind")) do
      {:ok,
       %__MODULE__{
         id: action_id(project_id, trigger_key, kind, params),
         kind: kind,
         params: params
       }}
    else
      {:error, reason} -> {:error, {:invalid_action, reason}}
    end
  end

  def normalize(_raw, _project_id, _trigger_key), do: {:error, {:invalid_action, :not_an_object}}

  @doc "Deterministic id of an action that failed normalisation (so it can still be recorded)."
  @spec rejected_id(term(), String.t(), String.t()) :: String.t()
  def rejected_id(raw, project_id, trigger_key),
    do: hash([project_id, trigger_key, "rejected", canonical(raw)])

  @doc "The `kind` string of a raw action for recording a rejection (never an atom conversion)."
  @spec raw_kind(term()) :: String.t()
  def raw_kind(%{} = raw) do
    case Map.get(stringify(raw), "kind") do
      kind when is_binary(kind) -> String.slice(kind, 0, 64)
      _ -> "unknown"
    end
  end

  def raw_kind(_raw), do: "unknown"

  # ------------------------------------------------------------------ internals

  defp kind(%{"kind" => name}) when is_binary(name) do
    case Map.fetch(@kind_names, name) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, {:unknown_kind, String.slice(name, 0, 64)}}
    end
  end

  defp kind(%{"kind" => _other}), do: {:error, :missing_kind}
  defp kind(_raw), do: {:error, :missing_kind}

  defp params(kind, raw) do
    spec = Map.fetch!(@specs, kind)

    case raw |> Map.keys() |> Enum.reject(&Map.has_key?(spec, &1)) |> Enum.sort() do
      [] -> validate_params(kind, spec, raw)
      unknown -> {:error, {:unknown_keys, kind, unknown}}
    end
  end

  defp validate_params(kind, spec, raw) do
    Enum.reduce_while(spec, {:ok, %{}}, fn {key, field}, {:ok, acc} ->
      case validate(field, Map.get(raw, key)) do
        {:ok, :absent} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, why} -> {:halt, {:error, {:invalid_param, kind, key, why}}}
      end
    end)
  end

  defp validate({:text, max, req}, value), do: text(value, max, req)
  defp validate({:text_list, max, req}, value), do: text_list(value, max, req)
  defp validate({{:enum, allowed}, req}, value), do: enum(value, allowed, req)
  defp validate({:tuning_value, req}, value), do: tuning_value(value, req)
  defp validate({:objects, spec, req}, value), do: objects(value, spec, req)

  defp absent(:required), do: {:error, :missing}
  defp absent(:optional), do: {:ok, :absent}

  defp text(nil, _max, req), do: absent(req)

  defp text(value, max, _req) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      not String.valid?(value) -> {:error, :invalid_encoding}
      trimmed == "" -> {:error, :blank}
      byte_size(trimmed) > max -> {:error, :too_long}
      true -> {:ok, trimmed}
    end
  end

  defp text(_value, _max, _req), do: {:error, :not_a_string}

  defp text_list(nil, _max, req), do: absent(req)

  defp text_list(values, max, _req) when is_list(values) do
    cond do
      values == [] -> {:error, :empty}
      length(values) > max -> {:error, :too_many}
      true -> collect(values, fn v -> text(v, @max_text, :required) end)
    end
  end

  defp text_list(_values, _max, _req), do: {:error, :not_a_list}

  defp enum(nil, _allowed, req), do: absent(req)

  defp enum(value, allowed, _req) do
    if is_binary(value) and Enum.member?(allowed, value),
      do: {:ok, value},
      else: {:error, :not_allowed}
  end

  defp tuning_value(nil, _req), do: {:ok, nil}
  defp tuning_value(value, _req) when is_boolean(value) or is_integer(value), do: {:ok, value}
  defp tuning_value(_value, _req), do: {:error, :invalid_value}

  defp objects(nil, _spec, req), do: absent(req)

  defp objects(values, spec, _req) when is_list(values) do
    cond do
      values == [] -> {:error, :empty}
      length(values) > @max_list -> {:error, :too_many}
      true -> collect(values, fn v -> object(v, spec) end)
    end
  end

  defp objects(_values, _spec, _req), do: {:error, :not_a_list}

  defp object(value, spec) when is_map(value) do
    raw = stringify(value)

    case raw |> Map.keys() |> Enum.reject(&Map.has_key?(spec, &1)) |> Enum.sort() do
      [] -> validate_params(:propose_threads, spec, raw)
      _unknown -> {:error, :unknown_keys}
    end
  end

  defp object(_value, _spec), do: {:error, :not_an_object}

  defp collect(values, fun) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, :absent} -> {:halt, {:error, :missing}}
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp action_id(project_id, trigger_key, kind, params),
    do: hash([project_id, trigger_key, Atom.to_string(kind), canonical(params)])

  defp hash(parts) do
    :crypto.hash(:sha256, Enum.intersperse(parts, <<0>>))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp canonical(term) do
    term |> sort_terms() |> inspect(limit: :infinity, printable_limit: :infinity)
  end

  defp sort_terms(%{} = map),
    do: map |> Enum.map(fn {k, v} -> {to_string(k), sort_terms(v)} end) |> Enum.sort()

  defp sort_terms(list) when is_list(list), do: Enum.map(list, &sort_terms/1)
  defp sort_terms(other), do: other

  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
