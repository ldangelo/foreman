defmodule ForemanServer.Project do
  @moduledoc "Project metadata loaded at server boot."

  @enforce_keys [:id, :path]
  defstruct [
    :id,
    :path,
    status: :active,
    default_branch: "main",
    config: %{},
    health: %{ok: true}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t(),
          status: :active | :inactive,
          default_branch: String.t(),
          config: map(),
          health: map()
        }

  @spec new(map()) :: {:ok, t()} | {:error, :invalid_project}
  def new(%{id: id, path: path} = attrs) when is_binary(id) and is_binary(path) do
    {:ok,
     %__MODULE__{
       id: id,
       path: path,
       status: normalize_status(Map.get(attrs, :status, :active)),
       default_branch: Map.get(attrs, :default_branch, "main"),
       config: Map.get(attrs, :config, %{}),
       health: Map.get(attrs, :health, %{ok: true})
     }}
  end

  def new(%{"id" => id, "path" => path} = attrs) when is_binary(id) and is_binary(path) do
    new(%{
      id: id,
      path: path,
      status: Map.get(attrs, "status", "active"),
      default_branch: Map.get(attrs, "default_branch", "main"),
      config: Map.get(attrs, "config", %{}),
      health: Map.get(attrs, "health", %{"ok" => true})
    })
  end

  def new(_), do: {:error, :invalid_project}

  defp normalize_status(:inactive), do: :inactive
  defp normalize_status("inactive"), do: :inactive
  defp normalize_status(_), do: :active
end
