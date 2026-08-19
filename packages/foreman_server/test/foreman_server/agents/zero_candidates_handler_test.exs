defmodule ForemanServer.Agents.ZeroCandidatesHandlerTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Agents.ZeroCandidatesHandler

  test "format_error includes excluded filters" do
    err = ZeroCandidatesHandler.format_error([%{capability: "code", reason: "no provider"}])
    assert err.kind == :zero_candidates
    assert length(err.excluded_filters) == 1
  end
end
