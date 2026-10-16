defmodule ForemanServer.AgentRuntime.JidoHarness.ModelCatalog do
  @moduledoc """
  Checks whether a requested model id actually exists for a provider, before a
  phase is dispatched. Foreman refuses to pay for a worktree and an agent
  session on a model the harness cannot load, so a wrong `models.default` is a
  manifest/preflight error, not a runtime crash.

  `:pi` is queried directly: `pi --list-models "<pattern>"` prints a table
  whose rows carry the PROVIDER name and the MODEL id in separate columns.
  The searched value is decomposed on its FIRST `/`: with both halves
  non-empty it is a `"<provider>/<model-id>"` pair and matches a row only when
  BOTH columns equal the two halves; otherwise the whole value is a bare model
  id and matches on the `model` column alone. Provider-scoping is what makes
  `minimax/MiniMax` fail when only `anthropic` carries a `MiniMax` model,
  instead of matching any provider's row. The qualified form is also exactly
  the string the catalog itself prints (e.g. `"minimax/MiniMax-M2.7"`) —
  confirmed working end-to-end with `pi --model minimax/MiniMax-M2.7`, no
  separate `--provider` flag required. A bare (unqualified) id is also accepted
  and matches on the `model` column alone, which can match more than one
  upstream provider's catalog entry; that is a real existence check, just not
  provider-scoped.

  Outcomes stay distinct, because `PreflightFailure` classifies on them and
  §5.3 forbids collapsing an unanswered question into a negative answer: a
  table with a matching row (`:ok`), `:model_not_found` (the catalog ANSWERED:
  a table with no matching row, or pi's own negative banners), and
  `{:error, {:catalog_query_failed, _}}` (the catalog could NOT be asked:
  non-zero exit, timeout, `pi` unreadable, or exit-0 output pi does not
  print).
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

  # One decomposition of the searched value, total over both shapes, instead
  # of composing a candidate string and comparing it. The previous form built
  # `"#{row_provider}/#{row_model}"` whenever the searched value happened to
  # contain a `/`, so a vendor-qualified workflow default (`MiniMax`) was
  # compared against composed row keys (`minimax/MiniMax-M2.7`) and could never
  # match — the failure reported for run-0381b526.
  #
  # Splitting on the FIRST `/` only:
  #
  #   * qualified `"<provider>/<model-id>"` — a row matches iff BOTH its
  #     provider column and its model column equal the two halves, so a
  #     `MiniMax` model id under an `anthropic` provider no longer satisfies a
  #     search for `minimax/MiniMax`;
  #   * unqualified `<model-id>` — a row matches on the model column alone,
  #     the provider-scoped-absent case documented in the moduledoc.
  #
  # Comparison stays case-exact: `pi --list-models` is a substring filter, so
  # the caller's own string already drove the row set, and relaxing case here
  # would make the check looser than the query it is validating.
  #
  # pi 1.2.0's `list-models` exits 0 in exactly four shapes
  # (`dist/cli/list-models.js` + `core/auth-guidance.js`): a column table;
  # `No models matching "<x>"`; `No models available. …` (the
  # formatNoModelsAvailableMessage lead, when zero models are configured); or,
  # when models.json failed to LOAD, a `Warning:` on STDERR with stdout EMPTY.
  # Anything else reaching a match decision was not pi answering the query and
  # must not be reported as a negative answer (§5.3) — an `Enum.any?` default
  # of "not found" over garbage stdout would be exactly that lie.
  #
  # Classification is line-scanned, not first-line-only: a host `pi` wrapper
  # can print its own notice to stdout ahead of pi's output (observed in the
  # wild: "bili: attaching to running proxy ..."), and a first-line-only
  # classifier would turn pi's real answer into `:unrecognized_output`.
  defp parse_result(output, model) do
    cond do
      String.trim(output) == "" ->
        {:error, {:catalog_query_failed, :empty_output}}

      true ->
        lines = String.split(output, "\n", trim: true)

        if Enum.any?(lines, &negative_banner?/1) do
          {:error, {:model_not_found, model}}
        else
          parse_table(lines, model)
        end
    end
  end

  defp parse_table(lines, model) do
    case Enum.find_index(lines, &table_header?/1) do
      nil ->
        {:error, {:catalog_query_failed, :unrecognized_output}}

      header_index ->
        rows = Enum.slice(lines, (header_index + 1)..-1//1)

        if Enum.any?(rows, &row_matches?(&1, model)) do
          :ok
        else
          {:error, {:model_not_found, model}}
        end
    end
  end

  # pi's own negative answers. Both are single-line `console.log` calls, so a
  # banner line can never also be a table row. Prefix-matched so upstream
  # wording drift makes them refuse to classify, never over-classify.
  defp negative_banner?(line) do
    String.starts_with?(line, "No models matching ") or
      String.starts_with?(line, "No models available.")
  end

  # pi's header line is the six column names padEnd-joined by two spaces; the
  # first two tokens are the stable "pi printed a table here" discriminator.
  defp table_header?(line) do
    String.split(line) |> Enum.take(2) == ["provider", "model"]
  end

  # pi's rows carry six whitespace-separated columns (provider, model,
  # context, max-out, thinking, images). A line with a different arity is not
  # a row pi printed, so it must never satisfy a search: a stray two-token
  # notice on stdout would otherwise read as a provider+model pair against the
  # bare-model clause below.
  defp row_matches?(line, model) do
    case String.split(line) do
      [row_provider, row_model | rest] when length(rest) >= 4 ->
        case split_qualified(model) do
          {provider, model_id} -> row_provider == provider and row_model == model_id
          :unqualified -> row_model == model
        end

      _other ->
        false
    end
  end

  # A value with no `/`, an empty half (`"/x"`, `"x/"`), or no `/` at all is
  # treated as a bare model id and matched on the model column — never as a
  # prefix that matches every provider's rows.
  defp split_qualified(model) do
    case String.split(model, "/", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" -> {provider, model_id}
      _other -> :unqualified
    end
  end
end
