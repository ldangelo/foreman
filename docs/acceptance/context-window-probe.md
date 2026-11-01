# Context window of a gateway model in the claude CLI: zero-spend probe and the prepared live run, 2026-10-31

Bead `foreman-gppjx` (hypothesis from `foreman-c3ke`: the claude CLI assumes a 200k-token window for `Minimax-M3`, declared 512000 in
LiteLLM). **Verdict when this was written (2026-10-31): PARTIAL, the >200k-token run through the proxy was NOT run** (it needed the owner's approval, a proxy this host could not reach, and
spend). **It was run on 2026-11-01: PASS on the bead's own acceptance, see [`context-window-live-run.md`](context-window-live-run.md)** (16 requests up to 252542 tokens, 5 above 200000, no
compaction, the variable in the project environment). This document holds the free half (the CLI measured against a stand-in gateway, and code reading) and the plan the live run followed.

Harness: `scripts/e2e/context_window_probe.sh` with `scripts/e2e/context_window_probe/fake_anthropic.py`. The real `claude` 2.1.308 (the version the
agent Dockerfile pins) is pointed at a stand-in on `127.0.0.1` (`ANTHROPIC_BASE_URL`, a fake API key, an empty private HOME: no login, no keychain). The stand-in
answers every request with a tiny streamed reply and CLAIMS a chosen number of input tokens in the reply's `usage` (what the CLI uses to decide when to
auto-compact), and logs each request, flagging compaction (summarisation) requests. No provider is contacted; nothing is spent.
Run: `devbox run -- bash scripts/e2e/context_window_probe.sh`.

## Result

`passed=10 failed=0 unverified=0 wall=4s` (one run; it measures the CLI, not Foreman). Re-run on 2026-11-01 with claude 2.1.309, the host's CLI at the time of the live run: `passed=10 failed=0 unverified=0 wall=3s`, the same table.

| Model name sent | `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | window the CLI reports | claimed context of turn 1 | turn 2 of the same session |
|---|---|---|---|---|
| `Minimax-M3` | unset | 200000 | 175000 | 1 request, no compaction |
| `Minimax-M3` | unset | 200000 | 177000 | **compaction request first**, then the turn (2 requests) |
| `Minimax-M3` | unset | 200000 | 190000 | **compaction request first**, then the turn |
| `Minimax-M3` | `512000` | 512000 | 190000 | 1 request, no compaction |
| `Minimax-M3` | `512000` | 512000 | 480000 | 1 request, no compaction |
| `Minimax-M3` | `512000` | 512000 | 490000 | **compaction request first**, then the turn |

So for an unrecognised model name 2.1.308 auto-compacts at about 176k claimed tokens (between 175000 and 177000) although the model's real window is 512000
(the "premature auto-compaction at ~200k on a 512k model" the bead names), and `CLAUDE_CODE_MAX_CONTEXT_TOKENS=512000` moves that to about 488k
(between 480000 and 490000): both thresholds sit 24000 below the window the CLI believes in. The CLI prints its `unrecognized_model` diagnostic in both
cases (with the variable set too). The unset-variable behaviour is also the window the bead quotes from the CLI's own message.

Also read, not exercised: the 2.1.308 binary's embedded script mentions `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`,
`DISABLE_AUTO_COMPACT`, `DISABLE_COMPACT` and `CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT` (the switch the bead's changelog excerpt names); only
`CLAUDE_CODE_MAX_CONTEXT_TOKENS` was tried.

## What this does not show

- That a real model behind the real proxy accepts and answers requests above 200k tokens through a Foreman run, the bead's own acceptance: DONE 2026-11-01
  (`context-window-live-run.md`: 16 requests up to 252542 tokens, 5 of them above 200000, all HTTP success, no compaction). The bead's
  2026-10-27 probes (8 direct `/v1/messages` calls from 13k to 611k input tokens all HTTP 200; one ~1.3 MB prompt and four chained `--resume` turns
  succeeded) were not repeated, and the live run is capped near 300k tokens by design.
- That Foreman delivers the variable to the claude process: read from the code, then OBSERVED on 2026-11-01 (the recorder in front of the CLI saw it in the CLI's environment and the
  CLI's own result record said `contextWindow` 512000, against 200000 without it). By code reading (a scout agent, spot-checked): the project environment
  (`project env set`, any name except `FOREMAN_*`) is merged into the phase's `env_map`, which `JidoHarnessWorker.init/1` copies into the harness
  driver options and the claude adapter passes to the CLI; for jobsites `agent.env` names must be in `FOREMAN_JOBSITES_AGENT_ENV_ALLOWLIST` (a jobsite was not run).
  `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is not secret-looking (`ProjectEnvironment.secret_name?/1` needs `token` followed by `_` or the end of the name), so it can be set
  as a plain variable. `docs/user-guide.md` already documents that route.
- The bead's literal ask, a per-model window declared in config and exported to the worker env: nothing in Foreman does that today (no store of
  windows; Foreman never reads or sets the variable), so the only channel is the project environment. That is a design decision for the owner.
- The first half of the bead is done: the agent image pins the CLI (`CLAUDE_CODE_VERSION=2.1.308` in the shared Dockerfile template).

## Prepared live run (the plan of 2026-10-31; RUN on 2026-11-01, see the note)

Run on 2026-11-01 as `scripts/e2e/context_window_live.sh` (`context-window-live-run.md`: PASS on the bead's acceptance). Where the run differs from the plan below: the proxy WAS reachable (an
owner-staged URL and key, `CW_LITELLM_FILE`); the ballast is ADAPTIVE (80 KB parts of about 18.5k tokens each by the proxy's count, added while the agent reads and none after the first request
above 200000 was seen, so run B stopped at 252542 tokens after 14 reads, not after 16 files); run A was a 2-part canary, not a no-variable control of the full corpus (that control is the
script's optional run C, which was not run); the key reached the agent as a project secret (stdin) and the variable as a plain project variable, as planned. Of the mechanical preconditions
below, (a), (b), (d) and (f) were exercised and their `[INFERENCE]` items answered (see "The mechanical `[INFERENCE]` items" in the live-run document); (c) and (e) concern docker jobsites and were not.

Needs (as planned): a LiteLLM proxy URL reachable from this host serving `Minimax-M3` (on 2026-10-31 none was: `pi --list-models` showed only the `ornith`, `qwen`,
`qwen38` and `smart_router` litellm routes; the owner then staged one), a key for it, and the owner's go-ahead for the spend below (given).

1. A scratch project (the `claude_projects/lib.sh` harness, as in `question_answer_boundary.sh`) whose repository holds `ballast/` with 16 files of
   60 KB of text (about 15k tokens each by the CLI's bytes/4 rule, 22k by a pessimistic count).
2. Project environment: `foreman project env set <id> ANTHROPIC_BASE_URL=<proxy>` and `... CLAUDE_CODE_MAX_CONTEXT_TOKENS=512000`; the key through
   `foreman project secret set <id> ANTHROPIC_API_KEY` (stdin; never in a flag or a log). A workflow with `provider: claude` and `models.default: Minimax-M3`
   installed for the scratch project: there is no bundled one and no `claudeedit.yaml` in `priv/defaults/workflows/` (see "Mechanical preconditions", a).
3. Run B (the acceptance): the prompt asks the agent to read every `ballast/` file, one per call, then answer `done`. The context passes 200k after the 14th to the 16th read.
   Observe in the claude session file: input tokens per request above 200000, no compaction summary, the run completes.
4. Run A (control, optional): the same without the variable: compaction expected near 176k.

### Mechanical preconditions (read from the tree 2026-11-01, before the run; see the note above for what the run exercised)

Each item cites the file and line that was read; anything not verifiable from the tree is marked `[INFERENCE]`.

a. **The workflow.** `priv/defaults/workflows/` holds `assess`, `fix`, `implement-trd-beads`, `implement-trd`, `prd` and `review` (`ls`), no claude-provider
   workflow that fits. `claudeedit.yaml` exists only as an acceptance asset: `scripts/e2e/claude_projects/workflows/claudeedit.yaml` and
   `scripts/e2e/live_claude/workflows/claudeedit.yaml` (`git ls-files`), with `models.default: haiku`. The first one (read in full) is the minimal
   shape: `name`, `description`, `task_types: [claude-e2e]`, `worktree: {enabled: true, branch: foreman/{task_id}/{run_id}, path: workspace, cleanup: on_success}` and
   one phase `{name: edit, prompt: edit.md, provider: claude, approval_mode: auto_approve, models: {default: haiku}, commit: true}`. For the probe copy it under a new
   name and task type, set `models.default: Minimax-M3`, and put its prompt file at `prompts/edit.md` beside it (the harness copies
   `scripts/e2e/claude_projects/workflows/prompts/edit.md`, `lib.sh:449-452`). The directory is the server's workflow root: `~/.foreman/workflows` by default,
   `config :foreman_server, :workflow_root` to move it (`docs/user-guide.md:45-53`); the harness sets it per run (`claude_projects/boot.exs:21`), and its own
   comment says a newly added workflow "takes a server (re)start to be seen" (`lib.sh:491`). The run is then submitted by name:
   `foreman run submit --project-id <id> --workflow <name> --work-id <task>` (as `fork_live.sh:212` does for `claudeedit` through the harness's `fm`). The model string reaches the CLI as its
   `--model`/model option verbatim (`run_executor.ex:4274-4276` puts `:model` into the driver options; the CLI side is `[INFERENCE]`).
b. **The proxy route.** The proxy must serve the alias spelled exactly as `models.default` (`Minimax-M3`, the default of `CW_MODEL` in
   `scripts/e2e/context_window_probe.sh:24`) and the route must really accept 512000 tokens of input. A differently named route is a different model name to
   the CLI: the table above shows it assumes 200000 for a name it does not recognise, and `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is the only lever that was
   measured. `[INFERENCE]` The variable carries no model name, so it applies to whatever name the phase passes.
c. **Which address.** A workflow run is NOT containerised: its agent runs on the server host ("workflow runs (agents on the server host)",
   `docs/user-guide.md:839`; `workflow/run_executor.ex` has no docker or sandbox reference, `grep -ni 'docker\|sandbox'`: no hit), so `ANTHROPIC_BASE_URL` is whatever
   the server host can reach, `127.0.0.1` included. `host.docker.internal:<port>` is the form only for an agent inside a docker jobsite sandbox
   (`scripts/e2e/network_policy/probe.sh:8,14`; `scripts/e2e/network_policy_flow.sh:77` `ALLOWED_HOST=host.docker.internal`; the target is reached from the
   container as that name). Run B as written in step 3 is a workflow run, so this precondition does not apply to it; it would to a jobsite variant.
d. **How the variables reach the claude process.**
   - A workflow phase: `RunExecutor.prepare_agent_launch` resolves the project environment once (`run_executor.ex:1347`, `ProjectEnvironment.resolve/2`), merges
     it under the `FOREMAN_*` values (`run_executor.ex:1506-1514`) and passes it as `env_map` (`:1546`). `ProjectEnvironment.resolve_parts` builds that env as the
     project's plain variables overlaid by the secret-store values (`project_environment.ex:56-66`). `JidoHarnessWorker.init/1` calls `put_env/2`
     (`overwatch/adapters/jido_harness_worker.ex:57`), which puts a non-empty `env_map` into the driver options as `:env` (`:96-105`), where it overlays the
     ambient environment (`:88-91`). No allowlist is involved in this door: `FOREMAN_JOBSITES_AGENT_ENV_ALLOWLIST` is read only for a jobsite spec's
     `agent.env` (`jobsite/spec.ex:398-420`, config `config/runtime.exs:63-70`).
   - A jobsite: the project environment and secrets are the base, and the spec's own `agent.env` overrides it (`docs/user-guide.md:837`); only names in
     `agent.env` must be in the allowlist (`jobsite/spec.ex:404-413`, error `spec_env_not_allowed`). A docker sandbox otherwise sees none of the operator's own
     variables (`jobsite/template/script.ex:146-148`). So the project env route needs no allowlist on either door.
   - `CLAUDE_CODE_MAX_CONTEXT_TOKENS` and `ANTHROPIC_BASE_URL`: plain `foreman project env set`. Neither name matches the secret-name pattern
     (`aggregates/project/environment.ex:38`: `token` must be followed by `_` or the end of the name, and `TOKENS` is not; `BASE_URL` is no listed word), and a
     secret-looking name is refused in `env set` with `secret_in_vars` (`docs/user-guide.md:835`).
   - `ANTHROPIC_API_KEY`: only `foreman project secret set <id> ANTHROPIC_API_KEY` (`API_KEY` matches the pattern, so `env set` would refuse it), the value on
     stdin from the staged file (`foreman project secret set <id> ANTHROPIC_API_KEY < <file>`, one value per file; never a flag, never a `printf` of the value in a
     command line). Delivered to the agent as an environment variable and redacted from logs (`docs/user-guide.md:836`).
   - `foreman project secret set` trims one trailing newline (`docs/cli-reference.md:405`); the live harness sent the value without one.
e. **Network policy.** `foreman project network set --mode allowlist --allow <host>` is enforced on docker jobsites only; workflow runs do not enforce it
   (`docs/user-guide.md:839`). For a jobsite variant the proxy host must be in `--allow` (the form is `--mode allowlist --allow host.docker.internal`,
   `network_policy_flow.sh:25`); that the proxy is not among the "always-allowed provider/VCS hosts" is `[INFERENCE]` (the list was not read). `none` blocks it.
f. **Where the observation lives.** The claude session file: `$HOME/.claude/projects/**/*.jsonl` of the HOME the server runs under (the acceptance
   harness redirects it to `$WORK/home`, `claude_projects/lib.sh:457-467`, and lists the files with `claude_session_files`, `claude_home.sh:43-47`). Read the
   `usage.input_tokens` of each request there (above 200000, and no compaction summary entry). Foreman's own log has no per-request token counts
   (`[INFERENCE]`: stated by the bead, not re-checked). Evidence that the variable reached the worker: (1) Foreman exporting it proves only that Foreman computed
   the map; `JidoHarnessWorker.init/1` shows the map becomes the driver's `:env` (above), so concluding the variable is ineffective from Foreman's side needs more
   than its absence in a log; (2) while run B is in flight, the claude process's environment names (`ps eww -p <pid>`, filter to
   `CLAUDE_CODE_MAX_CONTEXT_TOKENS=` only; never print the whole line, the key is in it; `[INFERENCE]` that `ps eww` shows it on this host); (3) the behaviour:
   run A (variable unset) compacts near 176k and run B does not, as the zero-spend probe measured against the stand-in. Whether the adapter hands `:env` on to the
   CLI: OBSERVED 2026-11-01 with a recorder wrapper in front of the CLI (not `ps eww`): it saw the variable in the CLI's environment (`context-window-live-run.md`).
g. **Credentials.** Staged by the owner in a `chmod 600` file under `/Users/ldangelo/.omp/foreman-ledger/`, values only. Never paste a value into chat, a
   command line, a log or a committed evidence file; record only names, versions (`foreman project secret list`) and the redaction check.

Estimate (these steps were not rehearsed through Foreman: `[INFERENCE]`). Each tool turn re-sends the whole context, so one run processes
about 15k x (1 + 2 + ... + 16) = 2.0M input tokens (3.0M at 22k per file) when nothing is cached; run A is cheaper (compaction near the 12th read) at about 1.2M to 1.8M
plus a summary of up to 20k output tokens. Run B alone: 2.0M to 3.0M input, under 30k output. Both runs: about 3.2M to 4.8M input. At the proxy
config's price entry for `Minimax-M3` ($0.30 per million input, $0.12 per million output; the file itself calls its numbers ILLUSTRATIVE, they are not a bill) that is
**about $0.6 to $0.9 for run B and $1.0 to $1.5 for both**; if the provider caches prefixes (the config declares `supports_prompt_caching`) it is lower. A
2x price would still be under $3. Wall time: tens of minutes (about 16 to 40 sequential model calls per run).

Actual (2026-11-01, `context-window-live-run.md`): run B processed 2354625 input-side tokens (inside the 2.0M to 3.0M estimate): 0.26 USD by the proxy's price table with its cache-read
price, 0.71 USD at 0.30 per million with no cache discount; runs A and B together 2493827 prompt tokens, 0.28 USD by the proxy's table (0.75 USD without a cache discount). Wall time: 212 s for
run B (16 sequential model calls).
