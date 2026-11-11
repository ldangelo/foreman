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

  `verdict/3` is fail-closed: a class with no reconciler, a reconciler that
  returns anything but the three atoms, and one that raises, throws or exits all
  produce `:unknown` / `:unregistered`, never `:not_done`.

  The registry maps an effect class name (the string `Effect` writes as
  `"effect_class"`: `"branch_push"`, `"pr_create"`, `"task_provider"`) to its
  module. Phase 0 registers none yet: the push and PR-create reconcilers land in
  TRD-013 and the task-provider one in TRD-015, so those classes block fail
  closed until then. The registry is read from
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

  @doc "The class name stored in a key's metadata, or `nil`."
  @spec class_of(map()) :: String.t() | nil
  def class_of(metadata), do: binary_field(metadata, "effect_class", :effect_class)

  @doc "The run id stored in a key's metadata, or `nil`."
  @spec run_id_of(map()) :: String.t() | nil
  def run_id_of(metadata), do: binary_field(metadata, "run_id", :run_id)

  defp binary_field(metadata, name, atom_name) when is_map(metadata) do
    value = Map.get(metadata, name) || Map.get(metadata, atom_name)
    if is_binary(value) and value != "", do: value, else: nil
  end

  defp binary_field(_metadata, _name, _atom_name), do: nil

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
end
