defmodule ForemanServer.AgentRuntime.AdapterCatalogTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.AdapterCatalog

  # Test adapters
  defmodule AdapterA do
    @behaviour ForemanServer.AgentRuntime.BackendAdapter
    @impl true
    def name, do: :adapter_a
    @impl true
    def capabilities do
      %{
        type: :language_model,
        strengths: [:coding],
        weaknesses: [],
        supported_contexts: [:chat]
      }
    end

    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "a", %{}}
  end

  defmodule AdapterB do
    @behaviour ForemanServer.AgentRuntime.BackendAdapter
    @impl true
    def name, do: :adapter_b
    @impl true
    def capabilities do
      %{
        type: :language_model,
        strengths: [:reasoning],
        weaknesses: [],
        supported_contexts: [:analysis]
      }
    end

    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "b", %{}}
  end

  defmodule AdapterC do
    @behaviour ForemanServer.AgentRuntime.BackendAdapter
    @impl true
    def name, do: :adapter_c
    @impl true
    def capabilities do
      %{
        type: :language_model,
        strengths: [:creativity],
        weaknesses: [],
        supported_contexts: [:creative]
      }
    end

    @impl true
    def available?, do: false
    @impl true
    def execute(_req, _opts), do: {:error, :offline}
  end

  # Helper to start catalog with unique name
  defp start_adapter_catalog(id) do
    name = :"AdapterCatalog.Test.#{id}"
    start_supervised!({AdapterCatalog, [name: name]}, id: id)
    name
  end

  describe "register/2" do
    test "registers a valid adapter and returns ok" do
      cat_name = start_adapter_catalog(:register)

      assert {:ok, AdapterA} = AdapterCatalog.register(AdapterA, cat_name)
    end

    test "rejects an invalid adapter" do
      cat_name = start_adapter_catalog(:invalid)

      # This adapter is missing required fields
      defmodule InvalidAdapter do
        @behaviour ForemanServer.AgentRuntime.BackendAdapter
        @impl true
        def name, do: :invalid
        @impl true
        # missing required fields
        def capabilities, do: %{type: :language_model}
        @impl true
        def available?, do: true
        @impl true
        def execute(_req, _opts), do: {:ok, "", %{}}
      end

      assert {:error, _} = AdapterCatalog.register(InvalidAdapter, cat_name)
    end
  end

  describe "unregister/2" do
    test "removes a registered adapter" do
      cat_name = start_adapter_catalog(:unregister)

      {:ok, AdapterA} = AdapterCatalog.register(AdapterA, cat_name)
      assert :ok = AdapterCatalog.unregister(AdapterA, cat_name)
      assert AdapterCatalog.snapshot(cat_name) == []
    end

    test "returns error for non-registered adapter" do
      cat_name = start_adapter_catalog(:unregister_error)

      assert {:error, :not_found} = AdapterCatalog.unregister(AdapterA, cat_name)
    end
  end

  describe "snapshot/1" do
    test "returns adapters in stable insertion order" do
      cat_name = start_adapter_catalog(:snapshot)

      AdapterCatalog.register(AdapterA, cat_name)
      AdapterCatalog.register(AdapterB, cat_name)
      AdapterCatalog.register(AdapterC, cat_name)

      assert AdapterCatalog.snapshot(cat_name) == [AdapterA, AdapterB, AdapterC]
    end

    test "returns consistent order across multiple calls" do
      cat_name = start_adapter_catalog(:snapshot_consistent)

      AdapterCatalog.register(AdapterA, cat_name)
      AdapterCatalog.register(AdapterB, cat_name)

      first = AdapterCatalog.snapshot(cat_name)
      second = AdapterCatalog.snapshot(cat_name)
      third = AdapterCatalog.snapshot(cat_name)

      assert first == second
      assert second == third
    end
  end

  describe "re-registration" do
    test "preserves first-insertion position" do
      cat_name = start_adapter_catalog(:reregister)

      AdapterCatalog.register(AdapterA, cat_name)
      AdapterCatalog.register(AdapterB, cat_name)
      AdapterCatalog.register(AdapterC, cat_name)

      # Re-register AdapterB - should stay in position 2
      {:ok, AdapterB} = AdapterCatalog.register(AdapterB, cat_name)

      assert AdapterCatalog.snapshot(cat_name) == [AdapterA, AdapterB, AdapterC]
    end
  end

  describe "available?/2" do
    test "returns cached availability" do
      cat_name = start_adapter_catalog(:available)

      # available: true
      AdapterCatalog.register(AdapterA, cat_name)
      # available: false
      AdapterCatalog.register(AdapterC, cat_name)

      assert AdapterCatalog.available?(AdapterA, cat_name) == true
      assert AdapterCatalog.available?(AdapterC, cat_name) == false
    end

    test "returns false for unknown adapter" do
      cat_name = start_adapter_catalog(:available_unknown)

      assert AdapterCatalog.available?(AdapterA, cat_name) == false
    end
  end
end
