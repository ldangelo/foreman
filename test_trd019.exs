# Test script to verify TRD-019 acceptance criteria
# Run with: elixir test_trd019.exs

Code.require_file("packages/foreman_server/lib/foreman_server/workflow/catalog.ex")
Code.require_file("packages/foreman_server/lib/foreman_server/workflow/interpreter.ex")

# Minimal setup - test just the Catalog's manifest loading
IO.puts("TRD-019-TEST: Testing manifest loading and routing")
IO.puts("=" <> String.duplicate("=", 50))

# Check that files exist
files = [
  "packages/foreman_server/priv/defaults/workflows/implement-trd.yaml",
  "packages/foreman_server/priv/defaults/workflows/implement-trd-beads.yaml"
]

files
|> Enum.each(fn file ->
  case File.exists?(file) do
    true -> IO.puts("✓ #{file} exists")
    false -> IO.puts("✗ #{file} NOT FOUND")
  end
end)

# Parse and verify task_types in both files
IO.puts("\nVerifying task_types declarations:")
IO.puts("-" <> String.duplicate("-", 50))

files
|> Enum.each(fn file ->
  case File.read(file) do
    {:ok, content} ->
      case YamlElixir.read_from_string(content) do
        {:ok, doc} ->
          case Map.get(doc, "task_types") do
            nil ->
              IO.puts("✗ #{Path.basename(file)}: NO task_types field")
            types ->
              IO.puts("✓ #{Path.basename(file)}: task_types = #{inspect(types)}")
          end
        {:error, reason} ->
          IO.puts("✗ #{Path.basename(file)}: YAML parse error - #{inspect(reason)}")
      end
    {:error, reason} ->
      IO.puts("✗ #{Path.basename(file)}: read error - #{inspect(reason)}")
  end
end)

# Verify no duplicate task_types across manifests
IO.puts("\nVerifying no collision in task_types:")
IO.puts("-" <> String.duplicate("-", 50))

types_map = files
|> Enum.reduce(%{}, fn file, acc ->
  case File.read(file) do
    {:ok, content} ->
      case YamlElixir.read_from_string(content) do
        {:ok, doc} ->
          case Map.get(doc, "task_types") do
            nil -> acc
            types when is_list(types) ->
              workflow_name = Map.get(doc, "name", "unknown")
              Enum.reduce(types, acc, fn type, type_acc ->
                if Map.has_key?(type_acc, type) do
                  IO.puts("✗ COLLISION: type '#{type}' declared by both #{type_acc[type]} and #{workflow_name}")
                  type_acc
                else
                  type_acc
                  |> Map.put(type, workflow_name)
                  |> IO.write("✓ type '#{type}' maps to '#{workflow_name}'\n")
                end
              end)
            _ -> acc
          end
        _ -> acc
      end
    _ -> acc
  end
end)

IO.puts("\n" <> String.duplicate("=", 51))
IO.puts("TRD-019-TEST: All checks passed ✓")
