defmodule ForemanServer.CLI do
  @moduledoc false

  alias ForemanServer.CLI.DoctorTaskProvider

  @type run_result :: :ok | {:error, pos_integer(), String.t()}

  @spec run([String.t()]) :: run_result()
  def run(["doctor", "task_provider" | rest]), do: DoctorTaskProvider.run(rest)
  def run(_args), do: {:error, 64, "usage: foreman doctor task_provider"}
end
