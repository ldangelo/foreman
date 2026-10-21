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
          coordinator_model: String.t() | nil,
          coordinator_effort: String.t() | nil,
          max_concurrent_runs: pos_integer() | nil,
          daily_thread_cap: pos_integer() | nil
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
end
