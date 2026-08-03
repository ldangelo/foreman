defmodule ForemanServer.PrGate do
  @moduledoc """
  TRD-017: PR gate that controls whether a run can transition to
  merge-pending state.

  The gate inspects the PR association recorded for a run and returns
  `:ok` only when the PR status is one of `:open` or `:merged`. Any
  other status (`:closed`, `:conflicted`, unknown) returns
  `{:error, :pr_not_acceptable}`.

  ## Example

      iex> PrGate.evaluate(:open)
      :ok

      iex> PrGate.evaluate(:closed)
      {:error, :pr_not_acceptable}
  """

  alias ForemanServer.PrAssociate

  @acceptable_states [:open, :merged]

  @doc """
  Pure helper — given a PR status atom, return whether the gate is open.
  """
  @spec evaluate(atom()) :: :ok | {:error, :pr_not_acceptable}
  def evaluate(status) when status in @acceptable_states, do: :ok
  def evaluate(_), do: {:error, :pr_not_acceptable}

  @doc """
  Check the PR state for a run.

  Returns one of:

    * `:ok` — PR is in an acceptable state.
    * `{:error, :pr_not_acceptable}` — PR is in a blocking state.
    * `{:error, :no_pr_association}` — no PR association exists for the run.
    * `{:error, _}` — projection/lookup error.
  """
  @spec check(String.t()) ::
          :ok | {:error, :pr_not_acceptable | :no_pr_association | term()}
  def check(run_id) when is_binary(run_id) do
    case PrAssociate.lookup(run_id) do
      {:error, :not_found} ->
        {:error, :no_pr_association}

      {:error, other} ->
        {:error, other}

      {:ok, %{} = assoc} ->
        evaluate(Map.get(assoc, :pr_status) || :open)
    end
  end

  def check(_), do: {:error, :no_pr_association}

  @doc """
  Convenience: returns `true` when the PR gate is open for `run_id`.
  """
  @spec open?(String.t()) :: boolean()
  def open?(run_id), do: check(run_id) == :ok
end
