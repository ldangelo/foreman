Advisor unusable again (Anthropic OAuth `invalid_grant` / refresh token expired — same as noted in memory). Proceeding without it.

Plan written. No code touched, nothing committed.

**Artifact:** `docs/reports/foreman-beads:foreman:foreman-d6rth/PLAN.md` (153 lines, under the 200-line cap)

## Verdict: premise is mostly stale

Task was written against run `run-a9ee2749`, whose branch implemented none of the four behaviours. Those landed later on `main` (#957/#959/#961). On current HEAD `39303e89`:

| Task claim | Reality |
|---|---|
| PR title rule undocumented | **Already documented** — `docs/user-guide.md:2966-2971`, `docs/cli-reference.md:622`; matches `phase_pr.ex` `pr_title/1` (:368-371) |
| `## PR body` convention | **Does not exist** — `git grep -- "## PR body"` → nothing. No prompt writes it, no reader parses it |
| `pr_body_template` project setting | **Does not exist** — `git grep pr_body_template` → nothing; `settings.ex` `@keys` (:48-51) has no such key |
| absolute-path rule | **Half documented** — review-report path rule at `:2996-2999`; the generated-body `Artifact:` line (`PrBodyPath.artifact_line/2`, :81-90) is in **no** gate file |

## Plan content

- **One edit**: a single paragraph in `docs/user-guide.md`, inserted between lines 3008 and 3010 (after the review-findings paragraph, before `**Marker lines.**`), documenting that a generated PR body's `Artifact:` line is repo-relative and is *omitted* rather than made absolute.
- **Explicit refusal** to document items 2 and 3 — writing docs for a setting that does not exist is a worse defect than the one being fixed. Named in "Out of scope" so the implementer doesn't follow the task prose instead.
- Doc gate statement included: no externally visible identifier added/removed/renamed; `CLAUDE.md:1216`, `README.md:288`, `docs/cli-reference.md:622` already carry their counterparts, so no edits there.
- Premise re-check commands at the head of section 3: if any of the three greps now hits, the implementer stops and reports instead of editing.
- Verification: `docs_test.exs` + Go `TestUserGuide|TestUsageDrift`; success = exactly one changed file, ~+12/-0. No `mix format` (no `.ex`/`.exs`).

Kata issue `ancq` created, claimed-state audit recorded as a comment, left open for the implement phase.