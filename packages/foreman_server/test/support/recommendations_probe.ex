defmodule ForemanServer.TestSupport.RecommendationsProbe do
  @moduledoc """
  A `Recommendations.Facts.Probe` for tests that must not run `gh`, `br` or the
  provider and workflow checks.

  Files are read for real (the test's own tmp repo); executables are never found
  (`gh` is `:missing`, `br` absent); `call/2` answers `{:error, :failed}`, so the
  workflow catalog, provider rows and memory facts are `:unavailable` and produce no
  recommendation. `install!/0` points `config :foreman_server, :recommendations` at it
  for the current test (restored on exit), which is the seam
  `Recommendations.recommend_bounded/1` reads.
  """

  @behaviour ForemanServer.Projects.Recommendations.Facts.Probe

  alias ForemanServer.Projects.Recommendations.Facts.Probe
  alias ForemanServer.TestSupport.Eventually

  defdelegate exists?(path), to: Probe.System
  defdelegate glob(pattern), to: Probe.System
  defdelegate read_head(path, max_bytes), to: Probe.System

  def find_executable(_name), do: nil
  def cmd(_executable, _args, _timeout_ms), do: {:error, :failed}
  def call(_fun, _timeout_ms), do: {:error, :failed}

  @doc "Use this probe for the rest of the current test."
  @spec install!() :: :ok
  def install! do
    Eventually.put_env_for_test(:foreman_server, :recommendations,
      probe: __MODULE__,
      probe_timeout_ms: 500
    )
  end
end
