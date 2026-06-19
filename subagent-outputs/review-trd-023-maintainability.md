## Review

- Correct:
  - Migration command wired through server API: `command_router.ex:14`, `:65-74`, `:253-258`; HTTP accepts `"MigrationImportCommand"` / `"migration.import"` at `router.ex:308-317`.
  - Completed import retry returns existing result: `migration_importer.ex:22-24`, `:330-343`.
  - Legacy delegation avoids shell injection: `legacy-coexistence.ts:76` uses `spawn(bin, argv, ...)`; recursion guard at `:71-74`.
  - Docs updated: `README.md:549-556`, `docs/cli-reference.md:580-606`, `docs/user-guide.md:109-125`.
  - Tests pass:
    - `cd packages/foreman_server && mix test test/migration_importer_test.exs` → 4 pass.
    - `npx vitest run src/cli/__tests__/legacy-coexistence.test.ts --reporter=dot` → 5 pass.
  - No unsafe atom growth found. `String.to_atom` uses fixed internal `record_type` path only: `migration_importer.ex:254-261`.

- Fixed:
  - None. Review-only/no-edit. Did not write requested output file because “No edits” conflicts with artifact-writing.

- Blocker:
  - Import is not atomic/idempotent on mid-payload validation failure.
    - Starts appending before validating all records: `migration_importer.ex:38-56`.
    - Stops on first later error after prior side effects: `migration_importer.ex:309-316`.
    - Retry only short-circuits completed imports: `migration_importer.ex:22-24`.
    - Same migration id then hits duplicate idempotency key: `event_store.ex:108-118`.
    - Docs advertise idempotent retries via `--command-id`: `docs/cli-reference.md:595`.
    - Fix now: pre-validate full payload incl shape, ids, enum values, dupes before first append; or write failed marker + resumable skip semantics.

- Note:
  - Invalid list items can crash instead of returning validation error. `require_list` checks only list type (`migration_importer.ex:351-355`); `normalize(other)` returns non-map (`:368`); then `Map.get(project, ...)` is called (`:102-104`). Fix w/ per-record map validation.
  - Unknown run status silently becomes completed: `migration_importer.ex:217-224`. Validate/map statuses.
  - Duplicate/colliding IDs are not pre-deduped. Appends omit expected stream version (`migration_importer.ex:320-327`); projections overwrite by id (`projection_store.ex:175-185`, `:196-216`).
  - CLI payload read is minimal: `import.ts:63-64` reads/parses arbitrary file as full JSON, no schema/size check. Server-side validation is the must-fix.
  - `foreman import` is documented but hidden in help: `index.ts:108`. OK if intentional; otherwise contract/docs mismatch.
  - Docs lack concrete JSON schema/sample and partial-failure behavior.

Commands run:
- `git status --short`
- `git log --oneline -n 8`
- `git show --stat --oneline bdda5936`
- `git show --stat --oneline d71cdb7b`
- `git diff --name-only bdda5936^..HEAD`
- `cd packages/foreman_server && mix test test/migration_importer_test.exs`
- `npx vitest run src/cli/__tests__/legacy-coexistence.test.ts --reporter=dot`