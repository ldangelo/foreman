defmodule ForemanServer.VcsAdapter.DefaultTest do
  use ExUnit.Case, async: false

  alias ForemanServer.VcsAdapter.Default

  defmodule StubAlwaysTransient do
    @behaviour ForemanServer.VcsAdapter

    @impl true
    def clone(_url, _opts), do: {:error, {:transient, "fail"}}

    @impl true
    def branch(_path, _name), do: raise("not used")

    @impl true
    def create_pr(_path, _opts), do: raise("not used")
  end

  describe "transient?/1" do
    test "distinguishes {:transient, _} from non-transient" do
      assert ForemanServer.VcsAdapter.transient?({:transient, "x"})
      refute ForemanServer.VcsAdapter.transient?(:auth)
    end
  end

  describe "retry integration" do
    test "transient failure retries up to 3 times then returns error" do
      assert {:error, {:transient, _}} =
               ForemanServer.VcsAdapter.run(StubAlwaysTransient, :clone, ["url", []],
                 max_retries: 3,
                 base_delay_ms: 1
               )
    end
  end

  describe "Default module API" do
    test "exposes public run/3 entry point" do
      Code.ensure_loaded(Default)
      assert function_exported?(Default, :run, 3)
    end
  end
end
