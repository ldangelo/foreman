# Wrapper to adapt Commanded's start_link/1 to OTP's start/2 callback.
# OTP calls MyApp.start(:normal, []) — Commanded expects start_link([]).
defmodule ForemanServer.AppStart do
  def start(_type, args) do
    ForemanServer.Application.start_link(args)
  end
end
