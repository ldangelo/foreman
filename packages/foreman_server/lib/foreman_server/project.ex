defmodule ForemanServer.Project do
  @moduledoc "Project metadata loaded at server boot."

  @enforce_keys [:id, :path]
  defstruct [:id, :path, status: :active]

  @type t :: %__MODULE__{id: String.t(), path: String.t(), status: :active | :inactive}

  @spec new(map()) :: {:ok, t()} | {:error, :invalid_project}
  def new(%{id: id, path: path}) when is_binary(id) and is_binary(path) do
    {:ok, %__MODULE__{id: id, path: path}}
  end

  def new(%{"id" => id, "path" => path}) when is_binary(id) and is_binary(path) do
    {:ok, %__MODULE__{id: id, path: path}}
  end

  def new(_), do: {:error, :invalid_project}
end
