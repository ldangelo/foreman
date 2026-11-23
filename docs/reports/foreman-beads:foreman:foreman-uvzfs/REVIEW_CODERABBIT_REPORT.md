Phase complete.

**Review engine** — `coderabbit review --agent --base "$FOREMAN_BASE_BRANCH"` (`FOREMAN_BASE_BRANCH=main`). Round 1 died on a transport error (`TRPCWebSocketClosedError`, 0 findings); rounds 2–3 completed, 1 finding each.

**Fixed (major, `packages/foreman_server/priv/defaults/workflows/fix.yaml:35`)** — the branch had replaced main's prompt-driven workflow with two `command:` phases, incl. `command: "/enseble:merge-pr --foreman"`: typo namespace, no such command (ensemble registers `pr-merge`), an agent-run merge against the operator-only merge gate, and it dropped the plan/coderabbit-review/repo-rules-review phases — which is why phase 1 wrote `Blocked: no plan found`. Restored main's `fix.yaml` + `prompts/fix.md` + `prompts/fix-plan.md`, fixed the 4 stale workflow test expectations, restored the `docs/user-guide.md` §7.3 model-pin paragraph, ran `foreman init --force`. Typo-only repair rejected: it points at `/ensemble:pr-merge`, i.e. an agent merge.

**Declined (major, `packages/foreman_server/priv/defaults/workflows/prompts/fix.md:22`)** — "create the planned regression test before running it": byte-identical to upstream `main` (`git diff main -- …prompts/fix.md` empty ⇒ pre-existing), prompt semantics outside this run's PR-title/body scope, ships to every operator via `foreman init --force`. Still reported unresolved to you.

**Verification** — workflow suite `1564 passed` exit 0 (before: 1561/1564); `mix format --check-formatted` exit 0; `foreman init --force` exit 0; `diff -rq ~/.foreman/workflows packages/foreman_server/priv/defaults/workflows` clean; `git diff main -- packages/foreman_server/priv/defaults/workflows/` empty. Report's findings + risk blocks re-parsed with `ReviewFindings.read/1` and `PrRisk.parse_judgement/1` → `:recorded`, level `MEDIUM`.

Docs gate: only `docs/user-guide.md` needed an edit; `CLAUDE.md`, `README.md`, `docs/cli-reference.md` none — no route, CLI verb, MCP tool, env var or config key changed.

Remaining, not mine to decide: the run's actual task (PR title/body generation) is still unimplemented — phase 1 never produced a plan. Branch work left uncommitted for Foreman; kata `eaf5` opened and closed with the test as evidence.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/priv/defaults/workflows/fix.yaml", "line": 35, "description": "The bundled fix workflow ran the non-existent command \"/enseble:merge-pr --foreman\", a typo of the ensemble namespace, in a phase that also dropped the plan and review phases; restored main's prompt-driven fix workflow with its plan, fix, coderabbit-review and repo-rules-review phases.", "disposition": "fixed", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/priv/defaults/workflows/prompts/fix.md", "line": 22, "description": "The bundled fix prompt tells the agent to run the plan's failing check before the new regression test exists; declined as pre-existing upstream main content and outside this run's task scope.", "disposition": "declined", "source": "coderabbit"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "MEDIUM", "rationale": "The phase's only code change restores upstream main's prompt-driven bundled fix workflow (plus its two prompts, the matching test expectations and the user-guide paragraph documenting the two model pins), so the branch no longer diverges from main on bundled workflow content and the repository's own workflow suite passes 1564/1564. The residual risk is that one major CodeRabbit finding on upstream's bundled fix.md prompt was declined as pre-existing and remains unresolved, and the run's actual PR title/body task was never implemented because phase 1 blocked on a missing PLAN.md."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
