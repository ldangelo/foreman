# Developer Report: Health monitoring: doctor command with auto-fix

## Approach

The implementation follows the Explorer's recommended phased approach:

1. **Created `Doctor` class** (`src/orchestrator/doctor.ts`) — extracted all health check logic from the CLI into a reusable, testable class following the same pattern as `Monitor`. Each check is a public method returning `CheckResult[]`.
2. **Refactored CLI command** (`src/cli/commands/doctor.ts`) — slimmed down to a thin wrapper that constructs a `Doctor` instance and formats its output.
3. **Added new health check** — `checkRunStateConsistency()` detects runs with `completed_at` set but still in `running`/`pending` status (impossible state), with auto-fix support.
4. **Added `--dry-run` flag** — shows what `--fix` would change without making any modifications; consistent with the pattern in `reset.ts`.
5. **Added `CheckStatus`, `CheckResult`, `DoctorReport` types** to `src/orchestrator/types.ts` for shared typing between orchestrator and CLI layers.

## Files Changed

- `src/orchestrator/types.ts` — Added `CheckStatus` ("pass" | "warn" | "fail" | "fixed" | "skip"), `CheckResult`, and `DoctorReport` types at the end of the file.
- `src/orchestrator/doctor.ts` — New `Doctor` class with public methods: `checkSystem()`, `checkSdBinary()`, `checkGitBinary()`, `checkRepository()`, `checkDatabaseFile()`, `checkProjectRegistered()`, `checkSeedsInitialized()`, `checkDataIntegrity()`, `checkOrphanedWorktrees()`, `checkZombieRuns()`, `checkStalePendingRuns()`, `checkFailedStuckRuns()`, `checkRunStateConsistency()` (new), `checkBlockedSeeds()`, and `runAll()`. All data-mutating checks accept `{ fix?, dryRun? }` options.
- `src/cli/commands/doctor.ts` — Replaced 609-line monolith with ~120-line thin CLI wrapper using `Doctor` class. Added `--dry-run` flag. Added `"skip"` status to icon/label helpers.

## Tests Added/Modified

- `src/orchestrator/__tests__/doctor.test.ts` — **18 new unit tests** covering:
  - `checkGitBinary`: basic availability check
  - `checkProjectRegistered`: pass/fail cases
  - `checkZombieRuns`: no runs, no project, zombie detection, `--fix` repair, `--dry-run` preview
  - `checkStalePendingRuns`: no stale, stale detection, `--fix` repair
  - `checkRunStateConsistency`: consistent state, inconsistent detection, `--fix` repair, no project
  - `checkFailedStuckRuns`: no failures, failed runs warning
  - `runAll`: verifies report structure has all required sections and summary fields
- `src/cli/__tests__/commands.test.ts` — Added 2 smoke tests: `doctor --help` shows flags, `doctor --json` exits 1 outside a git repo.

## Decisions & Trade-offs

- **Doctor class in orchestrator layer**: Follows the same separation of concerns as `Monitor` — the orchestrator layer owns the health-check logic, the CLI layer handles formatting and user interaction.
- **`dryRun` vs `fix` precedence**: `dryRun` takes priority over `fix` in all checks; if both are passed, dry-run wins (safe default).
- **New `checkRunStateConsistency` check**: Detects the impossible state of a run having `completed_at` set while still in `pending`/`running` status. Auto-fix marks such runs as `failed` (conservative).
- **`--dry-run` flag**: Added per Explorer recommendation and consistent with `reset.ts` pattern. Shows actionable messages without side effects.
- **`CheckStatus` adds `"skip"` value**: For future use where a check is bypassed due to missing prerequisites (e.g., no project registered). Icon/label helpers handle it as dim dash.
- **`runAll()` runs all three check groups in parallel** with `Promise.all` for performance; individual sub-checks within `checkDataIntegrity` also run in parallel.

## Known Limitations

- `checkSdBinary` and `checkBlockedSeeds` use hardcoded `~/.bun/bin/sd` path — inherited from original; no change made.
- `checkOrphanedWorktrees` is not covered in unit tests (requires mocking `listWorktrees` from `lib/git.ts`); the existing behavior was preserved from the original doctor command without regressions.
- The `checkSeedsInitialized` method uses `existsSync` synchronously (inherited pattern); could be made async in a future cleanup.
- No integration test with a real SQLite database and git worktree — CLI smoke tests cover surface-level behavior only.
