defmodule ForemanServer.Observability.SecretValueLogFilter do
  @moduledoc """
  A `:logger` PRIMARY filter that redacts stored secret VALUES from every log event, whatever
  key or text they arrive in (foreman-25sqf.1.1, the fail-closed follow-up to foreman-mw5rz).

  `config :phoenix, :filter_parameters` hides request params by KEY NAME, so a secret under a
  key nobody listed still reached the debug request log. This filter works by value: a primary
  filter runs before every handler, so one redaction covers the console, the server log file and
  the SigNoz export alike.

  ## What is redacted

  The values `Refresher` publishes: for every registered project, the secret-store values and
  the values of secret-named env variables (`ProjectEnvironment.fetch_secrets/1`, the same list
  persisted text is redacted with), each of at least
  `ProjectEnvironment.min_stored_secret_chars/0` characters. The floor is applied HERE to every
  value, because the project list may hold a short value of a secret-named variable and a
  verbatim match of `"1"` would rewrite every log line.

  A log event is rendered to text only when values are published. A match replaces the whole
  message with `WorkerLogPolicy.redact/2`'s output (the one place a value is replaced: longest
  value first, then the built-in name patterns), as a plain string message. An event with no
  match is returned untouched, term for term.

  ## What it does not cover

    * Log METADATA (`event.meta`) is not rewritten; only the message is.
    * A value that is not yet in the published list: the list is refreshed every
      `refresh_ms` (default 30 s) and immediately after `SecretStore.put/3` and `delete/2`
      (`Refresher`), so a value set by hand in the secrets directory, or a secret-named env
      variable, can be logged for up to one interval.
    * A value shorter than the floor, or a secret the process never stored.
    * Text that is not the value verbatim (a transformed, split or encoded copy).

  ## Failure policy

  The filter never raises: logger removes a filter that crashes, which would silently turn the
  protection off. A message that cannot be rendered while values are published is replaced by a
  fixed notice (fail closed) rather than passed unchecked. If the list cannot be built, the
  previous list stays and `Refresher` logs the project id and error code, never a value.
  """

  alias ForemanServer.Overwatch.WorkerLogPolicy
  alias ForemanServer.ProjectEnvironment

  @filter_id :foreman_secret_values
  @key {__MODULE__, :values}
  @withheld "[log message withheld: could not be checked for stored secret values]"

  @doc "Registers the primary filter. Idempotent."
  @spec install() :: :ok | {:error, term()}
  def install do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Removes the primary filter and the published values."
  @spec uninstall() :: :ok
  def uninstall do
    _ = :logger.remove_primary_filter(@filter_id)
    _ = :persistent_term.erase(@key)
    :ok
  end

  @doc """
  Publishes the values to redact (replacing the previous list). Values shorter than
  `ProjectEnvironment.min_stored_secret_chars/0` are dropped. An empty list switches the filter
  to a pass-through. A list equal to the published one is not rewritten (a `:persistent_term`
  update costs a global GC pass).
  """
  @spec publish([String.t()]) :: :ok
  def publish(values) when is_list(values) do
    floor = ProjectEnvironment.min_stored_secret_chars()

    values =
      values
      |> Enum.filter(&(is_binary(&1) and String.length(&1) >= floor))
      |> Enum.uniq()
      |> Enum.sort()

    cond do
      values == [] ->
        _ = :persistent_term.erase(@key)
        :ok

      match?({_, ^values}, :persistent_term.get(@key, nil)) ->
        :ok

      true ->
        :persistent_term.put(@key, {:binary.compile_pattern(values), values})
    end
  end

  @doc "The number of published values (for diagnostics and tests; never the values)."
  @spec count() :: non_neg_integer()
  def count do
    case :persistent_term.get(@key, nil) do
      {_pattern, values} -> length(values)
      nil -> 0
    end
  end

  @doc false
  @spec filter(:logger.log_event(), term()) :: :logger.log_event()
  def filter(%{msg: msg} = event, _extra) do
    case :persistent_term.get(@key, nil) do
      nil -> event
      {pattern, values} -> redact_event(event, msg, pattern, values)
    end
  end

  def filter(event, _extra), do: event

  defp redact_event(event, msg, pattern, values) do
    text = render(msg)

    case :binary.match(text, pattern) do
      :nomatch -> event
      _hit -> %{event | msg: {:string, WorkerLogPolicy.redact(text, values)}}
    end
  rescue
    _ -> %{event | msg: {:string, @withheld}}
  catch
    _kind, _reason -> %{event | msg: {:string, @withheld}}
  end

  defp render({:string, data}), do: IO.chardata_to_string(data)

  defp render({:report, report}),
    do: inspect(report, limit: :infinity, printable_limit: :infinity)

  defp render({format, args}) when is_list(args),
    do: format |> :io_lib.format(args) |> IO.chardata_to_string()
end
