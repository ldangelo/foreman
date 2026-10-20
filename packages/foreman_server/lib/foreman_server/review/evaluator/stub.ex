defmodule ForemanServer.Review.Evaluator.Stub do
  @moduledoc """
  Test evaluator. Returns whatever `:review_stub_verdict` holds: a
  `%Verdict{}` (returned as `{:ok, verdict}`) or `{:error, %Error{}}`;
  unset yields a `:met` verdict with no gaps.
  """
  @behaviour ForemanServer.Review.Evaluator

  alias ForemanServer.Review.{Error, Subject, Verdict}

  @impl true
  @spec evaluate(Subject.t()) :: {:ok, Verdict.t()} | {:error, Error.t()}
  def evaluate(%Subject{}) do
    case Application.get_env(:foreman_server, :review_stub_verdict) do
      nil ->
        {:ok,
         %Verdict{
           verdict: :met,
           summary: "stub verdict",
           scores: %{correctness: 5, tests: 5, documentation: 5, robustness: 5},
           gaps: []
         }}

      %Verdict{} = verdict ->
        {:ok, verdict}

      {:error, %Error{}} = error ->
        error
    end
  end
end
