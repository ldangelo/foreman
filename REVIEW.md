# Code Review: Integrate DCG (Destructive Command Guard) into foreman agent workers

## Verdict: PASS

## Summary

The implementation correctly replaces the blanket `permissionMode: "bypassPermissions"` + `allowDangerouslySkipPermissions: true` pattern across all three entry points (single-agent mode, pipeline phases, and plan-step dispatch) with `"acceptEdits"`. The change is consistently applied, well-commented, and the design decision to use `acceptEdits` for all roles (rather than differentiated modes) is clearly reasoned in the developer report. Tests are thorough, enforce the DCG contract explicitly, and all pass. TypeScript compiles cleanly. The scope is minimal and focused — no unrelated changes snuck into the diff.

## Issues

None.

## Positive Notes

- The `permissionMode` field was added to `RoleConfig` in `roles.ts` rather than hardcoded at each call site, making future per-role tightening straightforward — a clean extensibility pattern.
- `allowDangerouslySkipPermissions: true` is removed everywhere, not just where the mode changed. This eliminates a confusing flag that would have been meaningless alongside `acceptEdits`.
- Inline comments at every changed call site explain *why* the mode was chosen, not just *what* it is — especially the non-interactive/detached-process rationale that explains why `"default"` mode would hang.
- The DCG test suite includes a negative test (`no role uses bypassPermissions`) that acts as a regression guard, not just a positive assertion of current values.
- The non-interactive mode test (`interactiveModes` array) is future-proof: if someone adds `"default"` to any role config, the test will fail with a clear message.
- Known limitations are honestly documented in `DEVELOPER_REPORT.md` (OS-level enforcement for file paths, MCP `destructive: true` annotations, plan-step impact).
- The `PermissionMode` type is imported from the SDK rather than declared locally, keeping type safety aligned with the upstream contract.
