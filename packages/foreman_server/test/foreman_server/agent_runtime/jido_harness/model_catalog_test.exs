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
               @pi_row_fn.("openrouter", "shared"),
               # Live-catalog shape: `pi --list-models openrouter` really does
               # print rows whose MODEL column contains a slash (e.g.
               # `openrouter  minimax/minimax-m2.7`). The matcher splits the
               # SEARCHED value on its first slash only; it never splits the
               # row's columns, and composing them (the pre-PR form) matches
               # strings no row carries. See the two slash rows in the matrix.
               @pi_row_fn.("openrouter", "minimax/minimax-m2.7")
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
      # `"/MiniMax-M2.7"` splits on the FIRST slash into an EMPTY provider half,
      # so `split_qualified/1` classifies it as a bare model id and the leading
      # slash travels to the model-column comparison, where it cannot match.
      # Under the old whole-string matchers a slash made a value look qualified
      # and it was compared against the composed row, so this spelling used to
      # pass; it is pinned here as a deliberate behavior change, not a
      # regression.
      {"a leading slash is an empty provider, not a qualified value", "/MiniMax-M2.7",
       {:error, {:model_not_found, "/MiniMax-M2.7"}}},
      {"unqualified value matching the same model id under two providers", "shared", :ok},
      {"miss on a value the query filters down to nothing", "no-such-model",
       {:error, {:model_not_found, "no-such-model"}}},
      {"value whose halves are compared case-exactly", "MiniMax/miniMax-m2.7",
       {:error, {:model_not_found, "MiniMax/miniMax-m2.7"}}},
      # A qualified value whose MODEL half contains a slash is not a legal
      # `<provider>/<model-id>` spelling of the `openrouter` row it
      # superficially resembles: split on the FIRST slash pairs provider
      # `minimax` with model `minimax-m2.7`, and no row carries that pair.
      {"qualified value cannot re-partition a slashed model column", "minimax/minimax-m2.7",
       {:error, {:model_not_found, "minimax/minimax-m2.7"}}},
      # The exact spelling of that row, matched on both columns.
      {"qualified hit on a row whose model column contains a slash",
       "openrouter/minimax/minimax-m2.7", :ok}
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

    test "exit-0 output pi never prints fails closed (TRD-001)" do
      # §5.3: "I could not read the catalog" and "the model is not in it" are
      # different answers. `parse_result/2` classifies the whole line set and
      # refuses `:model_not_found` unless something identifiable as pi's
      # output was seen, so no garbage can be reported as a negative answer.
      # The `defp`s below are module-level: ExUnit forbids them inside
      # `describe`.
      with_pi(always_pi("Fatal: could not read models.json"), fn ->
        assert {:error, {:catalog_query_failed, :unrecognized_output}} =
                 ModelCatalog.check(:pi, "minimax/MiniMax-M2.7")
      end)
    end

    test "empty stdout is a query failure, not an existence answer (TRD-001)" do
      # `stderr_to_stdout: true` merges the streams, so the ONLY way stdout is
      # empty at this point is that pi printed nothing at all (e.g. it was
      # killed before producing output, or a wrapper swallowed it). Either
      # way the catalog never answered, and §5.3 forbids reporting that as
      # "model not found".
      with_pi("#!/bin/sh\nexit 0\n", fn ->
        assert {:error, {:catalog_query_failed, :empty_output}} =
                 ModelCatalog.check(:pi, "minimax/MiniMax-M2.7")
      end)
    end

    test "pi's negative banners answer \"not present\" (TRD-001)" do
      for banner <- ["No models matching \"minimax/MiniMax-M2.7\"", "No models available."] do
        with_pi(always_pi(banner), fn ->
          assert {:error, {:model_not_found, "minimax/MiniMax-M2.7"}} =
                   ModelCatalog.check(:pi, "minimax/MiniMax-M2.7")
        end)
      end
    end

    test "a host wrapper notice cannot mask pi's answer (TRD-001)" do
      # Observed in the wild: a `pi` wrapper prepends
      # "bili: attaching to running proxy ..." to stdout. Classification is
      # line-scanned, so the table underneath is still read.
      wrapper = "bili: attaching to running proxy http://127.0.0.1:4000\n" <> @catalog

      with_pi(always_pi(wrapper), fn ->
        assert ModelCatalog.check(:pi, "minimax/MiniMax-M2.7") == :ok
      end)

      # The banner must name the search pi was actually handed — `check/2`
      # passes `model` to the CLI, and `list-models.ts` echoes it back. A
      # banner naming a DIFFERENT search is not an answer to this one, so the
      # second case below is the one that pins that distinction.
      with_pi(
        always_pi(
          "bili: attaching to running proxy\nNo models matching \"minimax/MiniMax-M2.7\""
        ),
        fn ->
          assert {:error, {:model_not_found, "minimax/MiniMax-M2.7"}} =
                   ModelCatalog.check(:pi, "minimax/MiniMax-M2.7")
        end
      )

      # Same banner shape, foreign query: pi never answered THIS search, so the
      # output must not be read as "not present" (§5.3).
      with_pi(always_pi("bili: attaching to running proxy\nNo models matching \"x\""), fn ->
        assert {:error, {:catalog_query_failed, :unrecognized_output}} =
                 ModelCatalog.check(:pi, "minimax/MiniMax-M2.7")
      end)
    end

    # Superseded by the row-shape describe block below: a short row that NAMES
    # the searched model is now classified `{:catalog_query_failed,
    # {:malformed_row, _}}`, not `:model_not_found`. The case where the short
    # line is about some OTHER model is pinned by "a stray two-token line is
    # not a row" and by "an unrelated truncated row does not poison a clean
    # hit", which is what this test originally proved.
    test "a row with fewer than pi's six columns is skipped, not matched (TRD-001)" do
      short = @header <> "\nminimax  MiniMax-M2.7  128k  8k  no"

      with_pi(always_pi(short), fn ->
        assert {:error, {:catalog_query_failed, {:malformed_row, _}}} =
                 ModelCatalog.check(:pi, "minimax/MiniMax-M2.7")
      end)
    end

    test "a stray two-token line is not a row (TRD-001)" do
      notice = @header <> "\nsee docs\n" <> @pi_row_minimax

      with_pi(always_pi(notice), fn ->
        # The real row still matches the qualified search…
        assert ModelCatalog.check(:pi, "minimax/MiniMax-M2.7") == :ok

        # …and under the bare search `docs`, the NOTICE carries the searched
        # model id in its second token and fewer than pi's six columns. It is
        # not a row, but neither is its readability in question — the honest
        # answer is "I could not read this output", never "the catalog says
        # this model is absent" (§5.3): a false negative would fail a run over
        # a line of prose.
        assert {:error, {:catalog_query_failed, {:malformed_row, "see docs"}}} =
                 ModelCatalog.check(:pi, "docs")
      end)
    end

    test "a matching row ABOVE the header cannot be reached (TRD-001)" do
      rows_only = @pi_row_minimax <> "\n" <> @header

      with_pi(always_pi(rows_only), fn ->
        assert {:error, {:model_not_found, "minimax/MiniMax-M2.7"}} =
                 ModelCatalog.check(:pi, "minimax/MiniMax-M2.7")
      end)
    end
  end

  defp row_with_columns(provider, model, extra_columns) do
    String.pad_trailing(provider, 10) <> String.pad_trailing(model, 20) <> extra_columns
  end

  describe "row shape (TRD-001)" do
    test "the guard is a floor, not an equality: an eight-column row still matches" do
      padded =
        row_with_columns("minimax", "MiniMax-M2.7", "  128k  8k  no  yes  extra  more")

      with_pi(always_pi(@header <> "\n" <> padded), fn ->
        assert ModelCatalog.check(:pi, "minimax/MiniMax-M2.7") == :ok
      end)
    end

    # A truncated row ABOUT THE SEARCHED MODEL is unreadable output, not a
    # negative answer (§5.3): the catalog did not say "this model is absent",
    # it said something we could not parse. The same helper's rows for OTHER
    # models stay inert — see "an unrelated truncated row does not poison a
    # clean hit" below.
    test "a five-column row naming the searched model is a query failure" do
      short = row_with_columns("minimax", "MiniMax-M2.7", "  128k  8k  no")

      with_pi(always_pi(@header <> "\n" <> short), fn ->
        assert {:error, {:catalog_query_failed, {:malformed_row, ^short}}} =
                 ModelCatalog.check(:pi, "minimax/MiniMax-M2.7")
      end)
    end

    test "an unrelated truncated row does not poison a clean hit" do
      noise = row_with_columns("minimax", "MiniMax-M3", "  128k  8k  no")

      with_pi(always_pi(@header <> "\n" <> noise <> "\n" <> @pi_row_minimax), fn ->
        assert ModelCatalog.check(:pi, "minimax/MiniMax-M2.7") == :ok
      end)
    end
  end
end
