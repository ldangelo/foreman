defmodule ForemanServerWeb.Presence do
  @moduledoc false

  use Phoenix.Presence,
    otp_app: :foreman_server,
    pubsub_server: ForemanServer.PubSub
end
