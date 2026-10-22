defmodule ForemanServer.TaskProviders.JsonSchemaCacheBrSchemaTest do
  @moduledoc """
  `JsonSchemaCache.validate/2` against the REAL `br schema` documents
  (`test/fixtures/br/schema_*.json`, verbatim br 0.6.0 output).

  br wraps its schemas (`{"tool", "generated_at", "schemas": {"ReadyIssue": ...}}`)
  and the cache used to look for a top-level `required`/`properties`, so every
  payload was accepted (foreman-mlklw). The hand-written flat schemas in
  `json_schema_cache_test.exs` could not see that.
  """
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.JsonSchemaCache
  alias ForemanServer.TestSupport.BrFixtures

  @cache_name :foreman_server_json_schema_cache

  setup_all do
    {:ok, _} = Application.ensure_all_started(:mox)
    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stop_cache()

    stub(BrRunnerMock, :cmd, fn {:schema, %{schema: name}}, _cfg, _opts ->
      {:ok, %{stdout: BrFixtures.read!("schema_" <> String.replace(name, "-", "_") <> ".json")}}
    end)

    start_supervised!(JsonSchemaCache)
    on_exit(&stop_cache/0)
    :ok
  end

  test "real br issue payloads satisfy the real schemas" do
    assert :ok = JsonSchemaCache.validate(:issue_details, BrFixtures.issue!("show_plain.json"))
    assert :ok = JsonSchemaCache.validate(:ready_issue, hd(BrFixtures.decode!("ready.json")))
    assert :ok = JsonSchemaCache.validate(:commands, BrFixtures.decode!("schema_commands.json"))
  end

  test "a show payload missing required fields is rejected" do
    payload = Map.drop(BrFixtures.issue!("show_plain.json"), ["id", "status"])

    assert {:error, errors} = JsonSchemaCache.validate(:issue_details, payload)
    assert %{path: ["id"], message: "is required"} in errors
    assert %{path: ["status"], message: "is required"} in errors
  end

  test "a show payload with a wrongly typed field is rejected" do
    payload = Map.put(BrFixtures.issue!("show_plain.json"), "priority", "high")

    assert {:error, errors} = JsonSchemaCache.validate(:issue_details, payload)
    assert Enum.any?(errors, &(&1.path == ["priority"]))
  end

  test "a ready/claim payload missing required fields is rejected" do
    payload = Map.drop(hd(BrFixtures.decode!("ready.json")), ["title", "labels"])

    assert {:error, errors} = JsonSchemaCache.validate(:ready_issue, payload)
    assert %{path: ["title"], message: "is required"} in errors
    assert %{path: ["labels"], message: "is required"} in errors
  end

  test "a commands document without a commands inventory is rejected" do
    assert {:error, errors} = JsonSchemaCache.validate(:commands, %{"tool" => "br"})
    assert %{path: ["commands"], message: "is required"} in errors
  end

  test "real br update acknowledgements satisfy the pinned ack contract, malformed ones do not" do
    ack = hd(BrFixtures.decode!("update_claim.json"))

    for atom <- [:claimed_issue, :reopened_issue, :failed_issue] do
      assert :ok = JsonSchemaCache.validate(atom, ack)
      assert {:error, errors} = JsonSchemaCache.validate(atom, Map.delete(ack, "id"))
      assert %{path: ["id"], message: "is required"} in errors
    end

    assert {:error, errors} = JsonSchemaCache.validate(:claimed_issue, Map.delete(ack, "title"))
    assert %{path: ["title"], message: "is required"} in errors
  end

  test "real br dependency/dependent references satisfy the reference contract" do
    ref = hd(hd(BrFixtures.decode!("show_labels_with_dependency.json"))["dependencies"])

    assert :ok = JsonSchemaCache.validate(:issue_reference, ref)
    assert {:error, _} = JsonSchemaCache.validate(:issue_reference, Map.delete(ref, "status"))
  end

  defp stop_cache do
    case Process.whereis(@cache_name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end
end
