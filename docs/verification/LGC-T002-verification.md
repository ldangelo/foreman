# LGC-T002 Verification (TRD-2026-4212be7e)
Verified: 2026-08-19

## Existing security event logging
- none found
- Note: `packages/foreman_server/lib/foreman_server_web/controllers/command_controller.ex:34-37` returns HTTP `403 :forbidden` with body `{"error": "command_not_allowed", "type": type}` when the command gateway rejects an envelope, but no `security_event` / `SecurityEvent` module or audit emission is invoked on denial.
- Note: `packages/foreman_server/lib/foreman_server/aggregates/tool_call.ex:43-50,83` emits the `ToolCallDenied` domain event when a tool call hits the rejected transition, but this is a business projection event, not a separate security audit log.

## Existing access denial tests
- `packages/foreman_server/test/foreman_server_web/event_store_web_enforcement_test.exs:test "controller files do not bypass the web-layer CQRS boundary"` — AST-walker asserts controllers do not call `EventStore.append_to_stream/3`, `CommandRouter.append_*`, or `RunLifecycleReconciler.retry_run_start/2`.
- `packages/foreman_server/test/foreman_server_web/event_store_web_enforcement_test.exs:test "controllers do not import or alias RunLifecycleReconciler"` — AST-walker rejects any reference to `RunLifecycleReconciler` from controllers.
- `packages/foreman_server/test/foreman_server_web/event_store_web_enforcement_test.exs:test "web layer does not call RunLifecycleReconciler.retry_run_start/2"` — AST-walker rejects direct reconciler calls across the web layer.
- `packages/foreman_server/test/foreman_server/event_store_enforcement_test.exs:test "detects forbidden EventStore.append_to_stream call"` — AST-walker self-test.
- `packages/foreman_server/test/foreman_server/event_store_enforcement_test.exs:test "detects forbidden CommandRouter.dispatch call"` — AST-walker self-test.
- `packages/foreman_server/test/foreman_server/admission_facade_enforcement_test.exs:test "only allowlisted non-web server files call RunAdmission.start/2 or /3"` — AST-walker guard around the run-admission facade.
- `packages/foreman_server/test/foreman_server/admission_facade_enforcement_test.exs:test "allowlists internal server seams for RunAdmission.start/2 or /3"` — companion allowlist check.
- `packages/foreman_server/test/foreman_server/architecture/alias_boundary_test.exs:test ...` — AST-walker rejects non-allowlisted `TaskProviders.*` alias sites.
- `packages/foreman_server/test/foreman_server/workflow/codec_registry_test.exs:test "web layer does not call RunAdmission.start/2 or /3 directly"` — AST-walker sibling of the web enforcement test.

## Verdict
PARTIAL — static AST-walker enforcement rejects direct calls to `EventStore`, `CommandRouter`, `RunAdmission`, and `RunLifecycleReconciler` from outside the Phoenix boundary, but no dedicated `security_event` log is emitted at runtime when a denial occurs.

## Gaps (if any)
- No `SecurityEvent` / `security_event` / `audit_log` module exists; the only `:forbidden` response (`command_controller.ex:36`) returns an HTTP 403 without a dedicated audit emission.
- Denial coverage is purely static (AST walker over source files); there is no runtime test that invokes an internal seam from outside the boundary and asserts both a denial return and a recorded security event.
- `ToolCallDenied` (aggregates/tool_call.ex:43) is a domain event, not a security event, and it is not surfaced through any audit log.
- "Forbidden" matches in tests are about the AST-walker meaning of "call site not in allowlist", not about runtime access denial; the wording can mislead reviewers.
