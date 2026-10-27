defmodule ForemanServer.TestSupport.SourceIndex do
  @moduledoc """
  Reads and parses a source file once per test VM, for the architecture tests that scan `lib/`.

  A dozen tests each walked all ~650 files of `lib/` (5.7 MB), reading and tokenizing every one of
  them again; on a 4-vCPU CI runner that was several seconds of CPU per test, on the async phase
  every other module waits behind. They now share one copy per file.

  The entries live in `:persistent_term` (no owner process, reads copy nothing). The first caller
  of a file computes it under a `:global` lock, so concurrent async modules wait for that one
  parse instead of all doing it.

  Entries are never invalidated: sources do not change while the suite runs. A file's AST is
  parsed with `lines: true, columns: true`, a superset of what the callers asked for before.
  """

  @type path :: Path.t()

  @doc "The file's contents."
  @spec source!(path()) :: String.t()
  def source!(path), do: fetch({:source, path}, fn -> File.read!(path) end)

  @doc "The file's AST (`Code.string_to_quoted!/2` with `lines: true, columns: true`)."
  @spec quoted!(path()) :: Macro.t()
  def quoted!(path) do
    fetch({:quoted, path}, fn ->
      path |> source!() |> Code.string_to_quoted!(lines: true, columns: true)
    end)
  end

  defp fetch(key, compute) do
    pt_key = {__MODULE__, key}

    case :persistent_term.get(pt_key, :missing) do
      :missing ->
        :global.trans({{__MODULE__, key}, self()}, fn ->
          case :persistent_term.get(pt_key, :missing) do
            :missing ->
              value = compute.()
              :persistent_term.put(pt_key, value)
              value

            value ->
              value
          end
        end)

      value ->
        value
    end
  end
end
