defmodule ForemanServer.Identity do
  @moduledoc """
  Deterministic identity helpers for tasks, runs, phases, and system command IDs.

  Run IDs, phase IDs, and command IDs must be reproducible from the inputs that
  define them so that retries and actor-level deduplication collapse to a single
  domain event. This module owns those derivations and exposes a single SHA-256
  helper used by `CommandGateway` and the workflow dispatcher.

  The string format is exact: the algorithm and digest encoding are part of the
  contract with the actor/event store, and changing either will invalidate the
  event ID derivation.
  """

  @doc """
  Deterministic run identifier.

  Derives from `task_id` and `approval_id` to guarantee that reapproving the
  same task with the same approval ID always produces the same run, even after
  the projection has been rebuilt.

      iex> ForemanServer.Identity.run_id("t1", "ap-1")
      "run-" <> hex = ...
  """
  @spec run_id(String.t(), String.t()) :: String.t()
  def run_id(task_id, approval_id)
      when is_binary(task_id) and task_id != "" and
             is_binary(approval_id) and approval_id != "" do
    "run-" <> first_32_lowercase_hex(sha256(task_id <> "\0" <> approval_id))
  end

  @doc """
  Deterministic phase identifier for the given run.

      iex> ForemanServer.Identity.phase_id("run-abc", 1)
      "run-abc-p001"
  """
  @spec phase_id(String.t(), pos_integer()) :: String.t()
  def phase_id(run_id, index)
      when is_binary(run_id) and run_id != "" and is_integer(index) and index >= 1 do
    run_id <> "-p" <> String.pad_leading(Integer.to_string(index), 3, "0")
  end

  @doc """
  System command ID for a dispatcher claim against `task_id` and `approval_id`.

      iex> ForemanServer.Identity.dispatch_command_id("t1", "ap-1")
      "workflow:t1:ap-1:claim"
  """
  @spec dispatch_command_id(String.t(), String.t()) :: String.t()
  def dispatch_command_id(task_id, approval_id)
      when is_binary(task_id) and task_id != "" and
             is_binary(approval_id) and approval_id != "" do
    "workflow:" <> task_id <> ":" <> approval_id <> ":claim"
  end

  @doc """
  System command ID for starting a run.

      iex> ForemanServer.Identity.run_start_command_id("run-abc")
      "workflow:run-abc:start"
  """
  @spec run_start_command_id(String.t()) :: String.t()
  def run_start_command_id(run_id) when is_binary(run_id) and run_id != "" do
    "workflow:" <> run_id <> ":start"
  end

  @doc """
  System command ID for starting a phase.

      iex> ForemanServer.Identity.phase_start_command_id("run-abc", 1)
      "workflow:run-abc:phase:1:start"
  """
  @spec phase_start_command_id(String.t(), pos_integer()) :: String.t()
  def phase_start_command_id(run_id, index)
      when is_binary(run_id) and run_id != "" and is_integer(index) and index >= 1 do
    "workflow:" <> run_id <> ":phase:" <> Integer.to_string(index) <> ":start"
  end

  @doc """
  System command ID for completing a phase.

      iex> ForemanServer.Identity.phase_complete_command_id("run-abc", 1)
      "workflow:run-abc:phase:1:complete"
  """
  @spec phase_complete_command_id(String.t(), pos_integer()) :: String.t()
  def phase_complete_command_id(run_id, index)
      when is_binary(run_id) and run_id != "" and is_integer(index) and index >= 1 do
    "workflow:" <> run_id <> ":phase:" <> Integer.to_string(index) <> ":complete"
  end

  @doc """
  System command ID for failing a phase.

      iex> ForemanServer.Identity.phase_fail_command_id("run-abc", 1)
      "workflow:run-abc:phase:1:fail"
  """
  @spec phase_fail_command_id(String.t(), pos_integer()) :: String.t()
  def phase_fail_command_id(run_id, index)
      when is_binary(run_id) and run_id != "" and is_integer(index) and index >= 1 do
    "workflow:" <> run_id <> ":phase:" <> Integer.to_string(index) <> ":fail"
  end

  @doc """
  System command ID for completing a run.
  """
  @spec run_complete_command_id(String.t()) :: String.t()
  def run_complete_command_id(run_id) when is_binary(run_id) and run_id != "" do
    "workflow:" <> run_id <> ":complete"
  end

  @doc """
  System command ID for failing a run.
  """
  @spec run_fail_command_id(String.t()) :: String.t()
  def run_fail_command_id(run_id) when is_binary(run_id) and run_id != "" do
    "workflow:" <> run_id <> ":fail"
  end

  @doc """
  System command ID for the terminal `task.execution_complete` command.
  """
  @spec task_complete_command_id(String.t()) :: String.t()
  def task_complete_command_id(run_id) when is_binary(run_id) and run_id != "" do
    "workflow:" <> run_id <> ":task:complete"
  end

  @doc """
  System command ID for the terminal `task.execution_fail` command.
  """
  @spec task_fail_command_id(String.t()) :: String.t()
  def task_fail_command_id(run_id) when is_binary(run_id) and run_id != "" do
    "workflow:" <> run_id <> ":task:fail"
  end

  @doc """
  Stable lowercase SHA-256 hex digest.

  Always lowercase, always 64 hex characters, no padding.
  """
  @spec sha256(String.t()) :: String.t()
  def sha256(input) when is_binary(input) do
    :crypto.hash(:sha256, input)
    |> Base.encode16(case: :lower)
  end

  @doc """
  First 32 lowercase hex characters (16 bytes) of a SHA-256 digest.

  Used by `run_id/2`.
  """
  @spec first_32_lowercase_hex(String.t()) :: String.t()
  def first_32_lowercase_hex(hex) when is_binary(hex) and byte_size(hex) >= 32 do
    binary_part(hex, 0, 32)
  end
end