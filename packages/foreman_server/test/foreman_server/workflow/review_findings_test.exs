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

    test "returns :none when the end marker is absent" do
      contents = """
      # Report

      <!-- FOREMAN_REVIEW_FINDINGS_START -->
      - `lib/foo.ex:12` Major — unchecked nil
      """

      assert ReviewFindings.extract_from(contents) == :none
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
      assert byte_size(block) <= 4000 + byte_size("\n… truncated; see the phase artifact for the full list.")
      assert block =~ "… truncated; see the phase artifact for the full list."
    end
  end

  describe "extract/1" do
    test "returns :none for nil" do
      assert ReviewFindings.extract(nil) == :none
    end

    test "returns :none for a nonexistent path" do
      path = Path.join(System.tmp_dir!(), "does-not-exist-#{System.unique_integer([:positive])}.md")
      assert ReviewFindings.extract(path) == :none
    end

    test "reads and extracts from an existing file" do
      dir = Path.join(System.tmp_dir!(), "review-findings-test-#{System.unique_integer([:positive])}")
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
end
