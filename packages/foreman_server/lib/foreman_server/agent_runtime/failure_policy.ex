defmodule ForemanServer.AgentRuntime.FailurePolicy do
  @moduledoc """
  Resolves failure handling policy for agent runtime invocations.

  TRD-007 §Failure Policy and Attempt Semantics defines the contract.
  The resolved policy is a map with four keys: `:fail_fast`, `:fallback`,
  `:max_attempts`, and `:timeout_ms`.

  ## Precedence (high → low)

    1. Per-call `opts` (keyword list or map) — only present keys override.
    2. Per-task-type config under `:foreman_server, :agent_runtime, :failure_policies`.
    3. Built-in defaults (TRD line 187):

           %{fail_fast: true, fallback: false, max_attempts: 1, timeout_ms: 60_000}

  ## Special rule (TRD-007 AC 3)

  If the effective `:fallback` is `true` at the resolved level and no
  layer supplies `:max_attempts`, then `:max_attempts` is `2`.

  ## `fail_fast`

  `:fail_fast` is always `true` in the returned map. Operators cannot
  override it; it is included so the resolved shape matches the TRD
  default verbatim.
  """

  # Built-in defaults from TRD line 187.
  @default_fail_fast true
  @default_fallback false
  @default_max_attempts 1
  @default_timeout_ms 60_000

  @type task_type :: atom() | nil
  @type opts :: keyword() | map()

  @typedoc """
  The resolved policy map. Always contains exactly four keys:
  `:fail_fast`, `:fallback`, `:max_attempts`, `:timeout_ms`.
  """
  @type t :: %{
          fail_fast: true,
          fallback: boolean(),
          max_attempts: pos_integer(),
          timeout_ms: pos_integer()
        }

  @doc """
  Resolves the failure policy for a given task type and call options.

  See the moduledoc for precedence and special rules.

  ## Examples

      iex> ForemanServer.AgentRuntime.FailurePolicy.resolve(:code_generation, [])
      %{fail_fast: true, fallback: false, max_attempts: 1, timeout_ms: 60_000}
  """
  @spec resolve(task_type(), opts()) :: t()
  def resolve(task_type, opts) when is_list(opts) do
    resolve(task_type, Map.new(opts))
  end

  def resolve(task_type, opts) when is_map(opts) do
    rt_config = Application.get_env(:foreman_server, :agent_runtime, [])

    default_timeout_ms =
      Keyword.get(rt_config, :default_timeout_ms, @default_timeout_ms)

    task_policies = Keyword.get(rt_config, :failure_policies, %{})

    task_config =
      if task_type != nil do
        Map.get(task_policies, task_type, %{})
      else
        %{}
      end

    fallback =
      Map.get(opts, :fallback, Map.get(task_config, :fallback, @default_fallback))

    timeout_ms =
      Map.get(opts, :timeout_ms, Map.get(task_config, :timeout_ms, default_timeout_ms))

    max_attempts =
      cond do
        Map.has_key?(opts, :max_attempts) -> Map.fetch!(opts, :max_attempts)
        Map.has_key?(task_config, :max_attempts) -> Map.fetch!(task_config, :max_attempts)
        fallback == true -> 2
        true -> @default_max_attempts
      end

    %{
      fail_fast: @default_fail_fast,
      fallback: fallback,
      max_attempts: max_attempts,
      timeout_ms: timeout_ms
    }
  end
end
