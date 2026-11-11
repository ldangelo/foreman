defmodule ForemanServer.Idempotency.ReconcilerTest do
  @moduledoc """
  `ForemanServer.Idempotency.Reconciler` (TRD-012): the class registry and the
  three verdicts. A class with no reconciler, an answer outside the three
  verdicts and a reconciler that fails are never read as "the effect did not
  happen".
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.Idempotency.Reconciler

  defmodule Answering do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler

    @impl true
    def reconcile(%{"fake_verdict" => verdict}), do: String.to_existing_atom(verdict)
  end

  defmodule Garbage do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler

    @impl true
    def reconcile(_metadata), do: :maybe
  end

  defmodule Raising do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler

    @impl true
    def reconcile(_metadata), do: raise("provider down")
  end

  defmodule Exiting do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler

    @impl true
    def reconcile(_metadata), do: exit(:noproc)
  end

  @classes %{
    "branch_push" => Answering,
    "garbage" => Garbage,
    "raising" => Raising,
    "exiting" => Exiting
  }

  describe "verdict/3" do
    test "returns the registered reconciler's answer for :done, :not_done and :unknown" do
      for verdict <- [:done, :not_done, :unknown] do
        metadata = %{"fake_verdict" => Atom.to_string(verdict)}
        assert Reconciler.verdict("branch_push", metadata, classes: @classes) == verdict
      end
    end

    test "a class with no reconciler is :unregistered, never :not_done" do
      assert Reconciler.verdict("pr_create", %{}, classes: @classes) == :unregistered
      assert Reconciler.verdict("branch_push", %{}, classes: %{}) == :unregistered
    end

    test "an answer outside the three verdicts fails closed to :unknown" do
      assert Reconciler.verdict("garbage", %{}, classes: @classes) == :unknown
    end

    test "a reconciler that raises or exits fails closed to :unknown" do
      assert Reconciler.verdict("raising", %{}, classes: @classes) == :unknown
      assert Reconciler.verdict("exiting", %{}, classes: @classes) == :unknown
    end

    test "the configured registry is empty until TRD-013 and TRD-015 register classes" do
      assert Reconciler.classes() == %{}
      assert Reconciler.verdict("branch_push", %{}) == :unregistered
    end
  end

  describe "metadata accessors" do
    test "read the string keys a restart leaves and the atom keys the ETS path can hold" do
      assert Reconciler.class_of(%{"effect_class" => "pr_create"}) == "pr_create"
      assert Reconciler.class_of(%{effect_class: "pr_create"}) == "pr_create"
      assert Reconciler.run_id_of(%{"run_id" => "run-1"}) == "run-1"
      assert Reconciler.run_id_of(%{run_id: "run-1"}) == "run-1"
    end

    test "a missing or empty field is nil" do
      assert Reconciler.class_of(%{}) == nil
      assert Reconciler.run_id_of(%{"run_id" => ""}) == nil
      assert Reconciler.run_id_of(nil) == nil
    end
  end
end
