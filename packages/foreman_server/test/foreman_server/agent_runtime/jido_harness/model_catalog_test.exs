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

  # Synthetic `pi --list-models` tables for the matcher matrix below. These are
  # FIXED, not the live catalog: the point of the matrix is that a match is
  # decided by provider+model column pairing, which the live catalog cannot
  # demonstrate (no model id currently exists under two providers, and the
  # upstream row set changes without notice). Row shape is copied verbatim from
  # real `pi --list-models MiniMax` output on the host: a
  # `provider  model  context  max-out  thinking  images` header, then one row
  # per model.
  @header "provider    model                context  max-out  thinking  images"

  # Column widths copied from real `pi --list-models` output, so the matcher
  # sees the same field count in test that it sees in production.
  # Module attributes, not private functions: `@catalog` is evaluated while the
  # module body runs, before any `defp` in this module exists.
  @pi_row_fn &(:io_lib.format("~-12s ~-20s 204.8K   131.1K   yes       no", [&1, &2])
               |> IO.iodata_to_binary())
  @pi_row_minimax @pi_row_fn.("minimax", "MiniMax-M2.7")

  @catalog Enum.join(
             [
               @header,
               @pi_row_minimax,
               @pi_row_fn.("minimax", "MiniMax-M3"),
               @pi_row_fn.("anthropic", "sonnet"),
               @pi_row_fn.("anthropic", "shared"),
               @pi_row_fn.("openrouter", "shared")
             ],
             "\n"
           )

  # One fake `pi` per script body, so each matrix case gets a deterministic
  # catalog regardless of the search term it is asked about.
  defp with_pi(script, fun) do
    original_path = System.get_env("PATH")

    bin_dir =
      Path.join(System.tmp_dir!(), "model-catalog-matrix-#{System.unique_integer([:positive])}")

    File.mkdir_p!(bin_dir)
    File.write!(Path.join(bin_dir, "pi"), script)
    File.chmod!(Path.join(bin_dir, "pi"), 0o755)
    System.put_env("PATH", bin_dir <> ":" <> (original_path || ""))

    try do
      fun.()
    after
      case original_path do
        nil -> System.delete_env("PATH")
        path -> System.put_env("PATH", path)
      end

      File.rm_rf!(bin_dir)
    end
  end

  # The body carries real newlines, so the script writes it through `cat` with a
  # here-document rather than a printf format string.
  defp always_pi(body) do
    "#!/bin/sh\ncat <<'CATALOG_EOF'\n" <> body <> "\nCATALOG_EOF\nexit 0\n"
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

    @tag timeout: 10_000
    test "returns {:error, {:catalog_query_failed, :timeout}} when the catalog query hangs" do
      assert {:error, {:catalog_query_failed, :timeout}} = ModelCatalog.check(:pi, "timeout-me")
    end
  end

  describe "check/2 matcher matrix (TRD-001)" do
    # `MiniMax-M2.7` exists under the `minimax` provider only; `sonnet` under
    # `anthropic` only; `shared` under BOTH. Every searched value below is
    # something the fake `pi` would happily return rows for — the substring
    # filter is not what is under test, the pairing is.
    tests = [
      {"qualified hit on provider and model", "minimax/MiniMax-M2.7", :ok},
      {"qualified miss: model exists under a DIFFERENT provider", "anthropic/MiniMax-M2.7",
       {:error, {:model_not_found, "anthropic/MiniMax-M2.7"}}},
      {"qualified miss: provider exists, model does not", "minimax/sonnet",
       {:error, {:model_not_found, "minimax/sonnet"}}},
      {"qualified hit is not satisfied by a bare vendor prefix", "minimax/MiniMax",
       {:error, {:model_not_found, "minimax/MiniMax"}}},
      {"unqualified hit on the model column alone", "MiniMax-M2.7", :ok},
      {"unqualified value matching the same model id under two providers", "shared", :ok},
      {"miss on a value the query filters down to nothing", "no-such-model",
       {:error, {:model_not_found, "no-such-model"}}},
      {"value whose halves are compared case-exactly", "MiniMax/miniMax-m2.7",
       {:error, {:model_not_found, "MiniMax/miniMax-m2.7"}}}
    ]

    for {label, searched, expected} <- tests do
      test label <> " (TRD-001)" do
        # The fake ignores the search term and prints the whole table, so the
        # row set is constant and only the matcher decides — `pi` itself is a
        # substring filter, and a pass driven by an empty row set would prove
        # nothing about pairing.
        with_pi(always_pi(@catalog), fn ->
          assert ModelCatalog.check(:pi, unquote(searched)) == unquote(Macro.escape(expected))
        end)
      end
    end

    test "header-only table answers \"not present\", not \"could not answer\" (TRD-001)" do
      # A complete, readable query that returned no rows is an existence
      # answer. The `catalog_query_failed` distinction for a query that could
      # not be answered at all is covered by the "broken" and "timeout-me"
      # cases above; this row pins the other half of that split (§5.3).
      with_pi(always_pi(@header), fn ->
        assert {:error, {:model_not_found, "anything"}} = ModelCatalog.check(:pi, "anything")
      end)
    end

    test "empty output is a miss, not a crash (TRD-001)" do
      with_pi(always_pi(""), fn ->
        assert {:error, {:model_not_found, "minimax/MiniMax-M2.7"}} =
                 ModelCatalog.check(:pi, "minimax/MiniMax-M2.7")
      end)
    end

    test "a row too short to have two columns is skipped, not matched (TRD-001)" do
      noisy = @header <> "\n" <> @pi_row_minimax <> "\ntruncated-row"

      with_pi(always_pi(noisy), fn ->
        assert ModelCatalog.check(:pi, "minimax/MiniMax-M2.7") == :ok
      end)
    end
  end
end
