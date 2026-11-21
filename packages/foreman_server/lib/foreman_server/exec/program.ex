defmodule ForemanServer.Exec.Program do
  @moduledoc """
  An ordered list of `ForemanServer.Exec.Step` for
  `ForemanServer.Exec.Engine.run_program/3` to execute. Built either by
  `ForemanServer.Exec.Executor` (from `Jobsite.run/1` options) or by
  `ForemanServer.Workflow.Lowering` (from a parsed workflow manifest) — both
  front-ends compile to this one shape so the engine never knows which
  produced it.
  """

  alias ForemanServer.Exec.Step

  @enforce_keys [:steps]
  @type t :: %__MODULE__{steps: [Step.t()], name: String.t() | nil, context: map()}
  defstruct [:steps, name: nil, context: %{}]
end
