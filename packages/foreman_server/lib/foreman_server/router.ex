defmodule ForemanServer.Router do
  use Commanded.Commands.Router

  identify ForemanServer.AC1RunAggregate, by: :run_id
  dispatch ForemanServer.Commands.StartRun, to: ForemanServer.AC1RunAggregate
end
