defmodule ForemanServer.TaskProviders.KataRegistryTighteningTest do
  @moduledoc """
  TRD-KATA-T032-TEST (AC-002-2, AC-010-2): the registry's capability validation is one
  provider-generic contract that the Beads adapter and the Kata adapter both pass, with no
  provider-specific branch, exemption or special case anywhere in the routing code.

    1. Parity. Every rule the registry applies to Beads' map it applies to Kata's map identically:
       the same violation for the same broken key, so a Kata-only exemption cannot hide.
    2. Admission. Both adapters are in the routing snapshot together, their overlapping `supports`
       sets notwithstanding, and neither is reported as invalid.
    3. Routing. A transition is only ever routed to a provider that advertises it.
    4. Structure. An AST scan (never a text grep) finds no mention of a provider by name in the
       registry, the storage binding, the projector or the run executor; fixture tests prove the
       scanner fails on a planted violation.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProvider.StorageBinding
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.KataAdapter
  alias ForemanServer.Test.Support.CapabilityStubProvider

  @invalid_event [:foreman_server, :task_provider, :registry, :invalid_capabilities]
  @required_keys [:provider_id, :contract_version, :supports, :storage_scheme]
  @adapters [BeadsAdapter, KataAdapter]

  @lib_root Path.expand("../../../lib/foreman_server", __DIR__)
  @routing_sources ~w(
    task_provider/registry.ex
    task_provider/storage_binding.ex
    task_provider/project_provider_projector.ex
    workflow/run_executor.ex
  )

  setup do
    previous_config = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1", "kata.capabilities.v1"],
      providers: @adapters
    )

    handler_id = "kata-registry-tightening-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler_id, @invalid_event, &__MODULE__.handle_telemetry/4, self())

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Application.put_env(:foreman_server, :task_provider, previous_config)
    end)

    :ok
  end

  ## 1. Parity

  describe "both adapters pass the shared validation (AC-002-2, AC-010-2)" do
    test "each adapter's capability map is accepted unchanged" do
      for adapter <- @adapters do
        assert :ok = Registry.validate_capabilities(adapter.capabilities()),
               "#{inspect(adapter)} is rejected by the registry contract"
      end
    end

    test "the two adapters declare different storage schemes from the one closed set" do
      schemes = Enum.map(@adapters, & &1.capabilities().storage_scheme)

      assert schemes == [:sqlite, :cli_process]
      assert Enum.all?(schemes, &(&1 in StorageBinding.schemes()))
    end

    test "a missing required key is the same violation for both adapters" do
      for key <- @required_keys do
        results =
          for adapter <- @adapters do
            Registry.validate_capabilities(Map.delete(adapter.capabilities(), key))
          end

        assert results == [{:error, [{:missing_key, key}]}, {:error, [{:missing_key, key}]}],
               "#{key}: the registry judged the adapters differently: #{inspect(results)}"
      end
    end

    test "a wrongly typed required key is the same violation for both adapters" do
      for key <- @required_keys do
        results =
          for adapter <- @adapters do
            Registry.validate_capabilities(Map.put(adapter.capabilities(), key, 42))
          end

        assert results == [{:error, [{:invalid_value, key}]}, {:error, [{:invalid_value, key}]}],
               "#{key}: the registry judged the adapters differently: #{inspect(results)}"
      end
    end

    test "an unknown storage scheme is refused for both adapters, not only for a stranger" do
      for adapter <- @adapters do
        broken = Map.put(adapter.capabilities(), :storage_scheme, :postgres)

        assert {:error, [{:invalid_value, :storage_scheme}]} =
                 Registry.validate_capabilities(broken)
      end
    end
  end

  ## 2. Admission

  describe "both adapters are admitted together (AC-010-2)" do
    test "the configured registry routes both providers and reports neither as invalid" do
      name = :kata_registry_tightening_admission
      start_supervised!({Registry, [name: name]}, id: name)

      assert GenServer.call(name, :routing_snapshot) == %{
               beads: BeadsAdapter,
               kata: KataAdapter
             }

      for adapter <- @adapters do
        refute_receive {:telemetry, @invalid_event, _, %{provider: ^adapter}}, 50
      end
    end

    test "overlapping supports sets are not a conflict: both stay in the snapshot" do
      [beads, kata] = Enum.map(@adapters, &MapSet.new(&1.capabilities().supports))
      overlap = MapSet.intersection(beads, kata)

      assert MapSet.size(overlap) >= 9
      assert MapSet.subset?(MapSet.new([:claim, :close, :reopen, :create]), overlap)

      name = :kata_registry_tightening_overlap
      start_supervised!({Registry, [name: name]}, id: name)

      snapshot = GenServer.call(name, :routing_snapshot)
      assert snapshot[:beads] == BeadsAdapter
      assert snapshot[:kata] == KataAdapter
    end
  end

  ## 3. Routing

  describe "routing prefers a provider that advertises the transition (AC-010-2)" do
    setup do
      ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)
      :ok
    end

    test "a transition only one adapter advertises goes to that adapter" do
      refute :label in KataAdapter.capabilities().supports
      assert :label in BeadsAdapter.capabilities().supports

      assert {:ok, BeadsAdapter} = Registry.route(:label, nil)
      assert {:error, :no_provider_for_transition} = Registry.route(:label, KataAdapter.name())
    end

    test "a transition both advertise goes to the provider the routing key names" do
      assert :claim in BeadsAdapter.capabilities().supports
      assert :claim in KataAdapter.capabilities().supports

      assert {:ok, BeadsAdapter} = Registry.route(:claim, BeadsAdapter.name())
      assert {:ok, KataAdapter} = Registry.route(:claim, KataAdapter.name())
    end

    test "an unkeyed route never lands on a provider that lacks the transition" do
      stub = no_create_stub()
      assert {:ok, ^stub} = Registry.register(stub)

      transitions =
        [stub | @adapters]
        |> Enum.flat_map(& &1.capabilities().supports)
        |> Enum.uniq()

      for transition <- transitions do
        assert {:ok, provider} = Registry.route(transition, nil)

        assert transition in provider.capabilities().supports,
               "#{transition} was routed to #{inspect(provider)}, which does not advertise it"
      end

      assert {:ok, provider} = Registry.route(:create, nil)
      assert provider != stub
    end
  end

  ## 4. Structure

  describe "no provider is recognised by name in the routing code (AC-010-2)" do
    test "the registry, binding, projector and run executor never mention a provider by name" do
      offenders =
        for relative <- @routing_sources,
            site <- provider_name_mentions(File.read!(Path.join(@lib_root, relative))) do
          {relative, site}
        end

      assert offenders == [],
             "a provider is special-cased by name:\n" <>
               Enum.map_join(offenders, "\n", &inspect/1)
    end

    test "the scanner flags every way of naming the provider" do
      planted = [
        {"def route(:kata), do: :ok", :atom},
        {~S|def route("kata"), do: :ok|, :string},
        {~S|def route(id) when id == "Kata", do: :ok|, :string},
        {"def route, do: KataAdapter.claim()", :alias},
        {"def route, do: ForemanServer.TaskProviders.KataAdapter", :alias},
        {"alias ForemanServer.TaskProviders.KataAdapter", :alias}
      ]

      for {expression, kind} <- planted do
        source = "defmodule Fixture do\n  #{expression}\nend\n"

        assert [%{kind: ^kind, line: 2}] = provider_name_mentions(source),
               "scanner missed: #{expression}"
      end
    end

    test "the scanner ignores comments, other atoms and the word inside unrelated identifiers" do
      clean = """
      defmodule Fixture do
        # kata and Kata in a comment are prose, not a branch
        def route(:beads), do: :ok
        def route(:cli_process), do: :ok
        def route("database"), do: :ok
      end
      """

      assert provider_name_mentions(clean) == []
    end
  end

  def handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  # A provider that advertises everything but `:create`, registered first by id ordering.
  defp no_create_stub do
    CapabilityStubProvider.define!(
      name: :aaa_no_create,
      capabilities: %{
        provider_id: :aaa_no_create,
        contract_version: "br.capabilities.v1",
        supports: [:claim, :close, :reopen],
        storage_scheme: :sqlite
      }
    )
  end

  # Every literal atom, string and alias in the code that names the provider. Literals carry no
  # line in the plain AST, so they are wrapped by a `literal_encoder` that records it.
  defp provider_name_mentions(source) do
    {:ok, ast} =
      Code.string_to_quoted(source,
        literal_encoder: fn literal, meta -> {:ok, {:__block__, meta, [literal]}} end
      )

    {_ast, mentions} =
      Macro.prewalk(ast, [], fn
        {:__block__, meta, [literal]} = node, acc when is_atom(literal) ->
          {node, mention(literal, :atom, meta, acc)}

        {:__block__, meta, [literal]} = node, acc when is_binary(literal) ->
          {node, mention(literal, :string, meta, acc)}

        {:__aliases__, meta, parts} = node, acc ->
          {node, mention(parts |> List.last() |> to_string(), :alias, meta, acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(mentions)
  end

  defp mention(literal, kind, meta, acc) do
    if literal |> to_string() |> String.downcase() |> String.contains?("kata") do
      [%{kind: kind, line: meta[:line], literal: literal} | acc]
    else
      acc
    end
  end
end
