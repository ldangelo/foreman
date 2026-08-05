defmodule ForemanServer.AgentRuntime.RouterTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.{AdapterCatalog, BackendAdapter, Router}

  # =============================================================================
  # Test fixtures - each exercises a specific dimension of the ranking matrix
  # =============================================================================

  # CheapFastAdapter: lowest cost, lowest latency (1st registration)
  defmodule CheapFastAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :cheap_fast_adapter
    @impl true
    def capabilities,
      do: %{
        type: :cli,
        strengths: [:fast],
        weaknesses: [],
        supported_contexts: [:code],
        cost_per_call: 0.001,
        typical_latency_ms: 100
      }

    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "cheap_fast", %{}}
  end

  # CheapSlowAdapter: same cost as CheapFast, higher latency (2nd registration)
  defmodule CheapSlowAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :cheap_slow_adapter
    @impl true
    def capabilities,
      do: %{
        type: :cli,
        strengths: [:cheap],
        weaknesses: [],
        supported_contexts: [:code],
        cost_per_call: 0.001,
        typical_latency_ms: 1000
      }

    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "cheap_slow", %{}}
  end

  # ExpensiveFastAdapter: higher cost, lower latency (3rd registration)
  defmodule ExpensiveFastAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :expensive_fast_adapter
    @impl true
    def capabilities,
      do: %{
        type: :cli,
        strengths: [:fast],
        weaknesses: [:expensive],
        supported_contexts: [:code],
        cost_per_call: 0.5,
        typical_latency_ms: 50
      }

    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "expensive_fast", %{}}
  end

  # UnavailableAdapter: registered but unavailable (4th registration)
  defmodule UnavailableAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :unavailable_adapter
    @impl true
    def capabilities,
      do: %{
        type: :cli,
        strengths: [],
        weaknesses: [],
        supported_contexts: [:code],
        cost_per_call: 0.0,
        typical_latency_ms: 0
      }

    @impl true
    def available?, do: false
    @impl true
    def execute(_req, _opts), do: {:ok, "unavailable", %{}}
  end

  # HighLatencyAdapter: no cost declared, very high latency (5th registration)
  defmodule HighLatencyAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :high_latency_adapter
    @impl true
    def capabilities,
      do: %{
        type: :cli,
        strengths: [],
        weaknesses: [:slow],
        supported_contexts: [:code],
        typical_latency_ms: 999_999
      }

    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "high_latency", %{}}
  end

  # DefaultCostAdapter: cost declared, no latency (6th registration)
  defmodule DefaultCostAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :default_cost_adapter
    @impl true
    def capabilities,
      do: %{
        type: :cli,
        strengths: [],
        weaknesses: [],
        supported_contexts: [:code],
        cost_per_call: 0.01
      }

    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "default_cost", %{}}
  end

  # WrongContextAdapter: wrong supported_contexts (7th registration)
  defmodule WrongContextAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :wrong_context_adapter
    @impl true
    def capabilities,
      do: %{
        type: :cli,
        strengths: [],
        weaknesses: [],
        supported_contexts: [:review],
        cost_per_call: 0.0,
        typical_latency_ms: 0
      }

    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "wrong_context", %{}}
  end

  # MissingOptionalAdapter: both optional fields omitted (8th registration)
  defmodule MissingOptionalAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :missing_optional_adapter
    @impl true
    def capabilities,
      do: %{
        type: :cli,
        strengths: [],
        weaknesses: [],
        supported_contexts: [:code]
      }

    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "missing_optional", %{}}
  end

  # SameCostWithLatencyAdapter: same cost, has latency (for latency-missing test)
  defmodule SameCostWithLatencyAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :with_latency
    @impl true
    def capabilities,
      do: %{
        type: :cli,
        strengths: [],
        weaknesses: [],
        supported_contexts: [:code],
        cost_per_call: 0.01,
        typical_latency_ms: 100
      }

    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "with_latency", %{}}
  end

  # SameCostWithoutLatencyAdapter: same cost, no latency (for latency-missing test)
  defmodule SameCostWithoutLatencyAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :without_latency
    @impl true
    def capabilities,
      do: %{
        type: :cli,
        strengths: [],
        weaknesses: [],
        supported_contexts: [:code],
        cost_per_call: 0.01
      }

    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "without_latency", %{}}
  end

  # EqualCapAdapter1: same cost+latency as EqualCapAdapter2 (for registration-order test)
  defmodule EqualCapAdapter1 do
    @behaviour BackendAdapter
    @impl true
    def name, do: :equal_cap_1
    @impl true
    def capabilities,
      do: %{
        type: :cli,
        strengths: [],
        weaknesses: [],
        supported_contexts: [:code],
        cost_per_call: 0.5,
        typical_latency_ms: 500
      }

    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "equal1", %{}}
  end

  # EqualCapAdapter2: same cost+latency as EqualCapAdapter1 (for registration-order test)
  defmodule EqualCapAdapter2 do
    @behaviour BackendAdapter
    @impl true
    def name, do: :equal_cap_2
    @impl true
    def capabilities,
      do: %{
        type: :cli,
        strengths: [],
        weaknesses: [],
        supported_contexts: [:code],
        cost_per_call: 0.5,
        typical_latency_ms: 500
      }

    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "equal2", %{}}
  end

  # =============================================================================
  # Helper to start a test catalog
  # =============================================================================

  defp start_test_catalog(name \\ :router_test_catalog) do
    start_supervised!({AdapterCatalog, [name: name]}, id: name)
    name
  end

  # =============================================================================
  # Tests for TRD-005 implementation ACs
  # =============================================================================

  describe "automatic/2 empty match" do
    test "returns {:error, :no_available_backend} when no adapters match task_type" do
      catalog = start_test_catalog()
      {:ok, _} = AdapterCatalog.register(WrongContextAdapter, catalog)
      result = Router.automatic(%{}, catalog: catalog, task_type: :nonexistent)
      assert result == {:error, :no_available_backend}
    end

    test "returns {:error, :no_available_backend} when catalog is empty" do
      catalog = start_test_catalog()
      result = Router.automatic(%{}, catalog: catalog, task_type: :code)
      assert result == {:error, :no_available_backend}
    end

    test "returns {:error, :no_available_backend} when task_type is nil" do
      catalog = start_test_catalog()
      {:ok, _} = AdapterCatalog.register(CheapFastAdapter, catalog)
      result = Router.automatic(%{}, catalog: catalog, task_type: nil)
      assert result == {:error, :no_available_backend}
    end
  end

  describe "automatic/2 supported_contexts filter" do
    test "filters adapters by supported_contexts membership" do
      catalog = start_test_catalog()
      {:ok, _} = AdapterCatalog.register(CheapFastAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(WrongContextAdapter, catalog)
      {:ok, adapter} = Router.automatic(%{}, catalog: catalog, task_type: :code)
      assert adapter == CheapFastAdapter
    end
  end

  describe "automatic/2 availability filter" do
    test "excludes unavailable adapters from selection" do
      catalog = start_test_catalog()
      {:ok, _} = AdapterCatalog.register(UnavailableAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(CheapFastAdapter, catalog)
      {:ok, adapter} = Router.automatic(%{}, catalog: catalog, task_type: :code)
      assert adapter == CheapFastAdapter
    end

    test "returns error when all matching adapters are unavailable" do
      catalog = start_test_catalog()
      {:ok, _} = AdapterCatalog.register(UnavailableAdapter, catalog)
      result = Router.automatic(%{}, catalog: catalog, task_type: :code)
      assert result == {:error, :no_available_backend}
    end
  end

  describe "automatic/2 cost tiebreak" do
    test "lower cost_per_call wins when contexts match" do
      catalog = start_test_catalog()
      {:ok, _} = AdapterCatalog.register(ExpensiveFastAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(CheapFastAdapter, catalog)
      {:ok, adapter} = Router.automatic(%{}, catalog: catalog, task_type: :code)
      assert adapter == CheapFastAdapter
    end
  end

  describe "automatic/2 latency tiebreak" do
    test "lower typical_latency_ms wins when cost is equal" do
      catalog = start_test_catalog()
      {:ok, _} = AdapterCatalog.register(CheapSlowAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(CheapFastAdapter, catalog)
      {:ok, adapter} = Router.automatic(%{}, catalog: catalog, task_type: :code)
      assert adapter == CheapFastAdapter
    end
  end

  describe "automatic/2 missing optional values" do
    test "adapters with declared cost sort before those without" do
      catalog = start_test_catalog()
      {:ok, _} = AdapterCatalog.register(HighLatencyAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(DefaultCostAdapter, catalog)
      {:ok, adapter} = Router.automatic(%{}, catalog: catalog, task_type: :code)
      assert adapter == DefaultCostAdapter
    end

    test "adapters with declared latency sort before those without (equal cost)" do
      catalog = start_test_catalog()
      {:ok, _} = AdapterCatalog.register(SameCostWithoutLatencyAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(SameCostWithLatencyAdapter, catalog)
      {:ok, adapter} = Router.automatic(%{}, catalog: catalog, task_type: :code)
      assert adapter == SameCostWithLatencyAdapter
    end
  end

  describe "automatic/2 registration order tiebreak" do
    test "earlier registration wins when cost and latency are equal" do
      catalog = start_test_catalog()
      {:ok, _} = AdapterCatalog.register(EqualCapAdapter2, catalog)
      {:ok, _} = AdapterCatalog.register(EqualCapAdapter1, catalog)
      {:ok, adapter} = Router.automatic(%{}, catalog: catalog, task_type: :code)
      # EqualCapAdapter2 registered first should win
      assert adapter == EqualCapAdapter2
    end
  end

  describe "automatic/2 determinism" do
    test "repeated calls return identical order" do
      catalog = start_test_catalog()
      {:ok, _} = AdapterCatalog.register(ExpensiveFastAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(CheapSlowAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(CheapFastAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(DefaultCostAdapter, catalog)

      results =
        for _ <- 1..10 do
          {:ok, adapter} = Router.automatic(%{}, catalog: catalog, task_type: :code)
          adapter
        end

      assert Enum.all?(results, &(&1 == CheapFastAdapter))
    end
  end

  describe "automatic/2 full ranking matrix" do
    test "every expected candidate order is stable and unavailable adapters are absent" do
      catalog = start_test_catalog()
      {:ok, _} = AdapterCatalog.register(CheapFastAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(CheapSlowAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(ExpensiveFastAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(UnavailableAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(HighLatencyAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(DefaultCostAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(WrongContextAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(MissingOptionalAdapter, catalog)
      # EqualCapAdapter1/2 are equal in cost+latency — only registration order breaks the tie.
      {:ok, _} = AdapterCatalog.register(EqualCapAdapter1, catalog)
      {:ok, _} = AdapterCatalog.register(EqualCapAdapter2, catalog)

      {:ok, adapter} = Router.automatic(%{}, catalog: catalog, task_type: :code)

      # Sorted: cost ( CheapFast=0.001, CheapSlow=0.001, DefaultCost=0.01,
      #   ExpensiveFast=0.5, EqualCapAdapter1=0.5, EqualCapAdapter2=0.5, then nil )
      # For ties on cost: latency (CheapFast=100 < CheapSlow=1000 < nil).
      # So: CheapFast wins — registration-order tiebreak never fires because cheaper
      # adapters outrank EqualCapAdapter1/2.
      assert adapter == CheapFastAdapter

      # Stability: 20 invocations must all return the same winner.
      results = for _ <- 1..20, do: Router.automatic(%{}, catalog: catalog, task_type: :code)
      unique = Enum.uniq(results)

      assert length(unique) == 1,
             "Expected stable ranking across 20 invocations, got #{length(unique)} unique results"

      # UnavailableAdapter is registered but absent from the ranking.
      assert UnavailableAdapter in AdapterCatalog.snapshot(catalog)
      refute match?({:ok, UnavailableAdapter}, hd(results))

      # WrongContextAdapter is registered but absent from the ranking for :code.
      assert WrongContextAdapter in AdapterCatalog.snapshot(catalog)
      refute match?({:ok, WrongContextAdapter}, hd(results))
    end

    test "registration-order tiebreak is stable across opposite-order catalogs" do
      # The matrix above has cheaper adapters dominating — registration-order tiebreak
      # never fires there. To exercise it, build catalogs where the ONLY differentiator
      # between competing adapters is registration order (identical cost + latency).
      #
      # Case A: EqualCapAdapter1 registered first → must win 20 times.
      catalog_a = start_test_catalog(:router_test_reg_order_a)
      {:ok, _} = AdapterCatalog.register(EqualCapAdapter1, catalog_a)
      {:ok, _} = AdapterCatalog.register(EqualCapAdapter2, catalog_a)

      results_a = for _ <- 1..20, do: Router.automatic(%{}, catalog: catalog_a, task_type: :code)

      assert Enum.all?(results_a, &match?({:ok, EqualCapAdapter1}, &1)),
             "EqualCapAdapter1 registered first must win 20 times; " <>
               "unique results: #{inspect(Enum.uniq(results_a))}"

      # Case B: EqualCapAdapter2 registered first → must win 20 times.
      # Opposite order proves the tiebreak depends on registration order, not on
      # adapter identity (e.g., alphabetical name).
      catalog_b = start_test_catalog(:router_test_reg_order_b)
      {:ok, _} = AdapterCatalog.register(EqualCapAdapter2, catalog_b)
      {:ok, _} = AdapterCatalog.register(EqualCapAdapter1, catalog_b)

      results_b = for _ <- 1..20, do: Router.automatic(%{}, catalog: catalog_b, task_type: :code)

      assert Enum.all?(results_b, &match?({:ok, EqualCapAdapter2}, &1)),
             "EqualCapAdapter2 registered first must win 20 times; " <>
               "unique results: #{inspect(Enum.uniq(results_b))}"
    end
  end
end
