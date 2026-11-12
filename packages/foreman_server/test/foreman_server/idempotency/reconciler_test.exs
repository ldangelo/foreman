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

  # The answers of the optional callbacks come from the metadata, so one module shows every
  # case: a boolean, something that is not one, and a callback that fails.
  defmodule Callbacks do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler

    @impl true
    def reconcile(_metadata), do: :unknown

    @impl true
    def repeatable?(%{"repeatable" => answer}), do: answer(answer)

    @impl true
    def blocks_run?(%{"blocks" => answer}), do: answer(answer)

    defp answer("true"), do: true
    defp answer("false"), do: false
    defp answer("garbage"), do: :maybe
    defp answer("raise"), do: raise("callback down")
    defp answer("throw"), do: throw(:ball)
    defp answer("exit"), do: exit(:noproc)
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

    test "the configured registry holds the push, PR-create and task-provider reconcilers" do
      assert Reconciler.classes() == %{
               "branch_push" => ForemanServer.Idempotency.Reconcilers.BranchPush,
               "pr_create" => ForemanServer.Idempotency.Reconcilers.PrCreate,
               "task_provider" => ForemanServer.Idempotency.Reconcilers.TaskProvider
             }

      assert Reconciler.verdict("annotate", %{}) == :unregistered
    end
  end

  describe "repeatable?/3 and blocks_run?/3 (the optional callbacks)" do
    @optional_classes %{"declared" => Callbacks, "bare" => Answering}

    test "a class that declares neither callback is not repeatable and blocks the run" do
      refute Reconciler.repeatable?("bare", %{}, classes: @optional_classes)
      assert Reconciler.blocks_run?("bare", %{}, classes: @optional_classes)
    end

    test "a class with no reconciler is not repeatable and blocks the run" do
      refute Reconciler.repeatable?("unregistered", %{}, classes: @optional_classes)
      assert Reconciler.blocks_run?("unregistered", %{}, classes: @optional_classes)
      refute Reconciler.repeatable?("declared", %{}, classes: %{})
      assert Reconciler.blocks_run?("declared", %{}, classes: %{})
    end

    test "a declared answer is read from the stored metadata" do
      opts = [classes: @optional_classes]

      assert Reconciler.repeatable?("declared", %{"repeatable" => "true"}, opts)
      refute Reconciler.repeatable?("declared", %{"repeatable" => "false"}, opts)
      assert Reconciler.blocks_run?("declared", %{"blocks" => "true"}, opts)
      refute Reconciler.blocks_run?("declared", %{"blocks" => "false"}, opts)
    end

    test "an answer that is not a boolean and a callback that fails take the default" do
      opts = [classes: @optional_classes]

      for how <- ["garbage", "raise", "throw", "exit"] do
        refute Reconciler.repeatable?("declared", %{"repeatable" => how}, opts), how
        assert Reconciler.blocks_run?("declared", %{"blocks" => how}, opts), how
      end

      # metadata the callback has no clause for raises inside it: the same default
      refute Reconciler.repeatable?("declared", %{}, opts)
      assert Reconciler.blocks_run?("declared", %{}, opts)
    end

    test "the configured registry: only a task-provider reopen is repeatable and none stops blocking" do
      refute Reconciler.repeatable?("branch_push", %{})
      refute Reconciler.repeatable?("pr_create", %{})
      refute Reconciler.repeatable?("task_provider", %{"op" => "claim"})
      assert Reconciler.repeatable?("task_provider", %{"op" => "reopen"})

      for class <- ["branch_push", "pr_create", "task_provider"] do
        assert Reconciler.blocks_run?(class, %{"op" => "reopen"}), class
      end
    end
  end

  describe "metadata accessors" do
    test "read string keys only: normalising is the caller's single step" do
      assert Reconciler.class_of(%{"effect_class" => "pr_create"}) == "pr_create"
      assert Reconciler.run_id_of(%{"run_id" => "run-1"}) == "run-1"
      assert Reconciler.class_of(%{effect_class: "pr_create"}) == nil
      assert Reconciler.run_id_of(%{run_id: "run-1"}) == nil
    end

    test "a missing or empty field is nil" do
      assert Reconciler.class_of(%{}) == nil
      assert Reconciler.run_id_of(%{"run_id" => ""}) == nil
      assert Reconciler.run_id_of(nil) == nil
    end
  end
end
