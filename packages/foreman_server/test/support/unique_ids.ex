defmodule ForemanServer.TestSupport.UniqueIds do
  @moduledoc """
  Ids for runs a test projects into the process-wide `ForemanServer.ProjectionStore`.

  The store outlives every test, and a non-terminal run left in it (a `RunStarted`, or the
  `awaiting_worker` stub any run-keyed event mints) is read back by id from every later test:
  `Dispatcher.crash_resume_opts/2` starts a live run with `resume_from`, `PrWatcher`, `Overview`
  and `Messaging` read it too. A hand-written id such as `"run-1"` is therefore shared with every
  other test that types the same literal; a run id from `unique_run_id/1` is not
  (foreman-b8qjy, foreman-fhe9o). `ForemanServer.TestSupport.ProjectionLeakGuard` fails the
  suite when a fixed id is left behind.
  """

  @doc "A run id no other test can hold: `run-<label>-<n>`, `n` unique within this VM."
  @spec unique_run_id(String.t()) :: String.t()
  def unique_run_id(label) when is_binary(label) and label != "" do
    "run-#{label}-#{System.unique_integer([:positive])}"
  end
end
