defmodule ForemanServerWeb.MCP.Tools.Doctor do
  @moduledoc """
  `foreman server doctor` MCP tool — surfaces the readiness of every
  jido_harness provider the dispatch pipeline can target.

  The tool delegates the readiness probe to
  `ForemanServer.AgentRuntime.JidoHarness.ReadinessCheck` and renders the
  result as a deterministic multi-line report. The same module is
  invoked by the `ForemanServer.MCP.Tools.call_tool("foreman_doctor", _)`
  plumbing and by the `foreman server doctor` CLI mix task.

  ## Output format

      Provider readiness
      ✓ pi available
      ✗ claude not found — install with: npm install -g @anthropic-ai/claude-code

  ## Strict mode

  When `:strict` is passed and at least one required provider is missing,
  `run/1` returns `{:error, :provider_missing, output}` so callers (CLI
  mix task, CI gates) can fail with a non-zero exit code while still
  surfacing the rendered report.
  """

  alias ForemanServer.AgentRuntime.JidoHarness.ReadinessCheck
  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.ProjectionStore

  @type provider_result :: {:provider, atom(), :installed | :not_installed, String.t()}

  @typedoc """
  One unresolved effect key: the key, its effect class and run id (read from the
  record's string-keyed metadata, `"unknown"` when a field is missing) and the
  run's status from the projection (`"unknown"` when it could not be read,
  `"not_found"` when the run has no projection).
  """
  @type effect_entry :: %{
          key: String.t(),
          class: String.t(),
          run_id: String.t(),
          status: String.t()
        }

  @spec run(keyword()) :: {:ok, String.t()} | {:error, :provider_missing, String.t()}
  def run(opts \\ []) when is_list(opts) do
    results = rows()
    output = format(results) <> "\n\n" <> effect_keys_section()

    if Keyword.get(opts, :strict, false) and Enum.any?(results, &missing?/1) do
      {:error, :provider_missing, output}
    else
      {:ok, output}
    end
  end

  @doc """
  Returns the raw `{:provider, atom, :installed | :not_installed, hint}`
  rows produced by `ReadinessCheck.run/0`. Used by the `foreman_doctor`
  MCP tool to expose structured rows alongside the formatted output.
  """
  @spec rows() :: [provider_result()]
  def rows, do: ReadinessCheck.run()

  @doc """
  Renders the readiness rows as a multi-line report.
  """
  @spec format([provider_result()]) :: String.t()
  def format(results) when is_list(results), do: ReadinessCheck.format(results)

  @doc """
  Every ambiguous effect key (`KeyStore.effect_key?/1`), sorted by key, with its
  class, run id and the run's status. `{:error, :unavailable}` when the keys
  cannot be read (the `KeyStore` is not running, or the repo is configured but
  the read fails): an unreadable store is never an empty list.

  The list is by effect key, not by run: a key is listed whatever its run's
  status, because the verdict of a terminal run's key is only logged. Phase 0
  has no way to resolve or clear an ambiguous key.
  """
  @spec unresolved_effect_keys() :: {:ok, [effect_entry()]} | {:error, :unavailable}
  def unresolved_effect_keys do
    case KeyStore.list_records_checked(:ambiguous) do
      {:ok, records} ->
        entries =
          records
          |> Enum.filter(&KeyStore.effect_key?(&1.key))
          |> Enum.sort_by(& &1.key)
          |> Enum.map(&effect_entry/1)

        {:ok, entries}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  @doc "The one-line store durability statement (`✓ ...` durable, `✗ ...` not)."
  @spec store_line() :: String.t()
  def store_line do
    case KeyStore.durability_note() do
      nil -> "✓ idempotency store is durable (repo-backed); effect keys survive a restart"
      note -> "✗ " <> note
    end
  end

  @doc """
  The Phase 1 gating line (P-3), printed next to `store_line/0`: whether a durable store is
  required to gate a project (`KeyStore.durable_store_required?/0`) and, if so, whether it is met
  (`KeyStore.require_durable/0`). `✓` when not required or met, `✗` when required and not met.
  """
  @spec gating_line() :: String.t()
  def gating_line do
    if KeyStore.durable_store_required?() do
      case KeyStore.require_durable() do
        :ok ->
          "✓ Phase 1 gating: durable store required and met"

        {:error, {:store_not_durable, note}} ->
          "✗ Phase 1 gating: durable store required and NOT met: " <> note
      end
    else
      "✓ Phase 1 gating: durable store not required " <>
        "(config :foreman_server, :require_durable_store_for_gating is false)"
    end
  end

  @doc "One report line for an effect entry."
  @spec effect_entry_line(effect_entry()) :: String.t()
  def effect_entry_line(%{key: key, class: class, run_id: run_id, status: status}),
    do: "#{class} run=#{run_id} status=#{status} key=#{key}"

  @doc """
  The entries as report lines. On the ETS fallback an empty list says so: keys
  from before the last restart are not listed, so it is not read as clean.
  """
  @spec effect_entry_lines([effect_entry()]) :: [String.t()]
  def effect_entry_lines(entries) do
    case {entries, KeyStore.durable?()} do
      {[], true} ->
        ["none"]

      {[], false} ->
        ["none in this process (keys from before the last restart are not listed)"]

      {entries, _durable} ->
        Enum.map(entries, &effect_entry_line/1)
    end
  end

  @doc "The store line plus the `Unresolved effect keys` section."
  @spec effect_keys_section() :: String.t()
  def effect_keys_section do
    body =
      case unresolved_effect_keys() do
        {:ok, entries} ->
          entries |> effect_entry_lines() |> Enum.map_join("\n", &("  " <> &1))

        {:error, :unavailable} ->
          "  could not be read"
      end

    "Idempotency store\n" <>
      store_line() <> "\n" <> gating_line() <> "\n\nUnresolved effect keys\n" <> body
  end

  defp effect_entry(%{key: key, metadata: metadata}) do
    metadata = if is_map(metadata), do: metadata, else: %{}
    run_id = Map.get(metadata, "run_id")

    %{
      key: key,
      class: text(Map.get(metadata, "effect_class")),
      run_id: text(run_id),
      status: run_status(run_id)
    }
  end

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: "unknown"

  # `ProjectionStore.run/1` is a GenServer.call: it exits when the store is down or does
  # not answer, and its guard needs a non-empty binary.
  defp run_status(run_id) when is_binary(run_id) and run_id != "" do
    case ProjectionStore.run(run_id) do
      nil -> "not_found"
      %{status: status} when is_binary(status) -> status
      _other -> "unknown"
    end
  catch
    :exit, _reason -> "unknown"
  end

  defp run_status(_run_id), do: "unknown"

  @spec missing?(provider_result()) :: boolean()
  defp missing?({:provider, _provider, :not_installed, _hint}), do: true
  defp missing?(_result), do: false
end
