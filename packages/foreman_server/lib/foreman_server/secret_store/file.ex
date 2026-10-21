defmodule ForemanServer.SecretStore.File do
  @moduledoc """
  File backend for `ForemanServer.SecretStore` (spike E4-SP1: the default).

  One JSON object `{name => value}` per project at `<dir>/<b64(project_id)>.json`
  (the id is URL-safe-base64 encoded so it can never traverse out of `dir`).
  `dir` is created 0700, files are 0600, and writes go to a temp file that is
  `chmod`ed to 0600 while still empty, filled, then atomically renamed. Writers
  for the same project are serialised with a `:global` lock.
  """
  @behaviour ForemanServer.SecretStore

  alias ForemanServer.SecretStore
  alias ForemanServer.SecretStore.Error

  @impl true
  def put(project_id, name, value) do
    locked(project_id, fn ->
      with {:ok, map} <- read(project_id), do: write(project_id, Map.put(map, name, value))
    end)
  end

  @impl true
  def get(project_id, name) do
    with {:ok, map} <- read(project_id) do
      case Map.fetch(map, name) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, not_found(name)}
      end
    end
  end

  @impl true
  def delete(project_id, name) do
    locked(project_id, fn ->
      with {:ok, map} <- read(project_id) do
        if Map.has_key?(map, name) do
          with {:ok, :stored} <- write(project_id, Map.delete(map, name)), do: {:ok, :deleted}
        else
          {:error, not_found(name)}
        end
      end
    end)
  end

  @impl true
  def names(project_id) do
    with {:ok, map} <- read(project_id), do: {:ok, map |> Map.keys() |> Enum.sort()}
  end

  @impl true
  def pairs(project_id), do: read(project_id)

  defp not_found(name),
    do: Error.new(:secret_not_found, "no such secret", %{name: name})

  defp dir, do: SecretStore.config(:dir, Path.join(System.user_home!(), ".foreman/secrets"))

  defp path(project_id),
    do: Path.join(dir(), Base.url_encode64(project_id, padding: false) <> ".json")

  defp locked(project_id, fun), do: :global.trans({{__MODULE__, project_id}, self()}, fun)

  defp read(project_id) do
    case File.read(path(project_id)) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> {:error, Error.new(:store_malformed, "secret file is not a JSON object")}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, Error.new(:store_unavailable, "cannot read secret file", %{reason: reason})}
    end
  end

  defp write(project_id, map) do
    final = path(project_id)
    tmp = final <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(dir()),
         :ok <- File.chmod(dir(), 0o700),
         {:ok, io} <- File.open(tmp, [:write, :binary]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- write_and_close(io, Jason.encode!(map)),
         :ok <- File.rename(tmp, final) do
      {:ok, :stored}
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, Error.new(:store_unavailable, "cannot write secret file", %{reason: reason})}
    end
  end

  defp write_and_close(io, body) do
    result = IO.binwrite(io, body)
    File.close(io)
    result
  end
end
