defmodule ForemanServer.Review.Evaluator do
  @moduledoc """
  Behaviour for the reviewer that grades an archived session against its
  original request. The implementation is chosen by
  `config :foreman_server, :review, evaluator:`.
  """

  alias ForemanServer.Review.{Error, Subject, Verdict}

  @callback evaluate(Subject.t()) :: {:ok, Verdict.t()} | {:error, Error.t()}
end
