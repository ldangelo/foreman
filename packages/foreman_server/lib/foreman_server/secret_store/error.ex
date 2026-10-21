defmodule ForemanServer.SecretStore.Error do
  @moduledoc """
  Typed error for every `ForemanServer.SecretStore` failure. Never carries a
  secret value: `details` holds names, ids and OS error atoms only.

  `code` vocabulary: `:invalid_project_id`, `:invalid_secret_name`,
  `:invalid_secret_value`, `:secret_not_found`, `:store_unavailable`,
  `:store_malformed`.
  """
  @enforce_keys [:code, :message]
  @type t :: %__MODULE__{code: atom(), message: String.t(), details: map()}
  defstruct [:code, :message, details: %{}]

  @spec new(atom(), String.t(), map()) :: t()
  def new(code, message, details \\ %{})
      when is_atom(code) and is_binary(message) and is_map(details) do
    %__MODULE__{code: code, message: message, details: details}
  end
end
