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

  Returns `{:ok, result}` on success or `{:error, {:invalid_params, params}}`
  when validation fails.
  """
  @spec call(module(), map(), map(), (map(), map() -> any())) ::
          {:ok, any()} | {:ok, any(), any()} | {:error, any()}
  def call(action_module, params, context, next) when is_map(params) and is_function(next, 2) do
    schema = action_module.schema()

    case NimbleOptions.validate(params, schema) do
      {:ok, validated} ->
        next.(validated, context)

      {:error, %NimbleOptions.ValidationError{} = err} ->
        Logger.warning(
          "[ForemanServer.Actions.ValidationMiddleware] rejected params for #{inspect(action_module)}: #{Exception.message(err)}"
        )

        {:error, {:invalid_params, params}}
    end
  end

  def call(_action_module, params, _context, _next) do
    {:error, {:invalid_params, params}}
  end
end
