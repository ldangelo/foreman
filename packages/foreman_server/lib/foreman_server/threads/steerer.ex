defmodule ForemanServer.Threads.Steerer do
  @moduledoc """
  Steering capability of a thread's agent provider.

  Decision (spike S2, E6-S5): live mid-turn steering is **NO-GO for every
  provider**, so the only steering mode is `"pause_resume"` (v1): pause the
  work, then resume with the operator message as the next prompt
  (`ForemanServer.Jobsite.steer/3` for the jobsite door, `run.steer` for the
  workflow door).

    * `pi` - `Jido.Harness.Session.steer` exists for pi only, and is blocked by
      upstream pi-transport defects documented in S2.
    * `claude` - has no live steering operation at all.

  Because nothing is live, no `Session` steer/interrupt code exists in Foreman.
  If a provider is ever promoted to `"live"`, add it to `capability/1` and
  introduce the live path with its own pause/resume fallback; do not return
  `"live"` without one.
  """

  @type capability :: String.t()

  @doc "Steering mode for a provider: always `\"pause_resume\"` today."
  @spec capability(atom() | String.t() | nil) :: capability()
  def capability(_provider), do: "pause_resume"
end
