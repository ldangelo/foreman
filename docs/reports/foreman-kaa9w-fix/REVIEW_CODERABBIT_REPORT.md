Phase 3 done.

**Result: 0 findings, no fixes needed.**

Rounds (all exit 0, `review_completed`):
1. `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` (base=`main`, stale local ref) → 0 findings, 5 files reviewed
2. `--base 0f4e38cb` (exact merge base of the run) → 0 findings, same 5 files
3. `--base "$FOREMAN_BASE_BRANCH" --committed` → 0 findings, same 5 files

**Engine-sanity probe** (not a product round): reverted pi's `RecommendedProjectDir` to `.pi/agent/skills` → engine emitted exactly one **major** finding at `packages/foreman_cli/cmd/foreman/agent_commands.go:475` ("Use the Pi project skills directory"). So the zero-finding result is a genuine clean review, not a silent no-op. Probe reverted; tree byte-identical to HEAD (`git diff` empty).

Verification (from `packages/foreman_cli`): `go test ./cmd/foreman/...` ok 0.505s · `gofmt -l cmd` empty · `go vet ./...` ok · `go build ./...` ok. Task's VERIFY command run verbatim → exit 0.

Report: `docs/reports/foreman-kaa9w-fix/REVIEW_CODERABBIT_REPORT.md` (6039 B, untracked — Foreman commits). Findings block `reviewed: true, findings: []`; risk block `LOW`. Both JSON-validated, single marker occurrence each, no marker text inside fences.

Notes:
- Two stale out-of-scope doc refs recorded as operator notes only, not findings: `docs/cli-reference.md:1271` and `:1335` (`ompskills`/`ompsync`, pre-rename Beads names).
- `foreman_inbox_send` sent; `foreman_task_add_comment` failed ("Task external_id is malformed") — logged in the report.
- `ask_advisor` unusable again (Anthropic oauth 400 `invalid_grant`, refresh token expired) — operator needs re-auth.
- Kata issue `hw4f` created, claimed, closed.