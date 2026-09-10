defmodule ForemanServer.AgentRuntime.JidoHarness.ModelCatalogTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.JidoHarness.ModelCatalog

  # A fake `pi` executable on PATH so this test is deterministic and does not
  # depend on a real pi install, network access, or the live upstream
  # catalog's contents. Mirrors the "write a fake CLI binary to PATH"
  # convention already used in
  # test/foreman_server/agent_runtime/jido_harness_test.exs.
  defp fake_pi_script do
    """
    #!/bin/sh
    if [ "$1" = "--list-models" ]; then
      case "$2" in
        minimax/MiniMax-M2.7)
          echo "provider    model                context  max-out  thinking  images"
          echo "minimax     MiniMax-M2.7         204.8K   131.1K   yes       no"
          exit 0
          ;;
        timeout-me)
          sleep 10
          exit 0
          ;;
        broken)
          echo "boom" 1>&2
          exit 1
          ;;
        *)
          echo "No models matching \\"$2\\""
          exit 0
          ;;
      esac
    fi
    exit 0
    """
  end

  setup do
    original_path = System.get_env("PATH")

    bin_dir =
      Path.join(System.tmp_dir!(), "model-catalog-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(bin_dir)
    File.write!(Path.join(bin_dir, "pi"), fake_pi_script())
    File.chmod!(Path.join(bin_dir, "pi"), 0o755)
    System.put_env("PATH", bin_dir <> ":" <> (original_path || ""))

    on_exit(fn ->
      case original_path do
        nil -> System.delete_env("PATH")
        path -> System.put_env("PATH", path)
      end

      File.rm_rf!(bin_dir)
    end)

    :ok
  end

  describe "check/2" do
    test "returns :unchecked for claude regardless of model" do
      assert ModelCatalog.check(:claude, "opus") == :unchecked
    end

    test "returns :unchecked when no model is declared" do
      assert ModelCatalog.check(:pi, nil) == :unchecked
    end

    test "returns :ok when the fake pi catalog reports a matching qualified model" do
      assert ModelCatalog.check(:pi, "minimax/MiniMax-M2.7") == :ok
    end

    test "returns {:error, {:model_not_found, _}} when the fake pi catalog reports no match" do
      assert {:error, {:model_not_found, "nonexistent-model"}} =
               ModelCatalog.check(:pi, "nonexistent-model")
    end

    test "returns {:error, {:catalog_query_failed, _}} on a non-zero exit" do
      assert {:error, {:catalog_query_failed, "boom"}} = ModelCatalog.check(:pi, "broken")
    end
  end
end
