defmodule ForemanServer.AgentRuntime.TRD003Test do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.{AdapterCatalog, BackendAdapter, Supervisor}

  # Test adapters - captures prompt/context for verification
  defmodule EchoAdapter do
    @behaviour BackendAdapter

    @impl true
    def name, do: :echo_adapter

    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}

    @impl true
    def available?, do: true

    @impl true
    def execute(%{prompt: prompt, context: context}, _opts) do
      # Echo back prompt and context for verification
      {:ok, "prompt=#{prompt} context=#{inspect(context)}", %{}}
    end
  end

  defmodule UnavailableAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :unavailable_adapter
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: false
    @impl true
    def execute(_req, _opts), do: {:ok, "success", %{}}
  end

  defp start_runtime do
    test_id = :rand.uniform(999_999)
    sup_name = :"AgentRuntime.Test.#{test_id}"
    catalog_name = :"Catalog#{test_id}"
    invocation_name = :"InvocationSup#{test_id}"
    sup_id = :"agent_runtime_sup#{test_id}"

    sup_opts = [
      name: sup_name,
      adapter_catalog_name: catalog_name,
      invocation_supervisor_name: invocation_name,
      adapters: []
    ]

    start_supervised!({Supervisor, sup_opts}, id: sup_id)

    {catalog_name, invocation_name}
  end

  describe "execute/3 manual routing" do
    test "passes exact prompt and context to adapter, returns content only" do
      {catalog_name, inv_name} = start_runtime()

      # Register adapter with the test catalog
      {:ok, _} = AdapterCatalog.register(EchoAdapter, catalog_name)

      # Execute with specific prompt and context
      result = ForemanServer.AgentRuntime.execute("my test prompt", %{key: "value"},
        strategy: :manual,
        backend: :echo_adapter,
        catalog: catalog_name,
        invocation_supervisor: inv_name
      )

      # Verify success returns only content (no backend name)
      assert {:ok, "prompt=my test prompt context=%{key: \"value\"}"} = result
    end

    test "returns {:error, :backend_not_found} for unknown backend" do
      {catalog_name, inv_name} = start_runtime()

      # Register EchoAdapter, then request a different (nonexistent) backend
      {:ok, _} = AdapterCatalog.register(EchoAdapter, catalog_name)

      result = ForemanServer.AgentRuntime.execute("test prompt", %{},
        strategy: :manual,
        backend: :nonexistent,
        catalog: catalog_name,
        invocation_supervisor: inv_name
      )

      assert {:error, :backend_not_found} = result
    end

    test "returns {:error, :backend_unavailable} for unavailable backend - no fallback" do
      {catalog_name, inv_name} = start_runtime()

      # Register unavailable adapter
      {:ok, _} = AdapterCatalog.register(UnavailableAdapter, catalog_name)

      # Execute - should return unavailable, NOT try another adapter
      result = ForemanServer.AgentRuntime.execute("test prompt", %{},
        strategy: :manual,
        backend: :unavailable_adapter,
        catalog: catalog_name,
        invocation_supervisor: inv_name
      )

      assert {:error, :backend_unavailable} = result
    end

    test "returns {:error, :no_available_backend} for empty catalog" do
      # Start runtime with empty catalog
      {catalog_name, inv_name} = start_runtime()

      # Execute with no adapters registered
      result = ForemanServer.AgentRuntime.execute("test prompt", %{},
        strategy: :manual,
        backend: :any_backend,
        catalog: catalog_name,
        invocation_supervisor: inv_name
      )

      # Empty catalog should return no_available_backend immediately
      assert {:error, :no_available_backend} = result
    end
  end
end
