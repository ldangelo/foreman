defmodule ForemanServer.TestSupport.TestApplication do
  @moduledoc """
  No longer used — `ForemanServer.Application` is started once by ExUnit's
  `application` env and shared across all tests. Each test uses unique stream IDs.
  """
end
