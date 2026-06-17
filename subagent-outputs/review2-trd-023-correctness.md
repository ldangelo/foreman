## Review

REJECTED. Did not write output file: no-edit instruction conflicts w/ artifact-write request.

- Correct:
  - Import validates before `execute_import`: `migration_importer.ex:15`, `303-329`.
  - Invalid list items no longer crash: `341-351`; covered by `migration_importer_test.exs:121-125`.
  - String unknown run status rejected: `384-412`; test `127-130`.
  - Duplicate IDs checked per collection: `320-329`, `423-432`; tests `133-149`.
  - Completed retry no duplicate events: `19-21`, `460-473`; test `109-118`.
  - CLI dispatch covered: `import-server.test.ts:63-80`.
  - Failed/blocked runs mapped: `190-220`; test `152-179`.

- Fixed:
  - None. Review-only.

- Blocker:
  - Full pre-validation still incomplete.
  - `phase_order` is used as a list via `List.first(phase_order)` with no validation: `migration_importer.ex:157-158`.
  - `validate_runs/1` only checks `run_id` + `status`: `384-388`.
  - Bad payload like run `%{run_id: "...", status: "completed", phase_order: "bad"}` can crash during `import_runs` after earlier appends in `execute_import`: `35-52`.
  - Violates “invalid input fails before side effects.”

- Fix worth doing now:
  - Validate run optional fields before append:
    - `phase_order` absent or list.
    - `current_phase` absent or binary.
    - `retry_history` absent or list.
  - Add regression test: malformed later run `phase_order: "bad"` leaves `EventStore.all()` unchanged.

- Optional:
  - Failed run without `current_phase` but with `phase_order` loses fallback phase: `append_terminal_run/5` uses raw `Map.get(run, :current_phase)` at `197`, projection then writes nil at `projection_store.ex:309`. Pass computed `current_phase`.

- Commands:
  - `cd packages/foreman_server && mix test test/migration_importer_test.exs` — passed, 8 tests.
  - `npx vitest run src/cli/__tests__/import-server.test.ts --reporter=dot` — passed, 1 test.
  - `git status --short` — clean.