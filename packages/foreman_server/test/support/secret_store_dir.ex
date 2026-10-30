defmodule ForemanServer.TestSupport.SecretStoreDir do
  @moduledoc """
  Points the secret store at a tmp dir for one test and writes project secrets into it.

  The suite never touches the operator's `~/.foreman/secrets` (`config/test.exs` names a
  directory that does not exist), so a test that stores a secret names its own directory.
  Both functions are for the test process: `use_tmp_dir!/1` restores the previous config when
  the test exits.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias ForemanServer.SecretStore

  @doc "Use `<tmp_dir>/secrets` as the secret store directory until the test exits."
  @spec use_tmp_dir!(Path.t()) :: Path.t()
  def use_tmp_dir!(tmp_dir) do
    previous = Application.get_env(:foreman_server, :secret_store, [])
    dir = Path.join(tmp_dir, "secrets")
    Application.put_env(:foreman_server, :secret_store, Keyword.put(previous, :dir, dir))
    on_exit(fn -> Application.put_env(:foreman_server, :secret_store, previous) end)
    dir
  end

  @doc """
  Store `value` as secret `name` of `project_id`, straight in the store: no command and no
  event, so the project need not be registered.
  """
  @spec put!(String.t(), String.t(), String.t()) :: :ok
  def put!(project_id, name, value) do
    {:ok, :stored} = SecretStore.put(project_id, name, value)
    :ok
  end
end
