defmodule ForemanServer.MigrationImporterTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MigrationImporter

  # Cross-VM-stable IDs: System.unique_integer/1 resets per BEAM startup, so reused
  # prefixes collide with aggregates persisted from prior runs against the same DB.
  defp unique_id(prefix),
    do: "#{prefix}-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"

  setup do
    # Make sure shared Inbox infrastructure is up (affects ingest path).
    case Process.whereis(ForemanServer.Inbox.Poller) do
      nil ->
        {:ok, _pid} = ForemanServer.Inbox.Poller.start_link([])

      pid ->
        if not Process.alive?(pid), do: {:ok, _pid} = ForemanServer.Inbox.Poller.start_link([])
    end

    :ok
  end

  describe "start_import/1" do
    test "dispatches via CommandRouter with migration aggregate id" do
      assert {:ok, _} =
               MigrationImporter.start_import(%{
                 import_id: unique_id("batch"),
                 source: "fixture-seed",
                 initiated_by: "test"
               })
    end

    test "raises when :import_id is missing" do
      assert_raise ArgumentError, fn ->
        MigrationImporter.start_import(%{source: "x"})
      end
    end
  end

  describe "import_record/1" do
    test "dispatches via CommandRouter keyed by import_id" do
      import_id = unique_id("rec")
      assert {:ok, _} = MigrationImporter.start_import(%{import_id: import_id, source: "fixture"})

      assert {:ok, _} =
               MigrationImporter.import_record(%{
                 import_id: import_id,
                 record_id: "rec-1",
                 data: %{"a" => 1}
               })
    end

    test "raises when :record_id is missing" do
      assert_raise ArgumentError, fn ->
        MigrationImporter.import_record(%{import_id: "x"})
      end
    end
  end

  describe "complete_import/1" do
    test "dispatches completion event" do
      import_id = unique_id("done")
      assert {:ok, _} = MigrationImporter.start_import(%{import_id: import_id, source: "x"})
      assert {:ok, _} = MigrationImporter.complete_import(%{import_id: import_id})
    end
  end

  describe "process/1" do
    test "processes a batch of records end-to-end" do
      import_id = unique_id("batch-proc")

      assert {:ok, results} =
               MigrationImporter.process(%{
                 import_id: import_id,
                 source: "fixture",
                 records: [
                   %{record_id: "r1", data: %{}},
                   %{record_id: "r2", data: %{}}
                 ]
               })

      assert length(results) == 2
      assert Enum.all?(results, &match?({:ok, _}, &1))
    end

    test "rejects missing :records field" do
      assert {:error, :missing_records} = MigrationImporter.process(%{import_id: "x"})
    end
  end
end
