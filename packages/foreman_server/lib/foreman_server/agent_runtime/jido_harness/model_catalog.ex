defmodule ForemanServer.AgentRuntime.JidoHarness.ModelCatalog do
  @moduledoc """
  Live model-catalog lookup for dispatch providers that expose one.

  Only `:pi` exposes a non-interactive catalog query today
  (`pi --list-models <term>`, confirmed against a live pi 0.84.2 install:
  a matching term prints a `provider  model  ...` table, a non-matching term
  prints `No models matching "<term>"`, both at exit 0). `:claude` (Claude
  Code CLI) has no equivalent flag — `check/2` returns `:unchecked` for it
  rather than silently accepting or guessing at validity.

  For `:pi`, pass `models.default` as the fully-qualified `"<pi-provider>/<model-id>"`
  string the catalog itself prints (e.g. `"minimax/MiniMax-M2.7"`) — confirmed
  working end-to-end with `pi --model minimax/MiniMax-M2.7`, no separate
  `--provider` flag required. A bare (unqualified) id is also accepted and
  matches on the `model` column alone, which can match more than one
  upstream provider's catalog entry; that is a real existence check, just not
  provider-scoped.
  """

  alias ForemanServer.Telemetry

  @query_timeout_ms 5_000

  @spec check(atom(), String.t() | nil) :: :ok | :unchecked | {:error, term()}
  def check(_provider, nil), do: :unchecked
  def check(:pi, model) when is_binary(model), do: pi_model_exists?(model)
  def check(_provider, _model), do: :unchecked

  defp pi_model_exists?(model) do
    # `Task.async/1` LINKS the caller — a raw `System.cmd` :enoent (no `pi`
    # on PATH) or any other exception inside the task crashes RunExecutor
    # itself instead of returning a clean {:error, ...}. Confirmed live:
    # pointing PATH at nowhere and calling this directly terminates the
    # calling process. Catch inside the task so it always returns a value.
    task =
      Task.async(fn ->
        try do
          {:ok, System.cmd("pi", ["--list-models", model], stderr_to_stdout: true)}
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

    result =
      case Task.yield(task, @query_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, {output, 0}}} -> parse_result(output, model)
        {:ok, {:ok, {output, _nonzero}}} -> {:error, {:catalog_query_failed, String.trim(output)}}
        {:ok, {:error, reason}} -> {:error, {:catalog_query_failed, reason}}
        nil -> {:error, {:catalog_query_failed, :timeout}}
      end

    Telemetry.dispatch_model_check(:pi, model, result)
    result
  end

  defp parse_result(output, model) do
    found? =
      output
      |> String.split("\n", trim: true)
      |> Enum.drop(1)
      |> Enum.any?(fn line ->
        case String.split(line) do
          [row_provider, row_model | _] ->
            candidate =
              if String.contains?(model, "/"), do: "#{row_provider}/#{row_model}", else: row_model

            candidate == model

          _ ->
            false
        end
      end)

    if found?, do: :ok, else: {:error, {:model_not_found, model}}
  end
end
