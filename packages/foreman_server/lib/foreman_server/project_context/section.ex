defmodule ForemanServer.ProjectContext.Section do
  @moduledoc """
  One titled block of standing project context.

  `hint` tells the agent how to fetch the full content when the body is cut
  to fit its budget (rendered inside the truncation marker). `trailer` is text
  that always follows the body and any truncation marker (e.g. a closing tag),
  so a cut body can never leave a delimited block open.
  """

  @type id :: :instructions | :repositories | :memory | :library | atom()

  @type t :: %__MODULE__{
          id: id(),
          title: String.t(),
          body: String.t(),
          source_bytes: non_neg_integer(),
          hint: String.t(),
          trailer: String.t()
        }

  @enforce_keys [:id, :title, :body]
  defstruct [
    :id,
    :title,
    :body,
    source_bytes: 0,
    hint: "ask the operator for the full text",
    trailer: ""
  ]

  @doc "Builds a section; `source_bytes` is the body size before any cap."
  @spec new(id(), String.t(), String.t(), keyword()) :: t()
  def new(id, title, body, opts \\ []) when is_binary(title) and is_binary(body) do
    %__MODULE__{
      id: id,
      title: title,
      body: body,
      source_bytes: byte_size(body),
      hint: Keyword.get(opts, :hint, "ask the operator for the full text"),
      trailer: Keyword.get(opts, :trailer, "")
    }
  end
end
