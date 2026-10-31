defmodule ForemanServerWeb.LogFilterTest do
  @moduledoc """
  foreman-mw5rz: Phoenix logs request parameters at `:debug`, and its
  `:filter_parameters` list is what keeps free text and credentials out of that line.
  `Phoenix.Logger.filter_values/1` is the single function the router dispatch logger and
  `Phoenix.LiveView.Logger` (`HANDLE EVENT`) both call, so these tests pin the contract
  for every free-text key the server accepts, plus the MCP `tools/call` envelope.

  The list is a set of key names (substring match): a free-text key added later is NOT
  covered until it is added to `config :phoenix, :filter_parameters`. The fail-closed
  follow-up is foreman-25sqf.1.1 (value-based log filter).
  """
  use ExUnit.Case, async: true

  @canary "LOGCANARY-0f3a9c"

  # One entry per surface that carries free text or a credential.
  @free_text_keys ~w(text content description prompt message instructions goal body params
                     token password value)

  for key <- @free_text_keys do
    test "the #{key} param is filtered" do
      assert Phoenix.Logger.filter_values(%{unquote(key) => @canary}) ==
               %{unquote(key) => "[FILTERED]"}
    end
  end

  test "an MCP tools/call body is filtered whatever the tool's argument is named" do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{
        "name" => "foreman_project_memory_write",
        "arguments" => %{"project_id" => "p1", "brand_new_argument" => @canary}
      }
    }

    filtered = Phoenix.Logger.filter_values(body)

    refute inspect(filtered) =~ @canary
    # The method stays visible: the line is still useful for diagnosis.
    assert filtered["method"] == "tools/call"
  end

  test "ids and names that identify a request stay visible" do
    params = %{"id" => "p1", "project_id" => "proj-1", "workflow" => "fix", "run_id" => "r-9"}

    assert Phoenix.Logger.filter_values(params) == params
  end
end
