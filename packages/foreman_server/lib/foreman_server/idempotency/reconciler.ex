defmodule ForemanServer.Idempotency.Reconciler do
  @moduledoc """
  Decides, per effect class, whether an ambiguous keyed effect (`Effect.run/4`,
  TRD-011) already happened.

  A class's reconciler is a module implementing this behaviour. It reads the
  key's stored metadata (string-keyed after a restart; `Effect` writes the same
  fields on every path) and asks the outside world:

    * `:done` - the effect happened (the push is on the remote, the PR exists);
    * `:not_done` - it did not happen, so it may be attempted again;
    * `:unknown` - it could not be established (unreachable provider, an answer
      that is neither of the two).

  The metadata handed to `reconcile/1` is string-keyed: `BootReconciliation`
  normalises what `KeyStore.get/1` returns once, before the registry sees it.

  `verdict/3` is fail-closed: a class with no reconciler, a reconciler that
  returns anything but the three atoms, and one that raises, throws or exits all
  produce `:unknown` / `:unregistered`, never `:not_done`.

  Two optional callbacks describe the class rather than one effect. `repeatable?/1`:
  repeating the effect is harmless, so `Effect.run/4` never refuses its key as
  undecided and the boot sweep does not mark it unresolved. `blocks_run?/1`: a `done`
  or `unknown` verdict may block the run; absent means it may. `repeatable?/3` and
  `blocks_run?/3` read them and are fail-closed too: a class with no reconciler, a
  reconciler without the callback and an answer that is not a boolean are not
  repeatable and do block the run.

  The registry maps an effect class name (the string `Effect` writes as
  `"effect_class"`: `"branch_push"`, `"pr_create"`, `"task_provider"`) to its
  module. The push and PR-create reconcilers (TRD-013) are registered in
  `config/config.exs`; the task-provider one lands in TRD-015, so that class blocks
  fail closed until then. The registry is read from
  `Application.get_env(:foreman_server, #{inspect(__MODULE__)})[:classes]`, or
  from the `:classes` option of `verdict/3`.

  The consumer is `BootReconciliation.do_reconcile_ambiguous_keys/1`, which maps
  a verdict to a run action. This module never touches the key store and never
  calls `CrashRecovery.reconcile/2`.
  """

  require Logger

  @type verdict :: :done | :not_done | :unknown
  @type classes :: %{optional(String.t()) => module()}

  @doc "Reconcile one effect from its stored metadata."
  @callback reconcile(metadata :: map()) :: verdict()

  @doc """
  Optional. True when repeating the effect `metadata` describes is harmless (a
  task-provider `reopen` only moves an `in_progress` issue to `open`; a PR comment is
  found again by its marker), so `Effect.run/4` never refuses its key as undecided and
  the boot sweep does not mark it unresolved. Read it through `repeatable?/3`.
  """
  @callback repeatable?(metadata :: map()) :: boolean()

  @doc """
  Optional. False when a `done` or `unknown` verdict of this effect must not block its
  run (an advisory effect such as a PR comment). Absent means true: the sweep blocks
  and cancels a run whose push or PR create is in doubt. Read it through `blocks_run?/3`.
  """
  @callback blocks_run?(metadata :: map()) :: boolean()

  @optional_callbacks repeatable?: 1, blocks_run?: 1

  @doc "The configured class registry (empty until a class's reconciler is registered)."
  @spec classes() :: classes()
  def classes do
    :foreman_server
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:classes, %{})
  end

  @doc """
  The verdict for an effect of `class` with `metadata`.

  Returns `:unregistered` when no reconciler is registered for the class.
  Options: `:classes` (a registry map replacing the configured one).
  """
  @spec verdict(String.t(), map(), keyword()) :: verdict() | :unregistered
  def verdict(class, metadata, opts \\ []) when is_binary(class) and is_map(metadata) do
    registry = Keyword.get_lazy(opts, :classes, &classes/0)

    case Map.fetch(registry, class) do
      {:ok, module} when is_atom(module) -> run(module, class, metadata)
      _ -> :unregistered
    end
  end

  @doc """
  Whether an effect of `class` with `metadata` is repeatable: the class's reconciler
  declares `repeatable?/1` and answers `true`. A class with no registered reconciler, a
  reconciler without the callback, an answer that is not a boolean and a callback that
  raises, throws or exits are all `false`: an effect not known to be harmless to repeat
  is not repeated. `Effect` and the boot sweep read this one definition.
  Options: `:classes` (a registry map replacing the configured one).
  """
  @spec repeatable?(String.t(), map(), keyword()) :: boolean()
  def repeatable?(class, metadata, opts \\ []) when is_binary(class) and is_map(metadata),
    do: optional(class, metadata, opts, :repeatable?, false)

  @doc """
  Whether a `done` or `unknown` verdict of an effect of `class` with `metadata` may
  block its run: `true` unless the class's reconciler declares `blocks_run?/1` and
  answers `false`. A class with no registered reconciler, a reconciler without the
  callback, an answer that is not a boolean and a callback that raises, throws or exits
  all block: the run of an effect in doubt is not left running.
  Options: `:classes` (a registry map replacing the configured one).
  """
  @spec blocks_run?(String.t(), map(), keyword()) :: boolean()
  def blocks_run?(class, metadata, opts \\ []) when is_binary(class) and is_map(metadata),
    do: optional(class, metadata, opts, :blocks_run?, true)

  @doc "The class name in a key's string-keyed metadata, or `nil`."
  @spec class_of(map()) :: String.t() | nil
  def class_of(metadata), do: binary_field(metadata, "effect_class")

  @doc "The run id in a key's string-keyed metadata, or `nil`."
  @spec run_id_of(map()) :: String.t() | nil
  def run_id_of(metadata), do: binary_field(metadata, "run_id")

  defp binary_field(metadata, name) when is_map(metadata) do
    value = Map.get(metadata, name)
    if is_binary(value) and value != "", do: value, else: nil
  end

  defp binary_field(_metadata, _name), do: nil

  defp run(module, class, metadata) do
    case module.reconcile(metadata) do
      verdict when verdict in [:done, :not_done, :unknown] ->
        verdict

      other ->
        Logger.error(
          "Reconciler: #{inspect(module)} for #{class} returned #{inspect(other)}; treating as unknown"
        )

        :unknown
    end
  rescue
    exception ->
      Logger.error(
        "Reconciler: #{inspect(module)} for #{class} raised #{Exception.message(exception)}; treating as unknown"
      )

      :unknown
  catch
    kind, reason ->
      Logger.error(
        "Reconciler: #{inspect(module)} for #{class} #{kind} #{inspect(reason)}; treating as unknown"
      )

      :unknown
  end

  # An optional boolean callback of the class's reconciler. `default` is the answer for a
  # class with no reconciler, a module without the callback, an answer that is not a
  # boolean and a callback that fails (logged, as `run/3` does for `reconcile/1`).
  defp optional(class, metadata, opts, callback, default) do
    registry = Keyword.get_lazy(opts, :classes, &classes/0)

    with {:ok, module} when is_atom(module) <- Map.fetch(registry, class),
         true <- Code.ensure_loaded?(module) and function_exported?(module, callback, 1) do
      call_optional(module, class, metadata, callback, default)
    else
      _ -> default
    end
  end

  defp call_optional(module, class, metadata, callback, default) do
    case apply(module, callback, [metadata]) do
      answer when is_boolean(answer) ->
        answer

      other ->
        optional_failed(module, class, callback, "returned #{inspect(other)}", default)
    end
  rescue
    exception ->
      optional_failed(module, class, callback, "raised #{Exception.message(exception)}", default)
  catch
    kind, reason ->
      optional_failed(module, class, callback, "#{kind} #{inspect(reason)}", default)
  end

  defp optional_failed(module, class, callback, what, default) do
    Logger.error(
      "Reconciler: #{inspect(module)} for #{class} #{callback}/1 #{what}; treating as #{inspect(default)}"
    )

    default
  end
end
