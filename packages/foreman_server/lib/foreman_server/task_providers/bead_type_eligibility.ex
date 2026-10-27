defmodule ForemanServer.TaskProviders.BeadTypeEligibility do
  @moduledoc """
  Which bead types BeadsWatcher dispatches and which it holds (PRD REQ-008,
  AC-008-1 / AC-008-2).

  A labelled, open bead dispatches only when its `issue_type` is named in some
  workflow manifest's `task_types:`. This reports that decision for every type,
  derived from the two sources the decision itself reads and never from a
  hand-kept list:

    * `mapped` is exactly `Workflow.Catalog.type_to_workflow_map/0` — whatever
      the manifests declare right now, custom types included (`br` accepts any
      type string, e.g. `implement_trd`);
    * `unmapped` is the tracker's built-in types (`BeadsAdapter.task_types/0`)
      that no manifest maps.

  Adding a `task_types:` entry to any manifest therefore changes the report
  with no second edit.

  An unmapped type is the documented not-applicable category, not a fault: a
  bead of that type is *held* — BeadsWatcher never dispatches or mutates it and
  records it as `:unmapped` on every poll — until a manifest declares the type.
  Whether untyped `task` / `feature` / `epic` / `chore` beads should instead get
  a default workflow is a product decision this report deliberately does not
  make (TRD OTD-1).
  """

  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.Workflow.Catalog

  @enforce_keys [:mapped, :unmapped]
  defstruct [:mapped, :unmapped]

  @type t :: %__MODULE__{
          mapped: [{type :: String.t(), workflow :: String.t()}],
          unmapped: [String.t()]
        }

  @doc "The report against the live catalog and the tracker's built-in types."
  @spec report() :: t()
  def report, do: build(Catalog.type_to_workflow_map(), BeadsAdapter.task_types())

  @doc """
  The pure derivation: the type-to-workflow map and the tracker's built-in types
  in, both halves out, each sorted.
  """
  @spec build(%{String.t() => String.t()}, [String.t()]) :: t()
  def build(type_to_workflow, tracker_types)
      when is_map(type_to_workflow) and is_list(tracker_types) do
    %__MODULE__{
      mapped: Enum.sort(type_to_workflow),
      unmapped:
        tracker_types
        |> Enum.reject(&Map.has_key?(type_to_workflow, &1))
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  @doc """
  One line for `foreman doctor`: what dispatches, and what is held and why.
  """
  @spec summarize(t()) :: String.t()
  def summarize(%__MODULE__{mapped: mapped, unmapped: unmapped}) do
    dispatched =
      case mapped do
        [] ->
          "dispatched: none"

        pairs ->
          "dispatched: " <> Enum.map_join(pairs, ", ", fn {type, wf} -> "#{type} -> #{wf}" end)
      end

    held =
      case unmapped do
        [] ->
          "held: none"

        types ->
          "held (no workflow maps them, so a labelled bead of these types is never dispatched): " <>
            Enum.join(types, ", ")
      end

    dispatched <> "; " <> held
  end
end
