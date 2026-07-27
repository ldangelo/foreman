defmodule ForemanServer.TestSupport.TestRouter do
  @moduledoc """
  Thin dispatch wrapper for test commands.

  Provides a `dispatch/1-2` function that delegates to `CommandRouter.dispatch/2`.
  Tests call `TestRouter.dispatch(command)` rather than importing CommandRouter directly.
  """

  @spec dispatch(command :: map(), timeout :: integer()) ::
          {:ok, event_spec :: map() | nil}
          | {:error, any()}
  defdelegate dispatch(command, timeout \\ 5_000), to: ForemanServer.CommandRouter
end
