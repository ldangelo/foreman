/**
 * Workflow configuration and resolution utilities.
 *
 * @deprecated Use workflow-loader.ts for new code.
 * This module is kept for backward compatibility with callers that import
 * resolveWorkflowType(). The logic now lives in workflow-loader.ts.
 */
// Re-export resolveWorkflowName as resolveWorkflowType for backward compat.
// The new function normalises seedType: "smoke" → "smoke", everything else → "default".
// The old function returned seedType as-is (e.g. "feature"), which would fail
// prompt lookup. We intentionally preserve the old signature but delegate.
export { resolveWorkflowName as resolveWorkflowType } from "./workflow-loader.js";
//# sourceMappingURL=workflow-config-loader.js.map