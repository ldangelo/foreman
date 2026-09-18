defmodule ForemanServer.Test.Support.DoctorStubProvider do
  @moduledoc """
  Minimal `ForemanServer.TaskProvider` implementation for `DoctorTest`.

  Defined under `test/support` (not inline in the `.exs` test file) so it
  compiles to a real `.beam` via normal `mix compile` — a module defined
  inline in a `.exs` file has no such artifact, so
  `TaskProviderRegistry.ensure_provider_module/1`'s `Code.ensure_loaded?/1`
  check can fail with `:nofile` even though the module is otherwise
  callable in-process.
  """

  @behaviour ForemanServer.TaskProvider

  alias ForemanServer.TaskProviders.ProviderError

  @impl true
  def name, do: "doctor_test_stub"

  @impl true
  def capabilities do
    %{
      provider_id: :doctor_test_stub,
      contract_version: "br.capabilities.v1",
      id_format: "stub:%s",
      supports: [:list_ready]
    }
  end

  @impl true
  def available?, do: true

  @impl true
  def list_ready(%{issues: issues}, _opts), do: {:ok, issues}
  def list_ready(_project_config, _opts), do: {:ok, []}

  @impl true
  def create(_project_id, _attrs) do
    {:error,
     %ProviderError{
       code: "STUB_NOT_IMPLEMENTED",
       message: "stub",
       hint: "",
       retryable?: false,
       context: %{}
     }}
  end

  @impl true
  def get(_project_id, _id) do
    {:error,
     %ProviderError{
       code: "STUB_NOT_IMPLEMENTED",
       message: "stub",
       hint: "",
       retryable?: false,
       context: %{}
     }}
  end

  @impl true
  def claim(_project_id, _id, _assignee), do: :ok
  @impl true
  def complete(_project_id, _id, _opts), do: :ok
  @impl true
  def fail(_project_id, _id, _opts), do: :ok
  @impl true
  def reopen(_project_id, _id, _opts), do: :ok
  @impl true
  def set_priority(_project_id, _id, _priority), do: :ok
  @impl true
  def add_dependency(_project_id, _id, _depends_on), do: :ok

  @impl true
  def comment(_id, _body, _project_config), do: {:error, :not_implemented}
end
