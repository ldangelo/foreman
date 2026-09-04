defmodule ForemanServer.Actions.RepresentativeActionTimingTest do
  @moduledoc """
  TRD-085 / ADT-T003 — Benchmark: measure and document end-to-end time
  against the 4-hour target; record as benchmark baseline.

  Files are in `docs/ADT/` at the repo root (two levels up from the
  Mix project at `packages/foreman_server/`).
  """
  use ExUnit.Case, async: false
  @moduletag :timing

  # Path from packages/foreman_server/ to docs/ADT/
  @adt_docs "../../docs/ADT/"

  test "representative action development time scaffolding artifacts exist" do
    assert File.exists?("#{@adt_docs}representative-action.md"),
           "ADT-T001 template missing"

    assert File.exists?("#{@adt_docs}representative-action-run.md"),
           "ADT-T002 E2E run plan missing"

    assert File.exists?("#{@adt_docs}representative-action-timing.md"),
           "ADT-T003 timing doc missing"
  end

  test "timing doc documents methodology and baseline" do
    timing_doc = Path.join(@adt_docs, "representative-action-timing.md")
    assert {:ok, content} = File.read(timing_doc)

    assert content =~ "NFR-01",
           "timing doc must reference NFR-01 target"

    assert content =~ "methodology",
           "timing doc must document methodology"

    assert content =~ "Baseline",
           "timing doc must have Baseline section"

    assert content =~ "Benchmark log",
           "timing doc must have Benchmark log section"
  end

  test "run doc documents the E2E plan" do
    run_doc = Path.join(@adt_docs, "representative-action-run.md")
    assert {:ok, content} = File.read(run_doc)

    assert content =~ "GitStatusAction",
           "run doc must reference the representative action"

    assert content =~ "e2e",
           "run doc must describe e2e test scaffold"
  end
end
