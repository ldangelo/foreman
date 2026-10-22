defmodule ForemanServer.Coordinator.StatusBlockTest do
  # F7 (foreman-rkfxs): the model said "five ready for review" when two were.
  use ExUnit.Case, async: true

  alias ForemanServer.Coordinator.StatusBlock

  @counts %{
    ready_for_review: 2,
    waiting_on_you: 1,
    working: 3,
    landing: 0,
    idle: 1,
    resolved: 4
  }

  test "a status reply gets the authoritative line, next to the model's wrong number" do
    out = StatusBlock.annotate("You have five threads ready for review.", @counts)

    assert out =~ "five threads ready for review"

    assert out =~
             "Status (computed by Foreman from the Overview): ready for review 2 · " <>
               "waiting on you 1 · working 3 · landing 0 · idle 1 · resolved 4"
  end

  test "a reply that is not about status is left alone" do
    assert StatusBlock.annotate("Started the abs_diff thread.", @counts) ==
             "Started the abs_diff thread."
  end

  test "annotating twice appends once; unknown counts append nothing" do
    once = StatusBlock.annotate("Two are working.", @counts)
    assert StatusBlock.annotate(once, @counts) == once
    assert StatusBlock.annotate("Two are working.", %{}) == "Two are working."
  end

  test "missing groups count as zero" do
    assert StatusBlock.line(%{working: 1}) =~ "ready for review 0 · waiting on you 0 · working 1"
  end
end
