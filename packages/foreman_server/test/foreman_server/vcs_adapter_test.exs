defmodule ForemanServer.VcsAdapterTest do
  use ExUnit.Case, async: true

  alias ForemanServer.VcsAdapter

  defmodule StubOk do
    @behaviour ForemanServer.VcsAdapter

    @impl true
    def clone(_url, _opts), do: {:ok, %{path: "/tmp/cloned"}}

    @impl true
    def branch(_path, _name), do: {:ok, %{branch: "feature-x"}}

    @impl true
    def create_pr(_path, _opts),
      do: {:ok, %{url: "https://github.com/foo/bar/pull/1", number: 1}}
  end

  defmodule StubTransient do
    @behaviour ForemanServer.VcsAdapter

    def attempts, do: :persistent_term.get({__MODULE__, :attempts}, 0)
    def reset, do: :persistent_term.put({__MODULE__, :attempts}, 0)

    @impl true
    def clone(_url, _opts) do
      n = :persistent_term.get({__MODULE__, :attempts}, 0) + 1
      :persistent_term.put({__MODULE__, :attempts}, n)
      {:error, {:transient, "network blip"}}
    end

    @impl true
    def branch(_path, _name), do: raise("not used")

    @impl true
    def create_pr(_path, _opts), do: raise("not used")
  end

  defmodule StubAuth do
    @behaviour ForemanServer.VcsAdapter

    def attempts, do: :persistent_term.get({__MODULE__, :attempts}, 0)
    def reset, do: :persistent_term.put({__MODULE__, :attempts}, 0)

    @impl true
    def clone(_url, _opts) do
      n = :persistent_term.get({__MODULE__, :attempts}, 0) + 1
      :persistent_term.put({__MODULE__, :attempts}, n)
      {:error, :auth}
    end

    @impl true
    def branch(_path, _name), do: raise("not used")

    @impl true
    def create_pr(_path, _opts), do: raise("not used")
  end

  defmodule StubSucceedAfterTwo do
    @behaviour ForemanServer.VcsAdapter

    def reset, do: :persistent_term.put({__MODULE__, :attempts}, 0)
    def attempts, do: :persistent_term.get({__MODULE__, :attempts}, 0)

    @impl true
    def clone(_url, _opts) do
      n = :persistent_term.get({__MODULE__, :attempts}, 0) + 1
      :persistent_term.put({__MODULE__, :attempts}, n)

      if n >= 3 do
        {:ok, %{path: "/tmp/cloned"}}
      else
        {:error, {:transient, "transient #{n}"}}
      end
    end

    @impl true
    def branch(_path, _name), do: raise("not used")

    @impl true
    def create_pr(_path, _opts), do: raise("not used")
  end

  setup do
    on_exit(fn ->
      :persistent_term.erase({StubTransient, :attempts})
      :persistent_term.erase({StubAuth, :attempts})
      :persistent_term.erase({StubSucceedAfterTwo, :attempts})
    end)

    StubTransient.reset()
    StubAuth.reset()
    StubSucceedAfterTwo.reset()
    :ok
  end

  describe "transient?/1" do
    test "returns true for {:transient, _} tuples" do
      assert VcsAdapter.transient?({:transient, "net"})
    end

    test "returns false for non-transient atoms" do
      refute VcsAdapter.transient?(:auth)
      refute VcsAdapter.transient?(:not_found)
      refute VcsAdapter.transient?(:invalid)
    end
  end

  describe "non_transient_errors/0" do
    test "returns the documented list" do
      assert VcsAdapter.non_transient_errors() == [:auth, :not_found, :invalid]
    end
  end

  describe "run/4" do
    test "success on first attempt returns {:ok, result}" do
      assert {:ok, %{path: "/tmp/cloned"}} = VcsAdapter.run(StubOk, :clone, ["repo", []])
    end

    test "transient failure retries until success" do
      assert {:ok, %{path: "/tmp/cloned"}} =
               VcsAdapter.run(StubSucceedAfterTwo, :clone, ["repo", []],
                 max_retries: 5,
                 base_delay_ms: 1
               )

      assert StubSucceedAfterTwo.attempts() == 3
    end

    test "transient failure exhausts retries and returns error" do
      assert {:error, {:transient, _}} =
               VcsAdapter.run(StubTransient, :clone, ["repo", []],
                 max_retries: 3,
                 base_delay_ms: 1
               )

      assert StubTransient.attempts() == 3
    end

    test "non-transient failure does not retry" do
      assert {:error, :auth} =
               VcsAdapter.run(StubAuth, :clone, ["repo", []],
                 max_retries: 5,
                 base_delay_ms: 1
               )

      assert StubAuth.attempts() == 1
    end

    test "supports branch and create_pr funs" do
      assert {:ok, %{branch: "feature-x"}} = VcsAdapter.run(StubOk, :branch, ["/tmp", "feature-x"])
      assert {:ok, %{url: _, number: 1}} = VcsAdapter.run(StubOk, :create_pr, ["/tmp", []])
    end
  end
end
