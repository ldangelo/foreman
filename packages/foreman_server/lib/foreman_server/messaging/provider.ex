defmodule ForemanServer.Messaging.Provider do
  @moduledoc "Outbound chat provider behaviour."
  alias ForemanServer.Messaging.{DeliveryResult, Notification}

  @callback send(Notification.t(), map()) ::
              {:ok, DeliveryResult.t()} | {:error, DeliveryResult.t()}
end
