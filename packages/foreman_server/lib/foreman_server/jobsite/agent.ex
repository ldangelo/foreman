defmodule ForemanServer.Jobsite.Agent do
  @moduledoc """
An agent provider/model selection for a jobsite iteration.

`approval_mode` is the harness's tool-approval mode for the run. `nil` leaves
the harness default, which for Claude is its interactive permission mode — an
unattended run then cannot write files or run commands (it reports that it is
waiting for approval and exits "successfully"). Set `:auto_edit` to allow file
edits, or `:auto_approve` to bypass permission prompts, ideally only inside a
container sandbox.
"""

  @enforce_keys [:provider]
  @type t :: %__MODULE__{
          provider: atom(),
          model: String.t() | nil,
          effort: atom() | nil,
          env: map(),
          provider_options: map(),
          binary: String.t() | nil,
          approval_mode: :default | :prompt | :auto_edit | :auto_approve | nil
        }
  defstruct [:provider, :model, :effort, env: %{}, provider_options: %{}, binary: nil, approval_mode: nil]
end
