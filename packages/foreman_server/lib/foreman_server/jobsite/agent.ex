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
  defstruct [
    :provider,
    :model,
    :effort,
    env: %{},
    provider_options: %{},
    binary: nil,
    approval_mode: nil
  ]

  # Ordered: error messages list the modes in this order.
  @approval_mode_list [
    {"default", :default},
    {"prompt", :prompt},
    {"auto_edit", :auto_edit},
    {"auto_approve", :auto_approve}
  ]
  @approval_modes Map.new(@approval_mode_list)

  @doc """
  The one table of harness approval modes, string name to atom. Every boundary
  that accepts a mode by name (workflow phases, the remote spec, persisted
  jobsite state) resolves it here, so no atom is minted from caller input and
  the sets cannot drift apart.
  """
  @spec approval_modes() :: %{String.t() => atom()}
  def approval_modes, do: @approval_modes

  @doc "Mode names in documentation order."
  @spec approval_mode_names() :: [String.t()]
  def approval_mode_names, do: Enum.map(@approval_mode_list, &elem(&1, 0))

  @doc "Resolve a mode name to its atom, or `:error` for an unknown name."
  @spec parse_approval_mode(String.t()) :: {:ok, atom()} | :error
  def parse_approval_mode(name) when is_binary(name), do: Map.fetch(@approval_modes, name)
end
