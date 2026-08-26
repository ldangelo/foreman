defmodule ForemanServer.Agents.JidoVfsSandboxTest do
  @moduledoc """
  LGC-T003 — Verify sandbox enforcement (network deny-by-default, command
  allowlisting) for the host-path worktree adapter.

  Per TRD-2026-4212be7e / LGC-T003, the migration falls back to
  `jido_shell + jido_vfs + custom host-path adapter` (TRD-037 decision).
  The shell sandbox is the gate that enforces network policy at the
  command execution layer (NetworkPolicy.enforce/2), so the LGC-T003
  contract lives there.
  """
  use ExUnit.Case, async: true

  alias Jido.Shell.Sandbox.NetworkPolicy

  describe "network deny-by-default (LGC-T003)" do
    test "outbound network commands are blocked by default" do
      assert {:error, %Jido.Shell.Error{code: {:shell, :network_blocked}}} =
               NetworkPolicy.enforce("curl https://example.com", %{})
    end

    test "wget is also blocked by default" do
      assert {:error, %Jido.Shell.Error{code: {:shell, :network_blocked}}} =
               NetworkPolicy.enforce("wget https://example.com", %{})
    end

    test "non-network commands pass through the policy untouched" do
      assert :ok = NetworkPolicy.enforce("ls -la", %{})
      assert :ok = NetworkPolicy.enforce("git status", %{})
    end
  end

  describe "command allowlist / network allowlist (LGC-T003)" do
    test "allowlisted domain is permitted" do
      assert :ok =
               NetworkPolicy.enforce(
                 "curl https://example.com",
                 %{network: %{allow_domains: ["example.com"]}}
               )
    end

    test "non-allowlisted domain is still blocked when allowlist is set" do
      assert {:error, %Jido.Shell.Error{code: {:shell, :network_blocked}}} =
               NetworkPolicy.enforce(
                 "curl https://bad.example.com",
                 %{network: %{allow_domains: ["example.com"]}}
               )
    end

    test "blocklist wins over allowlist" do
      context = %{
        network: %{
          allow_domains: ["example.com"],
          block_domains: ["example.com"]
        }
      }

      assert {:error, %Jido.Shell.Error{code: {:shell, :network_blocked}}} =
               NetworkPolicy.enforce("curl https://example.com", context)
    end
  end
end
