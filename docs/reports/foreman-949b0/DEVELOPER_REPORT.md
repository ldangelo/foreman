# Developer Report: Canary: exercise PR review workflow phases

## Approach
Added a single sentence to `README.md` (after the "5. **Finalize**" bullet) documenting that Foreman runs explicit PR review phases (`create-pr` → `pr-wait` → `prepare-pr-review` → `pr-review`) before refinery merges. This is the only docs file requiring change — the pipeline infrastructure (builtins, workflow YAML, prompts) is already fully implemented.

## Files Changed
- `README.md` — added one sentence describing the post-Finalize PR review phases, consistent with existing docs style at lines 67–72.

## Tests Added/Modified
- None — this is a docs-only change with no source code modifications.

## Decisions & Trade-offs
- Chose prose sentence format over bullet point to integrate naturally with the adjacent "Dev ↔ QA retries" note.
- No source code touched; the EXPLORER_REPORT.md confirmed all pipeline infrastructure was already in place in YAML and TypeScript.

## Known Limitations
- None — the change is minimal and targeted; the pipeline will exercise the full phase sequence and produce all four required artifacts.