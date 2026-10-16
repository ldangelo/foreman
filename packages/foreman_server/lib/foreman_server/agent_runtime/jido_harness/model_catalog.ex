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
  §5.3 forbids collapsing an unanswered question into a negative answer:
  `:ok` (the catalog answered, and a row matches), `:model_not_found` (the
  catalog ANSWERED, and nothing matches), and
  `{:error, {:catalog_query_failed, _}}` (the catalog could NOT be asked:
  non-zero exit, timeout, `pi` unreadable, empty output, output that is not
  pi's, or a row about the searched model that is too truncated to read).
  """

  alias ForemanServer.Telemetry

  @query_timeout_ms 5_000
  # provider, model, context, max-out, thinking, images — pi 1.2.0's
  # `list-models` row, padEnd-joined.
  @row_columns 6

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
  # The table path is the authority; a negative banner is only ever the
  # fallback for output that is NOT a table, which is why the check lives in
  # `parse_table/2` and not above it: pi's own table can legitimately contain a
  # line that begins with a banner prefix, and a wrapper notice that
  # incidentally spells one must not overwrite the answer the table gives.
  defp parse_result(output, model) do
    if String.trim(output) == "" do
      {:error, {:catalog_query_failed, :empty_output}}
    else
      parse_table(String.split(output, "\n", trim: true), model)
    end
  end

  defp parse_table(lines, model) do
    case Enum.find_index(lines, &table_header?/1) do
      nil ->
        # No table. A complete negative banner naming THIS search is pi having
        # answered; anything else is output that was never an answer.
        if Enum.any?(lines, &negative_banner?(&1, model)) do
          {:error, {:model_not_found, model}}
        else
          {:error, {:catalog_query_failed, :unrecognized_output}}
        end

      header_index ->
        rows = Enum.slice(lines, (header_index + 1)..-1//1)

        case classify_rows(rows, model) do
          {:malformed_row, line} -> {:error, {:catalog_query_failed, {:malformed_row, line}}}
          :hit -> :ok
          :miss -> {:error, {:model_not_found, model}}
        end
    end
  end

  # Malformed, then hit, then miss. A line is a candidate if its first two
  # tokens name the searched provider/model pair — `row_pair?/2` requires two
  # tokens for that, so one-word stdout noise is never a candidate and cannot
  # fail a query. If any candidate is a COMPLETE row the catalog answered:
  # present. If every candidate is truncated, readability is in question and the
  # answer is a query failure, never a false "not present" (§5.3). A truncated
  # row about some OTHER model is not a candidate, so it cannot poison a clean
  # hit.
  defp classify_rows(rows, model) do
    candidates = Enum.filter(rows, &row_pair?(&1, model))

    cond do
      Enum.any?(candidates, &row_complete?/1) ->
        :hit

      candidates != [] ->
        {:malformed_row, hd(candidates)}

      true ->
        :miss
    end
  end

  # "Could this line be about the model that was searched?", ignoring how many
  # further columns the line carries: pi's provider and model columns are the
  # first two fields, so the pair is decided on the first two tokens no matter
  # what trails them.
  defp row_pair?(line, model) do
    case String.split(line) do
      [row_provider, row_model | _rest] ->
        case split_qualified(model) do
          {provider, model_id} -> row_provider == provider and row_model == model_id
          :unqualified -> row_model == model
        end

      _short ->
        false
    end
  end

  # pi's negative answers. `list-models.ts` writes
  # `No models matching "${search}"` with the caller's own search string
  # interpolated, so the searched value has to appear inside the banner before
  # the line is read as an answer to THIS query. Anything else carrying that
  # prefix is truncation or a foreign query, and §5.3 keeps "the catalog says
  # no" apart from "this was never an answer". The other negative — no models
  # configured at all — carries no query, so it answers every search. Both
  # prefixes are matched loosely so upstream wording drift makes them refuse to
  # classify rather than over-classify.
  defp negative_banner?(line, model) do
    String.starts_with?(line, "No models available.") or
      (String.starts_with?(line, "No models matching ") and
         String.contains?(line, "\"" <> model <> "\""))
  end

  # pi's header is `list-models.ts`'s fixed `headers` object, padEnd-joined by
  # two spaces — six column names, of which `max-out` is ONE token (hyphenated,
  # not two columns). All six have to appear, in order. A line that merely starts
  # `provider  model` is a truncated header: `parse_table/2` anchors on the first
  # header it finds and reads everything below it as that table's rows, so
  # accepting such a line lets a fragment of pi's own column header own the
  # search and silently mask the answer (§5.3).
  #
  # PREFIX comparison, not whole-line equality: column widths are computed from
  # the rows (`Math.max(headers.x.length, ...rows.map(...))`), so only `images`,
  # the final column, can carry padding a caller then truncates. The five names
  # before it are matched exactly.
  defp table_header?(line) do
    case String.split(line) do
      ["provider", "model", "context", "max-out", "thinking" | rest] ->
        Enum.any?(rest, &String.contains?(&1, "images"))

      _not_a_header ->
        false
    end
  end

  # A pi row is the provider and model columns plus four capability columns,
  # space-joined. Takes the raw line so one predicate serves every caller
  # instead of forcing each to split first.
  defp row_complete?(line), do: line |> String.split() |> length() >= @row_columns

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
