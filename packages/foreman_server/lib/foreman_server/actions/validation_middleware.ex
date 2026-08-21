defmodule ForemanServer.Actions.ValidationMiddleware do
  @moduledoc """
  Validates action parameters before execution.

  Wraps `Jido.Action.run/2` to enforce schema validation via `NimbleOptions`.
  Logs and rejects malformed params before they reach the action body.

  TRD-2026-4212be7e / JAF-T003 / TRD-013.

  ## Usage

      next = fn validated_params, context ->
        action_module.run(validated_params, context)
      end

      ForemanServer.Actions.ValidationMiddleware.call(
        SomeJidoAction,
        params,
        context,
        next
      )

  ## Notes

  `Jido.Action` does not ship a `Jido.Action.Middleware` behaviour as of
  the version pinned in `packages/foreman_server/deps/jido_action`, so this
  module deliberately exposes a plain `call/4` function rather than
  declaring a `@behaviour`. Any wrapper that wants to compose multiple
  pre-execution hooks should chain `call/4` invocations instead.
  """

  require Logger

  @doc """
  Validates `params` against `action_module.schema/0` and, on success,
  invokes `next.(validated_params, context)`.

  Accepts `params` as either a keyword list (preferred by `NimbleOptions`)
  or a map (common in Jido/Elixir action invocations). Maps are converted
  to keyword lists before validation. Returns `{:ok, result}` on success
  or `{:error, {:invalid_params, params}}` when validation fails.
  """
  @spec call(module(), NimbleOptions.options(), map(), (map(), map() -> any())) ::
          {:ok, any()} | {:ok, any(), any()} | {:error, any()}
  def call(action_module, params, context, next) when is_function(next, 2) do
    schema = action_module.schema()

    with {:ok, normalized} <- normalize_params(action_module, params),
         {:ok, validated} <- NimbleOptions.validate(normalized, schema) do
      next.(fill_optional_keys(Map.new(validated), schema), context)
    else
      {:error, %NimbleOptions.ValidationError{} = err} ->
        Logger.warning(
          "[ForemanServer.Actions.ValidationMiddleware] rejected params for #{inspect(action_module)}: #{Exception.message(err)}"
        )

        {:error, {:invalid_params, params}}

      {:error, _} = err ->
        err
    end
  end

  # Fill missing optional schema keys with `nil`. Without this,
  # NimbleOptions drops optional fields not provided by the caller, so
  # actions using dot-access (`params.age`) raise `KeyError` instead of
  # receiving the expected `nil`. Required fields cannot be missing
  # because NimbleOptions rejects them with `required option not found`.
  defp fill_optional_keys(validated, schema) do
    Enum.reduce(schema, validated, fn {key, _opts}, acc ->
      if Map.has_key?(acc, key), do: acc, else: Map.put(acc, key, nil)
    end)
  end

  defp normalize_params(action_module, params) when is_map(params) and not is_list(params) do
    {:ok, Map.to_list(params)}
  end

  defp normalize_params(_action_module, params) when is_list(params) do
    {:ok, params}
  end

  defp normalize_params(action_module, params) do
    Logger.warning(
      "[ForemanServer.Actions.ValidationMiddleware] rejected params for #{inspect(action_module)}: expected map or keyword list, got #{inspect(params)}"
    )

    {:error, {:invalid_params, params}}
  end
end
