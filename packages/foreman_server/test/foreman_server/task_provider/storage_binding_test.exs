defmodule ForemanServer.TaskProvider.StorageBindingTest do
  @moduledoc """
  `StorageBinding` is the one place that maps a provider's declared `storage_scheme` to the project
  config key that binds it (TRD-KATA-T053, AC-003-2, AC-010-2) and that decides what a
  `project.update` carrying a `task_provider` stores. Nothing here names a provider except as a
  configured fixture: every rule is stated over the scheme.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProvider.StorageBinding
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.KataAdapter
  alias ForemanServer.Test.Support.CapabilityStubProvider

  @cwd "/work/cli-project"
  @database_path "/abs/project.db"

  setup do
    previous = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      Keyword.put(previous, :providers, [BeadsAdapter, KataAdapter])
    )

    on_exit(fn -> Application.put_env(:foreman_server, :task_provider, previous) end)

    {:ok, sqlite: stub(:sqlite), cli: stub(:cli_process)}
  end

  describe "the scheme table" do
    test "the closed set of schemes, the key that binds each and the routing error for each" do
      assert StorageBinding.schemes() == [:sqlite, :cli_process]

      assert StorageBinding.key(:sqlite) == :database_path
      assert StorageBinding.key(:cli_process) == :cwd

      assert StorageBinding.mismatch_reason(:sqlite) == :database_path_mismatch
      assert StorageBinding.mismatch_reason(:cli_process) == :cwd_mismatch
    end

    test "scheme/1 reads the declared scheme, whatever the provider is called", %{
      sqlite: sqlite,
      cli: cli
    } do
      assert {:ok, :sqlite} = StorageBinding.scheme(sqlite)
      assert {:ok, :cli_process} = StorageBinding.scheme(cli)
      assert {:ok, :sqlite} = StorageBinding.scheme(BeadsAdapter)
      assert {:ok, :cli_process} = StorageBinding.scheme(KataAdapter)
    end

    test "scheme/1 refuses a provider that declares none the registry accepts" do
      for capabilities <- [nil, %{}, %{storage_scheme: :postgres}, %{storage_scheme: "sqlite"}] do
        provider = CapabilityStubProvider.define!(capabilities: capabilities)
        assert {:error, :invalid_capabilities} = StorageBinding.scheme(provider)
      end
    end
  end

  describe "fetch/2" do
    test "a :sqlite project is bound by its database_path under either key convention", %{
      sqlite: sqlite
    } do
      assert {:ok, @database_path} =
               StorageBinding.fetch(sqlite, %{database_path: @database_path})

      assert {:ok, @database_path} =
               StorageBinding.fetch(sqlite, %{"database_path" => @database_path})
    end

    test "a :cli_process project is bound by its cwd under either key convention", %{cli: cli} do
      assert {:ok, @cwd} = StorageBinding.fetch(cli, %{cwd: @cwd})
      assert {:ok, @cwd} = StorageBinding.fetch(cli, %{"cwd" => @cwd})
    end

    test "the key belongs to the scheme: a :cli_process project is not bound by a database_path",
         %{
           cli: cli,
           sqlite: sqlite
         } do
      assert {:error, {:missing_binding_key, :cwd}} =
               StorageBinding.fetch(cli, %{database_path: @database_path})

      assert {:error, {:missing_binding_key, :database_path}} =
               StorageBinding.fetch(sqlite, %{cwd: @cwd})
    end

    test "an absent, blank or non-string value is a missing key, never a default", %{cli: cli} do
      for config <- [
            %{},
            %{cwd: ""},
            %{cwd: nil},
            %{cwd: 42},
            %{"cwd" => ""},
            nil,
            "cwd",
            [cwd: @cwd]
          ] do
        assert {:error, {:missing_binding_key, :cwd}} = StorageBinding.fetch(cli, config),
               "accepted #{inspect(config)}"
      end
    end

    test "a provider without a usable scheme has no key to fetch" do
      provider = CapabilityStubProvider.define!(capabilities: %{storage_scheme: :postgres})
      assert {:error, :invalid_capabilities} = StorageBinding.fetch(provider, %{cwd: @cwd})
    end
  end

  describe "provider_for_ref/1" do
    test "resolves a provider id, a module name or the module to the configured module" do
      for ref <- [:beads, "beads", BeadsAdapter, "ForemanServer.TaskProviders.BeadsAdapter"] do
        assert {:ok, BeadsAdapter} = StorageBinding.provider_for_ref(ref), inspect(ref)
      end

      for ref <- [:kata, "kata", KataAdapter, "ForemanServer.TaskProviders.KataAdapter"] do
        assert {:ok, KataAdapter} = StorageBinding.provider_for_ref(ref), inspect(ref)
      end
    end

    test "a loaded provider module resolves to itself even when it is not configured", %{
      cli: cli
    } do
      assert {:ok, ^cli} = StorageBinding.provider_for_ref(cli)
    end

    test "an unknown or malformed reference resolves to nothing" do
      for ref <- [nil, :nonexistent, "nonexistent", "", 42, %{provider: :beads}, ["beads"]] do
        assert :error = StorageBinding.provider_for_ref(ref), inspect(ref)
      end
    end

    test "resolving a reference never creates an atom from it" do
      unseen = "never_seen_provider_#{System.unique_integer([:positive])}"

      assert :error = StorageBinding.provider_for_ref(unseen)
      assert_raise ArgumentError, fn -> String.to_existing_atom(unseen) end
    end
  end

  describe "resolve_update/2: the same provider and no config keeps the stored config" do
    test "for either scheme, under atom keys" do
      assert {:ok, %{provider: "kata", config: %{cwd: @cwd}}} =
               StorageBinding.resolve_update(
                 %{provider: "kata", config: %{cwd: @cwd}},
                 %{provider: "kata"}
               )

      assert {:ok, %{provider: "beads", config: %{database_path: @database_path}}} =
               StorageBinding.resolve_update(
                 %{provider: "beads", config: %{database_path: @database_path}},
                 %{provider: "beads"}
               )
    end

    test "under the string keys JSON ingress produces" do
      assert {:ok, %{"provider" => "kata", "config" => %{"cwd" => @cwd}} = resolved} =
               StorageBinding.resolve_update(
                 %{"provider" => "kata", "config" => %{"cwd" => @cwd}},
                 %{"provider" => "kata"}
               )

      refute Map.has_key?(resolved, :config)
    end

    test "when the request names the provider another way" do
      stored = %{provider: "kata", config: %{cwd: @cwd}}

      for spelling <- [:kata, KataAdapter, "ForemanServer.TaskProviders.KataAdapter"] do
        assert {:ok, %{config: %{cwd: @cwd}}} =
                 StorageBinding.resolve_update(stored, %{provider: spelling})
      end
    end

    test "a config of nil is no config" do
      assert {:ok, %{config: %{cwd: @cwd}}} =
               StorageBinding.resolve_update(
                 %{provider: "kata", config: %{cwd: @cwd}},
                 %{provider: "kata", config: nil}
               )
    end

    test "an unknown provider restated keeps its config too" do
      assert {:ok, %{provider: "elsewhere", config: %{token: "t"}}} =
               StorageBinding.resolve_update(
                 %{provider: "elsewhere", config: %{token: "t"}},
                 %{provider: "elsewhere"}
               )
    end

    test "nothing stored to keep leaves the request as asked" do
      assert {:ok, %{provider: "kata"} = resolved} =
               StorageBinding.resolve_update(%{provider: "kata"}, %{provider: "kata"})

      refute Map.has_key?(resolved, :config)
    end
  end

  describe "resolve_update/2: a request that carries a config replaces the stored block" do
    test "atomically, without merging a single stored key" do
      assert {:ok, %{provider: "kata", config: config}} =
               StorageBinding.resolve_update(
                 %{provider: "kata", config: %{cwd: @cwd, extra: 1}},
                 %{provider: "kata", config: %{cwd: "/work/other"}}
               )

      assert config == %{cwd: "/work/other"}
    end
  end

  describe "resolve_update/2: a different provider must bring the key its scheme needs" do
    test "a :cli_process target without a cwd is refused, naming cwd" do
      stored = %{provider: "beads", config: %{database_path: @database_path}}

      assert {:error, {:missing_or_invalid, :cwd}} =
               StorageBinding.resolve_update(stored, %{provider: "kata"})

      assert {:error, {:missing_or_invalid, :cwd}} =
               StorageBinding.resolve_update(stored, %{
                 provider: "kata",
                 config: %{database_path: @database_path}
               })

      assert {:error, {:missing_or_invalid, :cwd}} =
               StorageBinding.resolve_update(stored, %{provider: "kata", config: %{cwd: ""}})
    end

    test "a :sqlite target without a database_path is refused, naming database_path" do
      stored = %{provider: "kata", config: %{cwd: @cwd}}

      assert {:error, {:missing_or_invalid, :database_path}} =
               StorageBinding.resolve_update(stored, %{provider: "beads"})

      assert {:error, {:missing_or_invalid, :database_path}} =
               StorageBinding.resolve_update(stored, %{provider: "beads", config: %{cwd: @cwd}})
    end

    test "a target that brings its key is stored as asked, under either key convention" do
      stored = %{provider: "beads", config: %{database_path: @database_path}}

      assert {:ok, %{provider: "kata", config: %{cwd: @cwd}}} =
               StorageBinding.resolve_update(stored, %{provider: "kata", config: %{cwd: @cwd}})

      assert {:ok, %{"provider" => "kata", "config" => %{"cwd" => @cwd}}} =
               StorageBinding.resolve_update(stored, %{
                 "provider" => "kata",
                 "config" => %{"cwd" => @cwd}
               })
    end

    test "a provider that was never stored counts as a different provider" do
      assert {:error, {:missing_or_invalid, :cwd}} =
               StorageBinding.resolve_update(nil, %{provider: "kata"})

      assert {:ok, %{provider: "kata", config: %{cwd: @cwd}}} =
               StorageBinding.resolve_update(nil, %{provider: "kata", config: %{cwd: @cwd}})
    end

    test "the rule is the scheme's, not the provider's: a configured stub of each scheme", %{
      sqlite: sqlite,
      cli: cli
    } do
      assert {:error, {:missing_or_invalid, :cwd}} =
               StorageBinding.resolve_update(%{provider: "beads"}, %{provider: cli})

      assert {:error, {:missing_or_invalid, :database_path}} =
               StorageBinding.resolve_update(%{provider: "kata"}, %{provider: sqlite})
    end

    test "a provider that cannot be resolved, or declares no scheme, is stored as asked" do
      broken = CapabilityStubProvider.define!(capabilities: %{storage_scheme: :postgres})

      assert {:ok, %{provider: "nonexistent"}} =
               StorageBinding.resolve_update(%{provider: "beads"}, %{provider: "nonexistent"})

      assert {:ok, %{provider: ^broken}} =
               StorageBinding.resolve_update(%{provider: "beads"}, %{provider: broken})
    end
  end

  defp stub(scheme) do
    CapabilityStubProvider.define!(
      name: :"#{scheme}_stub",
      capabilities: %{
        provider_id: :"#{scheme}_stub",
        contract_version: "br.capabilities.v1",
        supports: [:claim],
        storage_scheme: scheme
      }
    )
  end
end
