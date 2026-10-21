defmodule ForemanServer.ProjectSettings do
  @moduledoc """
  Typed read model of a project's settings, extracted from its projected
  `config` (see `ForemanServer.Aggregates.Project.Settings` for the write side).
  """

  @keys ForemanServer.Aggregates.Project.Settings.keys()

  @type t :: %__MODULE__{
          goal: String.t() | nil,
          instructions: String.t() | nil,
          thread_model: String.t() | nil,
          thread_effort: String.t() | nil,
          coordinator_provider: String.t() | nil,
          coordinator_model: String.t() | nil,
          coordinator_effort: String.t() | nil,
          max_concurrent_runs: pos_integer() | nil,
          daily_thread_cap: pos_integer() | nil,
          pr_auto_fix: map() | nil,
          coordinator_propose_before_start: boolean() | nil,
          coordinator_max_active_threads: pos_integer() | nil,
          coordinator_reuse_threads: boolean() | nil
        }

  defstruct @keys

  @doc "Setting keys (the whitelist table in `Aggregates.Project.Settings`)."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc "Builds the struct from a config map with atom or string keys."
  @spec from_config(map() | nil) :: t()
  def from_config(config) when is_map(config) do
    struct(__MODULE__, Enum.map(@keys, &{&1, fetch(config, &1)}))
  end

  def from_config(_config), do: %__MODULE__{}

  defp fetch(config, key) do
    case Map.fetch(config, key) do
      {:ok, value} -> value
      :error -> Map.get(config, Atom.to_string(key))
    end
  end

  @redacted "[redacted]"

  @doc """
  The project projection as handed to readers (HTTP and MCP): `config.env` and
  `config.environment` keep their keys but every value is replaced with
  `"[redacted]"`, because they hold secrets. `name`, `task_provider` and
  `database_path` stay visible. Accepts atom or string keys (persisted config
  has both after replay) and never raises on a malformed projection.
  """
  @spec public_view(map()) :: map()
  def public_view(%{} = projection) do
    case Map.fetch(projection, :config) do
      {:ok, %{} = config} -> Map.put(projection, :config, redact_config(config))
      _ -> projection
    end
  end

  defp redact_config(config) do
    Map.new(config, fn {key, value} ->
      if to_string(key) in ["env", "environment"],
        do: {key, redact_values(value)},
        else: {key, value}
    end)
  end

  # The environment RECORD keeps `setup_script` and `network` (not secrets) and
  # redacts only its `vars` values; legacy flat env redacts every value.
  defp redact_values(%{} = env) do
    if ForemanServer.Aggregates.Project.Environment.record?(env) do
      Map.new(env, fn {key, value} ->
        if to_string(key) == "vars", do: {key, redact_values(value)}, else: {key, value}
      end)
    else
      Map.new(env, fn {key, _value} -> {key, @redacted} end)
    end
  end

  defp redact_values(other), do: other
end
