defmodule ForemanServer.Router do
  use Commanded.Commands.Router

  # AC1 Run aggregate
  identify(ForemanServer.AC1RunAggregate, by: :run_id)
  dispatch(ForemanServer.Commands.StartRun, to: ForemanServer.AC1RunAggregate)
  dispatch(ForemanServer.Commands.CompleteRun, to: ForemanServer.AC1RunAggregate)

  # AC1 Project aggregate
  identify(ForemanServer.AC1ProjectAggregate, by: :project_id)
  dispatch(ForemanServer.Commands.RegisterProject, to: ForemanServer.AC1ProjectAggregate)
  dispatch(ForemanServer.Commands.ArchiveProject, to: ForemanServer.AC1ProjectAggregate)

  # AC1 Task aggregate
  identify(ForemanServer.AC1TaskAggregate, by: :task_id)
  dispatch(ForemanServer.Commands.CreateTask, to: ForemanServer.AC1TaskAggregate)
  dispatch(ForemanServer.Commands.CloseTask, to: ForemanServer.AC1TaskAggregate)

  # AC1 Worker aggregate
  identify(ForemanServer.AC1WorkerAggregate, by: :worker_id)
  dispatch(ForemanServer.Commands.StartWorker, to: ForemanServer.AC1WorkerAggregate)
  dispatch(ForemanServer.Commands.ExitWorker, to: ForemanServer.AC1WorkerAggregate)

  # AC1 Phase aggregate
  identify(ForemanServer.AC1PhaseAggregate, by: :phase_id)
  dispatch(ForemanServer.Commands.StartPhase, to: ForemanServer.AC1PhaseAggregate)
  dispatch(ForemanServer.Commands.CompletePhase, to: ForemanServer.AC1PhaseAggregate)
end
