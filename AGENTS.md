READ ./CLAUDE.md

Execution safety rules:
- Before rerunning a task to validate a fix, ensure the fix is durably committed and available on the active branch being tested.
- Treat "implemented" as meaning: relevant tests/build passed and the work has a concrete commit hash on the branch/workspace that will be used for the rerun.
- Do not benchmark or rerun tasks from a dirty or ambiguous controller workspace state.
- If a task reset, branch cleanup, or workspace cleanup is about to happen while important work is only in the working copy, checkpoint it first via commit or patch export.
