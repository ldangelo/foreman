defmodule ForemanServer.Workflow.ReviewFindingsTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.ReviewFindings

  @start "<!-- FOREMAN_REVIEW_FINDINGS_START -->"
  @end_ "<!-- FOREMAN_REVIEW_FINDINGS_END -->"

  defp finding(overrides \\ %{}) do
    Map.merge(
      %{
        "severity" => "major",
        "path" => "lib/foo.ex",
        "line" => 12,
        "description" => "unchecked nil",
        "disposition" => "open",
        "source" => "repo-rules"
      },
      overrides
    )
  end

  defp doc(findings \\ [finding()], overrides \\ %{}) do
    Map.merge(
      %{"schema" => "foreman.review_findings/1", "reviewed" => true, "findings" => findings},
      overrides
    )
  end

  defp block(json) when is_map(json), do: block(Jason.encode!(json))
  defp block(text), do: "#{@start}\n#{text}\n#{@end_}\n"

  defp valid_block, do: block(doc())

  describe "parse/1 recorded and absent" do
    test "a valid block is recorded with typed findings and the artifact SHA-256" do
      contents = "# Review\n\ntext\n\n" <> valid_block()

      assert {:recorded, %ReviewFindings.Record{findings: [f], artifact_sha256: sha}} =
               ReviewFindings.parse(contents)

      assert %ReviewFindings.Finding{
               severity: :major,
               path: "lib/foo.ex",
               line: 12,
               description: "unchecked nil",
               disposition: :open,
               source: "repo-rules"
             } = f

      assert sha == :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
    end

    test "reviewed true with no findings is a recorded empty record, the one clean outcome" do
      assert {:recorded, %{findings: []}} = ReviewFindings.parse(block(doc([])))
    end

    test "findings [] without reviewed true is malformed" do
      assert ReviewFindings.parse(block(doc([], %{"reviewed" => false}))) ==
               {:malformed, :invalid_field}

      json = Jason.encode!(Map.delete(doc([]), "reviewed"))
      assert ReviewFindings.parse(block(json)) == {:malformed, :invalid_field}
    end

    test "no markers is :absent, never a recorded empty record" do
      assert ReviewFindings.parse("# Review\n\nnothing to see\n") == :absent
      assert ReviewFindings.parse("") == :absent
    end

    test "a nil path reads :absent and an unreadable path is an error, never clean" do
      assert ReviewFindings.read(nil) == :absent

      assert {:error, {:unreadable, :enoent}} =
               ReviewFindings.read("/nonexistent/phase1/review.md")
    end

    @tag :tmp_dir
    test "read/1 parses the file's bytes", %{tmp_dir: dir} do
      path = Path.join(dir, "review.md")
      File.write!(path, valid_block())
      assert {:recorded, %{findings: [_]}} = ReviewFindings.read(path)
    end

    @tag :tmp_dir
    test "a directory path is unreadable", %{tmp_dir: dir} do
      assert {:error, {:unreadable, :eisdir}} = ReviewFindings.read(dir)
    end
  end

  describe "parse/1 malformed shapes" do
    test "an unterminated block" do
      assert ReviewFindings.parse("#{@start}\n#{Jason.encode!(doc())}\n") ==
               {:malformed, :unterminated_block}
    end

    test "invalid JSON, and JSON that is not an object" do
      assert ReviewFindings.parse(block("{not json")) == {:malformed, :invalid_json}
      assert ReviewFindings.parse(block("[1, 2]")) == {:malformed, :invalid_json}
    end

    test "an unknown or missing schema" do
      assert ReviewFindings.parse(block(doc([], %{"schema" => "foreman.review_findings/2"}))) ==
               {:malformed, :unknown_schema}

      assert ReviewFindings.parse(block(~s({"reviewed": true, "findings": []}))) ==
               {:malformed, :unknown_schema}
    end

    test "an unknown severity" do
      assert ReviewFindings.parse(block(doc([finding(%{"severity" => "blocker"})]))) ==
               {:malformed, :invalid_field}
    end

    test "an unknown disposition" do
      assert ReviewFindings.parse(block(doc([finding(%{"disposition" => "wontfix"})]))) ==
               {:malformed, :invalid_field}
    end

    test "a missing or unknown key on a finding or the document" do
      assert ReviewFindings.parse(block(doc([Map.delete(finding(), "source")]))) ==
               {:malformed, :invalid_field}

      assert ReviewFindings.parse(block(doc([finding(%{"extra" => 1})]))) ==
               {:malformed, :invalid_field}

      assert ReviewFindings.parse(block(doc([finding()], %{"extra" => 1}))) ==
               {:malformed, :invalid_field}
    end

    test "a line that is not a positive integer or nil" do
      for bad <- [0, -1, 1.5, "12"] do
        assert ReviewFindings.parse(block(doc([finding(%{"line" => bad})]))) ==
                 {:malformed, :invalid_field}
      end

      assert {:recorded, %{findings: [%{line: nil}]}} =
               ReviewFindings.parse(block(doc([finding(%{"line" => nil})])))
    end

    test "wrong types for findings and reviewed" do
      assert ReviewFindings.parse(block(doc("nope"))) == {:malformed, :invalid_field}

      assert ReviewFindings.parse(block(doc([], %{"reviewed" => "true"}))) ==
               {:malformed, :invalid_field}

      assert ReviewFindings.parse(block(doc(["not a map"]))) == {:malformed, :invalid_field}
    end

    test "strings over their bounds are invalid, strings at the bound are accepted" do
      for {key, max} <- [{"description", 1000}, {"path", 1024}, {"source", 64}] do
        at = String.duplicate("a", max)
        over = String.duplicate("a", max + 1)

        assert {:recorded, _} = ReviewFindings.parse(block(doc([finding(%{key => at})])))

        assert ReviewFindings.parse(block(doc([finding(%{key => over})]))) ==
                 {:malformed, :invalid_field}
      end
    end
  end

  describe "parse/1 bounds" do
    test "a block over 32768 bytes is too_large" do
      padded = block(Jason.encode!(doc()) <> String.duplicate(" ", 32_768))
      assert ReviewFindings.parse(padded) == {:malformed, :too_large}
    end

    test "100 findings are accepted, 101 are too_many_findings" do
      assert {:recorded, %{findings: l}} =
               ReviewFindings.parse(block(doc(List.duplicate(finding(), 100))))

      assert length(l) == 100

      assert ReviewFindings.parse(block(doc(List.duplicate(finding(), 101)))) ==
               {:malformed, :too_many_findings}
    end
  end

  describe "parse/1 exact block size" do
    test "a block of exactly 32768 bytes is accepted, one more byte is too_large" do
      json = Jason.encode!(doc())
      exact = json <> String.duplicate(" ", 32_768 - byte_size(json))
      assert byte_size(exact) == 32_768
      assert {:recorded, _} = ReviewFindings.parse(block(exact))
      assert ReviewFindings.parse(block(exact <> " ")) == {:malformed, :too_large}
    end
  end

  describe "parse/1 control characters" do
    test "NUL, ESC, CR, DEL and other C0 characters in any string are invalid_field" do
      for key <- ["description", "path", "source"],
          bad <- ["\u0000", "\e", "\r", "\u007F", "\u0001", "\u001F"] do
        assert ReviewFindings.parse(block(doc([finding(%{key => "a#{bad}b"})]))) ==
                 {:malformed, :invalid_field},
               "#{key} with #{inspect(bad)}"
      end
    end

    test "a description may hold a newline and a tab, a path and a source may not" do
      assert {:recorded, _} =
               ReviewFindings.parse(block(doc([finding(%{"description" => "a\nb\tc"})])))

      for key <- ["path", "source"], ws <- ["\n", "\t"] do
        assert ReviewFindings.parse(block(doc([finding(%{key => "a#{ws}b"})]))) ==
                 {:malformed, :invalid_field}
      end
    end

    test "ordinary unicode text is accepted" do
      assert {:recorded, %{findings: [f]}} =
               ReviewFindings.parse(block(doc([finding(%{"description" => "naïve — 日本語 ✓"})])))

      assert f.description == "naïve — 日本語 ✓"
    end
  end

  describe "parse/1 line bound" do
    test "line 1_000_000_000 is accepted, one more is invalid_field" do
      assert {:recorded, _} =
               ReviewFindings.parse(block(doc([finding(%{"line" => 1_000_000_000})])))

      assert ReviewFindings.parse(block(doc([finding(%{"line" => 1_000_000_001})]))) ==
               {:malformed, :invalid_field}
    end
  end

  describe "parse/1 duplicate keys" do
    test "a repeated reviewed key is invalid_field, even when the last value is true" do
      text =
        ~s({"schema": "foreman.review_findings/1", "reviewed": false, "reviewed": true, "findings": []})

      assert ReviewFindings.parse(block(text)) == {:malformed, :invalid_field}
    end

    test "a repeated key inside a finding is invalid_field" do
      text =
        ~s({"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "minor", "severity": "critical", "path": "a", "line": 1, "description": "d", "disposition": "open", "source": "s"}]})

      assert ReviewFindings.parse(block(text)) == {:malformed, :invalid_field}
    end
  end

  describe "parse/1 fences" do
    @fenced_block "```\n#{@start}\n```\n"

    test "a closing fence with trailing text does not close" do
      # The fence stays open, so the real block after it is inside the fence.
      assert ReviewFindings.parse("```\ncode\n``` x\n" <> valid_block()) == :absent
    end

    test "a closing fence indented four spaces does not close" do
      assert ReviewFindings.parse("```\ncode\n    ```\n" <> valid_block()) == :absent
    end

    test "a tilde fence whose info string holds a backtick is a fence" do
      # The quoted marker inside the fence is not counted, so one pair remains.
      assert {:recorded, _} = ReviewFindings.parse("~~~ a`b\n#{@start}\n~~~\n" <> valid_block())
    end

    test "a backtick fence whose info string holds a backtick is not a fence" do
      assert {:recorded, _} = ReviewFindings.parse("``` a`b\n" <> valid_block())
    end

    test "a CRLF artifact with a closed fence before the real block is recorded" do
      contents =
        String.replace(@fenced_block <> "text\n" <> valid_block(), "\n", "\r\n")

      assert {:recorded, _} = ReviewFindings.parse(contents)
    end

    test "a CRLF fence opened with a quoted marker and never closed hides a later block" do
      contents = String.replace("```\n#{@start}\ntext\n" <> valid_block(), "\n", "\r\n")
      assert ReviewFindings.parse(contents) == :absent
    end
  end

  describe "read/1 size cap" do
    @cap 4 * 1024 * 1024

    defp tmp_file!(name, contents) do
      dir = Path.join(System.tmp_dir!(), "review-findings-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      path = Path.join(dir, name)
      File.write!(path, contents)
      path
    end

    test "an artifact of exactly the cap is read and parsed, one byte more is too_large" do
      base = valid_block()
      exact = base <> String.duplicate("x", @cap - byte_size(base))
      assert byte_size(exact) == @cap

      assert {:recorded, %{artifact_sha256: sha}} = ReviewFindings.read(tmp_file!("a.md", exact))
      assert sha == :crypto.hash(:sha256, exact) |> Base.encode16(case: :lower)

      assert ReviewFindings.read(tmp_file!("b.md", exact <> "x")) == {:malformed, :too_large}
    end

    test "an oversized sparse file is too_large, not unreadable and not absent" do
      dir = Path.join(System.tmp_dir!(), "review-findings-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      path = Path.join(dir, "sparse.md")
      {:ok, io} = File.open(path, [:write, :raw])
      {:ok, _} = :file.position(io, 1024 * 1024 * 1024)
      :ok = :file.write(io, "x")
      :ok = File.close(io)

      assert ReviewFindings.read(path) == {:malformed, :too_large}
    end

    test "a missing file is still unreadable" do
      assert ReviewFindings.read(
               Path.join(System.tmp_dir!(), "no-such-#{System.unique_integer([:positive])}")
             ) ==
               {:error, {:unreadable, :enoent}}
    end
  end

  describe "parse/1 earlier format" do
    test "a bullet block is legacy_format, not invalid_json" do
      assert ReviewFindings.parse(block("- `lib/foo.ex:12` Major — unchecked nil")) ==
               {:malformed, :legacy_format}

      assert ReviewFindings.parse(block("\n* item")) == {:malformed, :legacy_format}
    end

    test "an empty or blank block is legacy_format" do
      assert ReviewFindings.parse("#{@start}\n#{@end_}\n") == {:malformed, :legacy_format}
      assert ReviewFindings.parse(block("   \n  ")) == {:malformed, :legacy_format}
    end
  end

  describe "parse/1 counted one-pair rule" do
    test "a carried-forward block at column 0 then the final block is multiple_blocks" do
      assert ReviewFindings.parse(valid_block() <> "\nmore text\n" <> valid_block()) ==
               {:malformed, :multiple_blocks}
    end

    test "a second counted start or a second counted end alone is multiple_blocks" do
      assert ReviewFindings.parse("#{@start}\n#{@start}\n{}\n#{@end_}\n") ==
               {:malformed, :multiple_blocks}

      assert ReviewFindings.parse("#{@start}\n{}\n#{@end_}\n#{@end_}\n") ==
               {:malformed, :multiple_blocks}
    end

    test "a start with no end, a lone end, and an end before the start are unterminated_block" do
      assert ReviewFindings.parse("#{@start}\n{}\n") == {:malformed, :unterminated_block}
      assert ReviewFindings.parse("#{@end_}\n") == {:malformed, :unterminated_block}

      assert ReviewFindings.parse("#{@end_}\n{}\n#{@start}\n") ==
               {:malformed, :unterminated_block}
    end

    test "trailing whitespace and CRLF line ends still count" do
      contents = "#{@start}  \r\n#{Jason.encode!(doc())}\r\n#{@end_}\t\r\n"
      assert {:recorded, _} = ReviewFindings.parse(contents)
    end

    test "blocks quoted inside a backtick fence and a tilde fence do not count" do
      quoted =
        "```\n#{valid_block()}```\n\n~~~markdown\n#{valid_block()}~~~\n\n"

      assert {:recorded, %{findings: [_]}} = ReviewFindings.parse(quoted <> valid_block())
    end

    test "a four-backtick fence holding a three-backtick line stays open" do
      contents = "````\n```\n#{@start}\n````\n\n" <> valid_block()
      assert {:recorded, %{findings: [_]}} = ReviewFindings.parse(contents)

      # the quoted marker is inside the outer fence: only the real block counts
      assert ReviewFindings.parse("````\n```\n#{@start}\n```\n#{@end_}\n````\n") == :absent
    end

    test "a fence closed by a shorter run of the same character does not close" do
      contents = "````\n```\n#{@start}\n#{@end_}\n````\n" <> valid_block()
      assert {:recorded, _} = ReviewFindings.parse(contents)
    end

    test "a tilde line does not close a backtick fence" do
      contents = "```\n~~~\n#{@start}\n```\n" <> valid_block()
      assert {:recorded, _} = ReviewFindings.parse(contents)
    end

    test "an indented marker, a blockquote marker and an inline quote are not counted" do
      for quoted <- [
            "  #{@start}\n  #{@end_}",
            "> #{@start}\n> #{@end_}",
            "see #{@start} and #{@end_} here",
            "\"#{@start}\""
          ] do
        assert {:recorded, %{findings: [_]}} =
                 ReviewFindings.parse(quoted <> "\n\n" <> valid_block())

        assert ReviewFindings.parse(quoted <> "\n") == :absent
      end
    end

    test "a marker quoted inside a JSON string of the block is not counted" do
      desc = "the marker #{@start} is quoted"

      assert {:recorded, %{findings: [%{description: ^desc}]}} =
               ReviewFindings.parse(block(doc([finding(%{"description" => desc})])))
    end

    test "a fence that is never closed hides the markers after it" do
      assert ReviewFindings.parse("```\n" <> valid_block()) == :absent

      assert ReviewFindings.parse("#{@start}\n```\n{}\n#{@end_}\n") ==
               {:malformed, :unterminated_block}
    end

    test "an info string with a backtick is not a fence" do
      assert {:recorded, _} = ReviewFindings.parse("``` not `a` fence\n" <> valid_block())
    end
  end

  describe "extract_block/3" do
    test "scans any marker pair with the same rule" do
      s = "<!-- X_START -->"
      e = "<!-- X_END -->"
      assert ReviewFindings.extract_block("a\n#{s}\nbody\n#{e}\n", s, e) == {:ok, "body"}
      assert ReviewFindings.extract_block("```\n#{s}\n#{e}\n```\n", s, e) == :absent

      assert ReviewFindings.extract_block("#{s}\n#{e}\n#{s}\n#{e}\n", s, e) ==
               {:error, :multiple_blocks}

      assert ReviewFindings.extract_block("#{s}\n", s, e) == {:error, :unterminated_block}
      assert ReviewFindings.extract_block("#{s}\n#{e}\n", s, e) == {:ok, ""}
    end
  end

  describe "defect/1" do
    test "maps every malformed reason and the unreadable error to a closed code and bounded detail" do
      for reason <-
            ~w(unterminated_block multiple_blocks legacy_format invalid_json unknown_schema invalid_field too_large too_many_findings)a do
        assert {^reason, detail} = ReviewFindings.defect({:malformed, reason})
        assert detail != "" and String.length(detail) <= 500
      end

      assert {:unreadable, detail} = ReviewFindings.defect({:error, {:unreadable, :enoent}})
      assert detail =~ "enoent"

      long = String.duplicate("x", 2000)
      assert {:unreadable, d} = ReviewFindings.defect({:error, {:unreadable, long}})
      assert String.length(d) == 500
    end
  end

  describe "unresolved/1" do
    defp f(sev, disp),
      do: %ReviewFindings.Finding{
        severity: sev,
        path: "a",
        line: nil,
        description: "d",
        disposition: disp,
        source: "s"
      }

    test "counts every open finding and declined critical or major, by severity" do
      findings =
        for sev <- [:critical, :major, :minor, :nitpick],
            disp <- [:open, :declined, :fixed],
            do: f(sev, disp)

      assert ReviewFindings.unresolved(findings) ==
               %{critical: 2, major: 2, minor: 1, nitpick: 1}

      assert ReviewFindings.unresolved(%ReviewFindings.Record{
               findings: findings,
               artifact_sha256: "x"
             }) ==
               %{critical: 2, major: 2, minor: 1, nitpick: 1}
    end

    test "a declined critical finding is counted, fixed and declined minor are not" do
      assert ReviewFindings.unresolved([f(:critical, :declined)]).critical == 1

      assert ReviewFindings.unresolved([
               f(:critical, :fixed),
               f(:minor, :declined),
               f(:nitpick, :declined)
             ]) ==
               %{critical: 0, major: 0, minor: 0, nitpick: 0}
    end
  end
end

defmodule ForemanServer.Workflow.ReviewPromptContractTest do
  # The review prompts specify the block the parser (TRD-013) reads. These tests
  # pin the contract text and prove the prompts' own example parses the way the
  # prompt says it does.
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.ReviewFindings

  @prompts_dir Path.expand("../../../priv/defaults/workflows/prompts", __DIR__)
  @prompts ["review-coderabbit.md", "review-repo-rules.md"]

  defp raw(name), do: File.read!(Path.join(@prompts_dir, name))
  defp prompt(name), do: name |> raw() |> String.split() |> Enum.join(" ")

  # The example is the fenced block holding the marker lines.
  defp example(text) do
    [_before, rest] = String.split(text, "```\n<!-- FOREMAN_REVIEW_FINDINGS_START -->", parts: 2)
    [block, _after] = String.split(rest, "```\n", parts: 2)
    "<!-- FOREMAN_REVIEW_FINDINGS_START -->" <> block
  end

  for name <- @prompts do
    describe name do
      test "states the schema, the closed sets and the reviewed rule" do
        text = prompt(unquote(name))

        assert text =~ "foreman.review_findings/1"

        for word <- ~w(critical major minor nitpick fixed declined open) do
          assert text =~ "`#{word}`"
        end

        assert text =~ ~s("reviewed": true)
        assert text =~ "review that did not run writes no block at all"
        assert text =~ "exactly once"
        assert text =~ "declined critical or major finding is still shown"

        # The triage-to-disposition mapping: fix -> fixed, decline -> declined,
        # anything else -> open.
        assert text =~
                 "`fixed` for a finding you fixed, `declined` for one you declined, `open` for any other finding"
      end

      test "tells the agent to fence a quoted marker and not to fence the block" do
        text = prompt(unquote(name))

        assert text =~ "put the quote inside a code fence"
        assert text =~ "stands alone at the start of a line, outside any code fence"
        assert text =~ "do not wrap the JSON in a fence"
        refute text =~ ~r/never quote|do not quote|don't quote/i
        refute text =~ ~r/wrap the (findings )?block in a (code )?fence/i
      end

      test "the example holds one placeholder finding, parses as recorded and stays open" do
        assert {:recorded, %ReviewFindings.Record{findings: [finding]}} =
                 ReviewFindings.parse(example(raw(unquote(name))))

        assert finding.description =~ "PLACEHOLDER"
        assert finding.disposition == :open
      end

      test "the prompt itself holds no counted block: its example is fenced" do
        assert ReviewFindings.parse(raw(unquote(name))) == :absent
      end
    end
  end

  test "the CodeRabbit prompt writes no block when the engine could not run" do
    text = prompt("review-coderabbit.md")

    assert text =~ "write NO findings block"
    refute text =~ "empty findings block"
    refute text =~ "Emit the markers even when empty"
  end

  test "the repo-rules carry-forward copies finding objects, not bullets or markers" do
    text = prompt("review-repo-rules.md")

    assert text =~ "copy each finding object"
    assert text =~ "Never copy the marker lines, and never copy a previous judgement block"
    refute text =~ "copy every bullet"
    refute text =~ "Markdown bullet"
  end
end
