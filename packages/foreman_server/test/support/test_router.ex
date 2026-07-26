defmodule ForemanServer.TestSupport.TestRouter do
  use Commanded.Commands.Router

  identify(ForemanServer.TestSupport.BlockingAggregate, by: :aggregate_id)

  dispatch(ForemanServer.TestSupport.BlockCommand,
    to: ForemanServer.TestSupport.BlockingAggregate
  )
end
