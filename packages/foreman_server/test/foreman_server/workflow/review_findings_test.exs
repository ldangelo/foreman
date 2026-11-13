defmodule ForemanServer.Workflow.ReviewFindingsTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.ReviewFindings

  describe "extract_from/1" do
    test "returns the block content with both bullets and neither marker" do
      contents = """
      # Report

      Some prose.

      <!-- FOREMAN_REVIEW_FINDINGS_START -->
      - `lib/foo.ex:12` Major — unchecked nil
      - `lib/bar.ex:34` Minor — missing typespec
      <!-- FOREMAN_REVIEW_FINDINGS_END -->
      """

      assert {:ok, block} = ReviewFindings.extract_from(contents)
      assert block =~ "lib/foo.ex:12"
      assert block =~ "lib/bar.ex:34"
      refute block =~ "FOREMAN_REVIEW_FINDINGS_START"
      refute block =~ "FOREMAN_REVIEW_FINDINGS_END"
    end

    test "returns :none when the start marker is absent" do
      contents = """
      # Report

      - `lib/foo.ex:12` Major — unchecked nil
      <!-- FOREMAN_REVIEW_FINDINGS_END -->
      """

      assert ReviewFindings.extract_from(contents) == :none
    end

    test "returns {:error, :unterminated_block} when the end marker is absent" do
      contents = """
      # Report

      <!-- FOREMAN_REVIEW_FINDINGS_START -->
      - `lib/foo.ex:12` Major — unchecked nil
      """

      assert ReviewFindings.extract_from(contents) == {:error, :unterminated_block}
    end

    test "returns :none when the block trims to an empty string" do
      contents = """
      <!-- FOREMAN_REVIEW_FINDINGS_START -->

      <!-- FOREMAN_REVIEW_FINDINGS_END -->
      """

      assert ReviewFindings.extract_from(contents) == :none
    end

    test "truncates a block over 4000 bytes with a truncation notice" do
      long_block = String.duplicate("x", 5000)

      contents =
        "<!-- FOREMAN_REVIEW_FINDINGS_START -->\n" <>
          long_block <> "\n<!-- FOREMAN_REVIEW_FINDINGS_END -->"

      assert {:ok, block} = ReviewFindings.extract_from(contents)

      assert byte_size(block) <=
               4000 + byte_size("\n… truncated; see the phase artifact for the full list.")

      assert block =~ "… truncated; see the phase artifact for the full list."
    end

    test "truncates a multi-byte block on a codepoint boundary, never splitting a character" do
      long_block = String.duplicate("—", 3000)

      contents =
        "<!-- FOREMAN_REVIEW_FINDINGS_START -->\n" <>
          long_block <> "\n<!-- FOREMAN_REVIEW_FINDINGS_END -->"

      assert {:ok, block} = ReviewFindings.extract_from(contents)
      assert String.valid?(block)

      assert byte_size(block) <=
               4000 + byte_size("\n… truncated; see the phase artifact for the full list.")

      assert block =~ "… truncated; see the phase artifact for the full list."
    end
  end

  describe "extract/1" do
    test "returns :none for nil" do
      assert ReviewFindings.extract(nil) == :none
    end

    test "returns :none for a nonexistent path" do
      path =
        Path.join(System.tmp_dir!(), "does-not-exist-#{System.unique_integer([:positive])}.md")

      assert ReviewFindings.extract(path) == :none
    end

    test "reads and extracts from an existing file" do
      dir =
        Path.join(System.tmp_dir!(), "review-findings-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      path = Path.join(dir, "REPORT.md")

      File.write!(path, """
      <!-- FOREMAN_REVIEW_FINDINGS_START -->
      - `lib/foo.ex:1` Nitpick — style only
      <!-- FOREMAN_REVIEW_FINDINGS_END -->
      """)

      assert {:ok, block} = ReviewFindings.extract(path)
      assert block =~ "lib/foo.ex:1"
    end
  end

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
