defmodule ForemanServer.Workflow.ApproverAuthorizer do
  @moduledoc """
  Verifies approver GitHub identity matches the authorized identity list.
  TRD-2026-4212be7e / MGH-T002 / TRD-072.
  """
  @default_authorized ["github:ldangelo"]

  def authorized?(identity, allowed \\ @default_authorized), do: identity in allowed

  def authorize(identity, allowed \\ @default_authorized) do
    if authorized?(identity, allowed), do: :ok, else: {:error, :unauthorized_approver}
  end
end
