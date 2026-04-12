# Testing Framework

Foreman now uses an explicit **lane-based** test contract so failures are easier to interpret and less likely to send development into unrelated churn.

## Lanes

### `test:unit`
- Fast, in-process tests
- Pure logic, parsing, prompt/template invariants, command behavior with mocks
- No ambient machine assumptions

### `test:integration`
- Deterministic local-state tests
- Real temp repos, SQLite, subprocesses, VCS backends, and command-level integration
- Still no provider/network dependency

### `test:e2e:smoke`
- Deterministic smoke workflow tests
- Exercises real Foreman runtime seams with a scripted phase runner
- Covers happy-path merge behavior and same-file conflict handling

### `test:e2e:full-run`
- Heavier detached runtime validation
- Exercises the true `foreman run` path in explicit test runtime mode
- Separate from PR-facing CI until it stays stable enough for promotion

### `test:system`
- Homebrew, install, packaging, Docker, and other ambient-machine validations
- Not part of default PR gating

### `test:ci`
- The deterministic PR contract
- Runs:
  - `test:unit`
  - `test:integration`
  - `test:e2e:smoke`

## Commands

```bash
npm test
npm run test:unit
npm run test:integration
npm run test:e2e:smoke
npm run test:e2e:full-run
npm run test:e2e
npm run test:system
npm run test:ci
npm run test:all
```

## Reports

Deterministic lanes can emit JSON reports under `.foreman/test-reports/`:

```bash
npm run test:report:unit
npm run test:report:integration
npm run test:report:e2e:smoke
npm run test:report:e2e:full-run
npm run test:report:system
npm run test:report:ci
```

## Runtime test mode

Deterministic end-to-end tests use an explicit runtime seam instead of real provider work:

- `FOREMAN_RUNTIME_MODE=test`
- `FOREMAN_TASK_STORE=native`
- `FOREMAN_PHASE_RUNNER_MODULE=<module path>`

This keeps the real Foreman dispatch / worker / merge flow in play while replacing only the AI phase execution with a deterministic local runner.

## Placement guidance

- Put fast mocked tests in existing `src/**/__tests__/`
- Put deterministic command/runtime integration tests in `src/integration/__tests__/`
- Put detached runtime smoke/full-run coverage in lane-specific e2e files:
  - `*e2e*.test.ts`
  - `*full-run*.test.ts`
- Keep machine-specific validations in `scripts/__tests__/`

## Promotion policy

- PRs must keep `test:ci` green.
- `test:e2e:full-run` remains a separate heavier lane until it proves consistently stable.
- `.github/workflows/e2e-full-run.yml` runs the detached full-run lane on a separate manual/scheduled cadence and uploads its JSON report artifact.
- `.github/workflows/system-tests.yml` keeps the live/system lane opt-in or scheduled, uploads a JSON report artifact, and should not block normal feature delivery.

## Coverage note

The repo constitution still expects unit/integration coverage targets, but this implementation intentionally stops at **lane separation + deterministic reports** because adding a coverage provider would require a new dependency approval. Once approved, coverage enforcement should be layered onto the deterministic lanes rather than the system lane.
