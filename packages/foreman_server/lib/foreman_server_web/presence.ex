defmodule ForemanServerWeb.Presence do
  @moduledoc """
  Phoenix Presence tracker for live aggregate actors. Each loaded aggregate
  registers its pid under the `"debug:aggregates"` topic with metadata
  describing its current state. LiveView debug pages subscribe to presence
  diffs to update their snapshots in real time.
  """

  use Phoenix.Presence,
    otp_app: :foreman_server,
    pubsub_server: ForemanServer.PubSub
end