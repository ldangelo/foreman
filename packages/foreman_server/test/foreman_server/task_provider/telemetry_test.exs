defmodule ForemanServer.TaskProvider.TelemetryTest do
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProvider.Telemetry

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    :ok
  end

  test "taxonomy/0 returns a non-empty map of documented events" do
    taxonomy = Telemetry.taxonomy()

    assert is_map(taxonomy)
    assert map_size(taxonomy) >= 4

    assert taxonomy[[:foreman_server, :task_provider, :registry, :route, :ok]].metadata_keys == [
             :transition,
             :routing_key,
             :provider
           ]

    assert taxonomy[[:foreman_server, :task_provider, :registry, :route, :error]].metadata_keys ==
             [
               :transition,
               :routing_key,
               :reason
             ]

    assert taxonomy[[:foreman_server, :task_provider, :registry, :restarted]].metadata_keys == [
             :restart_count,
             :providers,
             :registry
           ]

    assert taxonomy[[:foreman_server, :task_provider, :registry, :register_for_project, :ok]].metadata_keys ==
             [
               :project_id,
               :provider
             ]

    assert taxonomy[
             [:foreman_server, :task_provider, :registry, :register_for_project, :error]
           ].metadata_keys == [
             :project_id,
             :provider,
             :reason
           ]

    assert taxonomy[[:foreman_server, :task_provider, :registry, :unregister_for_project]].metadata_keys ==
             [
               :project_id,
               :reason
             ]

    assert taxonomy[[:foreman_server, :task_provider, :beads_adapter, :preflight, :ok]].metadata_keys ==
             [
               :argv
             ]

    assert taxonomy[[:foreman_server, :task_provider, :beads_adapter, :preflight, :error]].metadata_keys ==
             [
               :argv,
               :error
             ]
    assert taxonomy[[:foreman_server, :task_provider, :beads_adapter, :fail, :success]].metadata_keys ==
             [
               :argv
             ]

    assert taxonomy[[:foreman_server, :task_provider, :transition_comment, :rejected]].metadata_keys ==
             [
               :argv,
               :raw_code,
               :task_id
             ]


    assert taxonomy[[:foreman_server, :task_provider, :beads, :temp_file, :leaked]].metadata_keys ==
             [
               :kind
             ]
  end

  test "scrub_argv/1 redacts :database_path value" do
    assert Telemetry.scrub_argv([{:database_path, "/secret/path.db"}, "--json"]) == [
             {:database_path, "/abs/<redacted:15>"},
             "--json"
           ]
  end

  test "scrub_argv/1 redacts :claim_token value" do
    assert Telemetry.scrub_argv([{:claim_token, "supersecret-token"}]) == [
             {:claim_token, "<redacted:8>"}
           ]
  end

  test "scrub_argv/1 redacts :completion_token and :failure_token" do
    assert Telemetry.scrub_argv([
             {:completion_token, "completion-token"},
             {:failure_token, "failure-token"}
           ]) == [
             {:completion_token, "<redacted:8>"},
             {:failure_token, "<redacted:8>"}
           ]
  end

  test "scrub_argv/1 truncates long :transition_comment" do
    long_comment = String.duplicate("x", 80)

    assert Telemetry.scrub_argv([{:transition_comment, long_comment}]) == [
             {:transition_comment, "<redacted:64>"}
           ]
  end

  test "scrub_argv/1 leaves non-sentinel pairs unchanged" do
    assert Telemetry.scrub_argv([{:timeout_ms, 5000}]) == [{:timeout_ms, 5000}]
  end

  test "emit/3 scrubs :argv metadata before :telemetry.execute/3" do
    event = [:test, :event]
    handler_id = attach_handler(event)

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok = Telemetry.emit(event, %{value: 1}, %{argv: [{:database_path, "/secret"}]})

    assert_receive {:telemetry, ^event, %{value: 1}, %{argv: [{:database_path, redacted}]}}, 1_000
    assert redacted == "/abs/<redacted:7>"
    refute redacted == "/secret"
  end

  test "emit/3 forwards non-argv metadata unchanged" do
    event = [:test, :event2]
    handler_id = attach_handler(event)

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok = Telemetry.emit(event, %{count: 1}, %{timeout_ms: 5000})

    assert_receive {:telemetry, ^event, %{count: 1}, %{timeout_ms: 5000}}, 1_000
  end

  test "every emit site in the codebase uses Telemetry.emit/3 (not raw :telemetry.execute/3)" do
    raw_calls =
      source_paths()
      |> Enum.flat_map(&raw_telemetry_execute_calls/1)

    assert raw_calls == []

    expected_events = [
      [:foreman_server, :task_provider, :registry, :route, :ok],
      [:foreman_server, :task_provider, :registry, :route, :error],
      [:foreman_server, :task_provider, :registry, :restarted],
      [:foreman_server, :task_provider, :registry, :register_for_project, :ok],
      [:foreman_server, :task_provider, :registry, :register_for_project, :error],
      [:foreman_server, :task_provider, :registry, :unregister_for_project],
      [:foreman_server, :task_provider, :beads_adapter, :preflight, :start],
      [:foreman_server, :task_provider, :beads_adapter, :preflight, :ok],
      [:foreman_server, :task_provider, :beads_adapter, :preflight, :error],
      [:foreman_server, :task_provider, :beads, :temp_file, :leaked],
      [:foreman_server, :task_provider, :beads, :capabilities, :refreshed],
      [:foreman_server, :task_provider, :beads, :contract, :version_changed],
      [:foreman_server, :task_provider, :concurrency_limiter, :acquire],
      [:foreman_server, :task_provider, :concurrency_limiter, :release],
      [:foreman_server, :task_provider, :concurrency_limiter, :timeout],
      [:foreman_server, :task_provider, :beads_adapter, :fail, :success],
      [:foreman_server, :task_provider, :transition_comment, :rejected]
    ]

    event_counts =
      source_paths()
      |> Enum.flat_map(&telemetry_emit_events/1)
      |> Enum.frequencies()

    assert event_counts == Map.new(expected_events, &{&1, 1})
  end

  defp attach_handler(event) do
    handler_id = "task-provider-telemetry-test-#{System.unique_integer([:positive, :monotonic])}"

    :ok = :telemetry.attach(handler_id, event, &__MODULE__.handle_telemetry/4, self())

    handler_id
  end

  defp source_paths do
    source_root = Path.expand("../../../lib/foreman_server", __DIR__)

    [
      Path.wildcard(Path.join(source_root, "task_provider*.ex")),
      Path.wildcard(Path.join(source_root, "task_provider/*.ex")),
      Path.wildcard(Path.join(source_root, "task_providers/*.ex"))
    ]
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reject(&String.ends_with?(&1, "/task_provider/telemetry.ex"))
    |> Enum.sort()
  end

  defp raw_telemetry_execute_calls(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()

    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., meta, [:telemetry, :execute]}, _meta, _args} = node, acc ->
          {node, ["#{path}:#{meta[:line]}" | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(calls)
  end

  defp telemetry_emit_events(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()
    attrs = module_attributes(ast)

    {_ast, event_asts} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, alias_parts}, :emit]}, _, [event_ast | _]} = node, acc
        when alias_parts in [
               [:TaskProviderTelemetry],
               [:Telemetry],
               [:ForemanServer, :TaskProvider, :Telemetry]
             ] ->
          {node, [event_ast | acc]}

        node, acc ->
          {node, acc}
      end)

    event_asts
    |> Enum.reverse()
    |> Enum.map(&resolve_event_ast(&1, attrs))
  end

  defp module_attributes(ast) do
    {_ast, attrs} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) ->
          {node, Map.put(acc, name, value)}

        node, acc ->
          {node, acc}
      end)

    attrs
  end

  defp resolve_event_ast(list, _attrs) when is_list(list) do
    if Enum.all?(list, &is_atom/1),
      do: list,
      else: flunk("expected atom event path, got: #{inspect(list)}")
  end

  defp resolve_event_ast({:@, _, [{name, _, nil}]}, attrs) do
    attrs
    |> Map.fetch!(name)
    |> resolve_event_ast(attrs)
  end

  defp resolve_event_ast({:++, _, [left, right]}, attrs) do
    resolve_event_ast(left, attrs) ++ resolve_event_ast(right, attrs)
  end

  defp resolve_event_ast(ast, _attrs) do
    flunk("unable to resolve telemetry event AST: #{Macro.to_string(ast)}")
  end

  def handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end
end
