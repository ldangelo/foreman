defmodule ForemanServer.Architecture.AdmissionFacadeBypassTest do
  use ExUnit.Case, async: true

  @dispatch_run_start_regex ~r/CommandRouter\.dispatch_run_start\s*\(/
  @lib_root Path.expand("../../../lib", __DIR__)
  @allowlisted_modules MapSet.new([
                         ForemanServer.RunAdmission,
                         ForemanServer.CommandRouter
                       ])

  test "only allowlisted modules call CommandRouter.dispatch_run_start/3 directly" do
    files = source_files(@lib_root)

    assert files != [], "No source files found under #{@lib_root}"

    hits = Enum.flat_map(files, &dispatch_run_start_hits/1)

    assert hits != [], "Expected scanner to find at least one dispatch_run_start callsite"

    assert Enum.all?(hits, &MapSet.member?(@allowlisted_modules, &1.module)),
           "Unexpected direct CommandRouter.dispatch_run_start/3 callsites:\n" <>
             format_hits(reject_allowlisted(hits))

    assert Enum.any?(hits, &(&1.module == ForemanServer.RunAdmission)),
           "Expected scanner to find RunAdmission direct dispatch callsite"
  end

  defp reject_allowlisted(hits) do
    Enum.reject(hits, &MapSet.member?(@allowlisted_modules, &1.module))
  end

  defp dispatch_run_start_hits(file) do
    module = module_name(file)

    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if Regex.match?(@dispatch_run_start_regex, line) do
        [
          %{
            file: Path.relative_to_cwd(file),
            line: line_number,
            module: module,
            source: String.trim(line)
          }
        ]
      else
        []
      end
    end)
  end

  defp module_name(file) do
    file
    |> File.read!()
    |> then(&Regex.run(~r/^defmodule\s+([A-Za-z0-9_.!?]+)\s+do/m, &1, capture: :all_but_first))
    |> case do
      [module_name] -> Module.concat([module_name])
      _ -> raise "Unable to determine module name for #{Path.relative_to_cwd(file)}"
    end
  end

  defp source_files(root) do
    root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/_build/"))
  end

  defp format_hits([]), do: "  (none)"

  defp format_hits(hits) do
    Enum.map_join(hits, "\n", fn %{file: file, line: line, module: module, source: source} ->
      "  - #{inspect(module)} #{file}:#{line} => #{source}"
    end)
  end
end
