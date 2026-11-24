Phase 2 complete. PLAN.md implemented exactly as written — no deviations.

**Root cause** — `packages/foreman_cli/cmd/foreman/agent_commands.go` had `case "pi", "omp":` setting `RecommendedProjectDir = ".pi/agent/skills"` (a path pi never reads).

**Change**
- `agent_commands.go:471-483` — split the shared case: `case "pi":` now yields `".pi/skills"` via the same `globalDir + "/agent/skills"` expression; `case "omp":` carries the previous pair verbatim, unchanged. Global dir `$HOME/.pi/agent/skills` untouched for both.
- `agent_commands_test.go:127` — `piProjectDir` gained a non-empty constraint plus `assert.Equal(t, ".pi/skills", piProjectDir)`, and a new pi-global `assert.Equal(t, globalDir+"/agent/skills", …)`.
- `docs/user-guide.md:2058` — project path → `.pi/skills`, global `$HOME/.pi/agent/skills` kept.

**Failing check, red first:** `go test ./cmd/foreman/ -run TestRenderAgentSupportStates -v` → `FAIL: want .pi/skills, got .pi/agent/skills`. After the edit → `PASS (0.291s)`.

Full package green: `ok foreman/cli/cmd/foreman 0.547s` / `0.595s`, and `-count=1 -shuffle=on` `ok 0.573s`. `gofmt -l cmd` empty, `go vet ./cmd/foreman/` rc 0, `go build ./...` rc 0.

**Documentation gate** — all four files grepped. Only `docs/user-guide.md` needed an edit. `CLAUDE.md`: no `commands install` or skill-dir references. `README.md`: generic install only (:18/:39/:137/:140/:151/:214), no skill paths. `docs/cli-reference.md:558`: global dir only, correct as-is. Related identifier `omp` rechecked — its docs hit is the unrelated Beads `om`→`omp` rename.

**Two findings left alone (out of scope, flagged in the report):** `docs/cli-reference.md:1271` and `:1335` still document the pre-rename `ompskills`/`ompsync` tool names. Same class as PLAN §6's stale `:393` zsh claim, which the plan explicitly declined to touch.

Note: PLAN §5 predicted the added global-dir assertion would also fail before the code edit. It does not — that expression already produced the correct global value, so only the project assertion is red. Assertion kept per the plan.

`git status`: 3 modified files + `docs/reports/foreman-kaa9w-fix/FIX_REPORT.md` (6789 bytes, all six `fix.md` headings), all uncommitted for Foreman. `PLAN.md` byte-identical to HEAD `f13f9745`, which `merge-base --is-ancestor` confirms already contains `origin/main` tip `0f4e38cb` — no rebase was due.

Status tools `foreman_inbox_send`/`foreman_task_add_comment` remain unexposed in this phase.