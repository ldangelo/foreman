defmodule ForemanServer.SecretStore do
  @moduledoc """
  Server-side store for per-project secret VALUES (spike E4-SP1).

  A value enters through `put/3` and nowhere else; it is never placed in an
  event, command payload, log line or projection. Events record only the
  secret's name and a monotonically increasing version
  (`ForemanServer.ProjectSecrets`). The default backend is a 0600 file under a
  0700 directory outside any repository (`ForemanServer.SecretStore.File`).
  The OS keychain was rejected by the spike (value in argv, no stdin route).

  Configuration: `config :foreman_server, :secret_store, backend:, dir:`.

  Callers validate through this facade so every backend sees the same rules:
  names match `^[A-Z][A-Z0-9_]{0,63}$` and are not `FOREMAN_`-prefixed; values
  are non-empty, at most 16 KiB and contain no NUL.
  """

  alias ForemanServer.SecretStore.Error

  @max_value_bytes 16 * 1024
  @name_pattern ~r/\A[A-Z][A-Z0-9_]{0,63}\z/

  @type project_id :: String.t()
  @type result(t) :: {:ok, t} | {:error, Error.t()}

  @callback put(project_id(), name :: String.t(), value :: String.t()) :: result(:stored)
  @callback get(project_id(), name :: String.t()) :: result(String.t())
  @callback delete(project_id(), name :: String.t()) :: result(:deleted)
  @callback names(project_id()) :: result([String.t()])
  @callback pairs(project_id()) :: result(%{optional(String.t()) => String.t()})

  @doc "Maximum secret value size in bytes."
  @spec max_value_bytes() :: pos_integer()
  def max_value_bytes, do: @max_value_bytes

  @doc "True when `name` is a valid secret name (also usable as an env var name)."
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name),
    do: Regex.match?(@name_pattern, name) and not String.starts_with?(name, "FOREMAN_")

  def valid_name?(_), do: false

  @spec put(project_id(), String.t(), String.t()) :: result(:stored)
  def put(project_id, name, value) do
    with :ok <- check_project(project_id),
         :ok <- check_name(name),
         :ok <- check_value(value) do
      backend().put(project_id, name, value)
    end
  end

  @spec get(project_id(), String.t()) :: result(String.t())
  def get(project_id, name) do
    with :ok <- check_project(project_id),
         :ok <- check_name(name) do
      backend().get(project_id, name)
    end
  end

  @spec delete(project_id(), String.t()) :: result(:deleted)
  def delete(project_id, name) do
    with :ok <- check_project(project_id),
         :ok <- check_name(name) do
      backend().delete(project_id, name)
    end
  end

  @spec names(project_id()) :: result([String.t()])
  def names(project_id) do
    with :ok <- check_project(project_id), do: backend().names(project_id)
  end

  @doc """
  Every `name => value` pair for a project. Private seam for
  `ForemanServer.ProjectEnvironment.resolve/1`; never exposed to a surface.
  """
  @spec pairs(project_id()) :: result(%{optional(String.t()) => String.t()})
  def pairs(project_id) do
    with :ok <- check_project(project_id), do: backend().pairs(project_id)
  end

  @doc false
  @spec config(atom(), term()) :: term()
  def config(key, default) do
    :foreman_server |> Application.get_env(:secret_store, []) |> Keyword.get(key, default)
  end

  defp backend, do: config(:backend, ForemanServer.SecretStore.File)

  defp check_project(id) when is_binary(id) and id != "", do: :ok

  defp check_project(_),
    do: {:error, Error.new(:invalid_project_id, "project id must be a non-empty string")}

  defp check_name(name) do
    if valid_name?(name),
      do: :ok,
      else:
        {:error,
         Error.new(
           :invalid_secret_name,
           "secret name must match ^[A-Z][A-Z0-9_]{0,63}$ and not start with FOREMAN_",
           %{name: name_for_error(name)}
         )}
  end

  defp name_for_error(name) when is_binary(name), do: String.slice(name, 0, 80)
  defp name_for_error(_), do: nil

  defp check_value(value)
       when is_binary(value) and value != "" and byte_size(value) <= @max_value_bytes do
    if String.contains?(value, <<0>>),
      do: {:error, Error.new(:invalid_secret_value, "secret value must not contain NUL")},
      else: :ok
  end

  defp check_value(_),
    do:
      {:error,
       Error.new(:invalid_secret_value, "secret value must be 1..#{@max_value_bytes} bytes")}
end
