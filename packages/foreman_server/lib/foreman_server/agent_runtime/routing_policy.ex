defmodule ForemanServer.AgentRuntime.RoutingPolicy do
  @moduledoc """
  Behaviour for policy-driven routing.

  TRD-2026-6af02293 §Public Contracts defines the contract a policy module
  implements to make centralised routing decisions. A policy module
  receives the current task type and a point-in-time snapshot of
  registered backend capabilities (keyed by backend name) and returns
  the backend name it has selected for the request.

  ## Contract

      @callback route(task_type :: atom(), capabilities :: %{atom() => map()}) :: atom()

  - `task_type` is the routing input supplied by the caller (the same
    task type the automatic strategy filters `supported_contexts`
    against). `nil` is permitted when the caller did not supply one.

  - `capabilities` is the catalog's stored capability snapshot keyed by
    backend name: `%{backend_name => capability_map}`. The map is the
    exact map the catalog validated at registration time — the policy
    MUST treat it as read-only.

  - The returned atom MUST be a backend name that is registered with the
    adapter catalog. The router looks the name up and translates
    "unknown" into `{:error, :backend_not_found}`; the policy module
    does not need to validate registration itself.

  ## Why the caller passes no backend override

  Centralising routing policy in a module means the choice of backend
  is the policy's, not the caller's. Callers using the `:policy`
  strategy do not pass `:backend`; they pass `:policy`. This separation
  keeps every call site consistent and avoids scattering backend
  preferences across the codebase.

  ## Where this fits in the routing pipeline

  The selected backend enters the same availability / fallback pipeline
  as automatic routing. The router preserves the policy's selection as
  the first candidate — including when the selection is unavailable or
  task-type-mismatched — so the Invocation layer (TRD-008) can decide
  whether to advance per the resolved failure policy (TRD-007). The
  router itself does not auto-skip; that is the Invocation's job.
  """

  @callback route(task_type :: atom(), capabilities :: %{atom() => map()}) :: atom()
end
