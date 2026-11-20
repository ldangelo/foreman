defmodule ForemanServer.TaskProviders.KataRunner do
  @moduledoc """
  Behaviour contract for the `kata` subprocess boundary.

  `KataAdapter` dispatches every Kata call through the module bound to this
  behaviour. Production binds `ForemanServer.TaskProviders.SystemKataRunner`;
  tests bind `ForemanServer.TaskProviders.KataRunnerMock`.

    * `argv` — the arguments after the `kata` binary, one list element per
      argument (never a pre-joined command line).
    * `cwd` — the project working directory the command runs in. Kata resolves
      its project from the `.kata.toml` binding at or above this directory.
    * `opts` — call-scoped runner options (for example `:timeout_ms`).

  On exit status 0 the runner returns the command's stdout. Every failure is a
  typed `ProviderError`; the runner never returns a raw string or map as an
  error.
  """

  alias ForemanServer.TaskProviders.ProviderError

  @callback cmd(argv :: [String.t()], cwd :: Path.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, ProviderError.t()}
end
