defmodule ForemanServerWeb.CommandControllerTypesTest do
  use ExUnit.Case, async: true

  @moduletag :controller

  describe "@allowed_types parity" do
    test "CommandController.@allowed_types matches CommandGateway.@allowed_operator_types" do
      controller_types =
        ForemanServerWeb.CommandController.__info__(:attributes)
        |> Keyword.get_values(:allowed_types)
        |> List.first()

      gateway_types =
        ForemanServer.CommandGateway.__info__(:attributes)
        |> Keyword.get_values(:allowed_operator_types)
        |> List.first()

      assert controller_types == gateway_types
    end
  end
end
