defmodule ForemanServer.Messaging.HttpResponse do
  @moduledoc "Typed successful HTTP response returned by HttpClient.post_json/4."
  @enforce_keys [:status, :body]
  @type t :: %__MODULE__{status: non_neg_integer(), body: String.t()}
  defstruct [:status, :body]
end
