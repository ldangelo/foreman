# Context window of a gateway model in the claude CLI: zero-spend probe and the prepared live run, 2026-10-31

Bead `foreman-gppjx` (hypothesis from `foreman-c3ke`: the claude CLI assumes a 200k-token window for `Minimax-M3`, declared 512000 in
LiteLLM). **Verdict: PARTIAL. The >200k-token run through the proxy was NOT run** (it needs the owner's approval, a proxy this host cannot reach, and
spend: see "Prepared live run"). What was done is free: the CLI's behaviour measured against a stand-in gateway, and code reading.

Harness: `scripts/e2e/context_window_probe.sh` with `scripts/e2e/context_window_probe/fake_anthropic.py`. The real `claude` 2.1.308 (the version the
agent Dockerfile pins) is pointed at a stand-in on `127.0.0.1` (`ANTHROPIC_BASE_URL`, a fake API key, an empty private HOME: no login, no keychain). The stand-in
answers every request with a tiny streamed reply and CLAIMS a chosen number of input tokens in the reply's `usage` (what the CLI uses to decide when to
auto-compact), and logs each request, flagging compaction (summarisation) requests. No provider is contacted; nothing is spent.
Run: `devbox run -- bash scripts/e2e/context_window_probe.sh`.

## Result

`passed=10 failed=0 unverified=0 wall=4s` (one run; it measures the CLI, not Foreman).

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

- That a real model behind the real proxy accepts and answers requests above 200k tokens through a Foreman run: the bead's own acceptance. The bead's
  2026-10-27 probes (8 direct `/v1/messages` calls from 13k to 611k input tokens all HTTP 200; one ~1.3 MB prompt and four chained `--resume` turns
  succeeded) were not repeated.
- That Foreman delivers the variable to the claude process. By code reading (a scout agent, spot-checked, not run): the project environment
  (`project env set`, any name except `FOREMAN_*`) is merged into the phase's `env_map`, which `JidoHarnessWorker.init/1` copies into the harness
  driver options and the claude adapter passes to the CLI; for jobsites `agent.env` names must be in `FOREMAN_JOBSITES_AGENT_ENV_ALLOWLIST`.
  `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is not secret-looking (`ProjectEnvironment.secret_name?/1` needs `token` followed by `_` or the end of the name), so it can be set
  as a plain variable. `docs/user-guide.md` already documents that route. A run through a stand-in gateway (zero spend) was not built.
- The bead's literal ask, a per-model window declared in config and exported to the worker env: nothing in Foreman does that today (no store of
  windows; Foreman never reads or sets the variable), so the only channel is the project environment. That is a design decision for the owner.
- The first half of the bead is done: the agent image pins the CLI (`CLAUDE_CODE_VERSION=2.1.308` in the shared Dockerfile template).

## Prepared live run (NOT run; needs approval)

Needs: a LiteLLM proxy URL reachable from this host serving `Minimax-M3` (this host cannot reach one: `pi --list-models` shows only the `ornith`, `qwen`,
`qwen38` and `smart_router` litellm routes), a key for it, and the owner's go-ahead for the spend below.

1. A scratch project (the `claude_projects/lib.sh` harness, as in `question_answer_boundary.sh`) whose repository holds `ballast/` with 16 files of
   60 KB of text (about 15k tokens each by the CLI's bytes/4 rule, 22k by a pessimistic count).
2. Project environment: `foreman project env set <id> ANTHROPIC_BASE_URL=<proxy>` and `... CLAUDE_CODE_MAX_CONTEXT_TOKENS=512000`; the key through
   `foreman project secret set <id> ANTHROPIC_API_KEY` (stdin; never in a flag or a log). A workflow with `provider: claude` and `models.default: Minimax-M3`
   (like `claudeedit.yaml`, whose model is `haiku`).
3. Run B (the acceptance): the prompt asks the agent to read every `ballast/` file, one per call, then answer `done`. The context passes 200k after the 14th to the 16th read.
   Observe in the claude session file: input tokens per request above 200000, no compaction summary, the run completes.
4. Run A (control, optional): the same without the variable: compaction expected near 176k.

Estimate (these steps were not rehearsed through Foreman: `[INFERENCE]`). Each tool turn re-sends the whole context, so one run processes
about 15k x (1 + 2 + ... + 16) = 2.0M input tokens (3.0M at 22k per file) when nothing is cached; run A is cheaper (compaction near the 12th read) at about 1.2M to 1.8M
plus a summary of up to 20k output tokens. Run B alone: 2.0M to 3.0M input, under 30k output. Both runs: about 3.2M to 4.8M input. At the proxy
config's price entry for `Minimax-M3` ($0.30 per million input, $0.12 per million output; the file itself calls its numbers ILLUSTRATIVE, they are not a bill) that is
**about $0.6 to $0.9 for run B and $1.0 to $1.5 for both**; if the provider caches prefixes (the config declares `supports_prompt_caching`) it is lower. A
2x price would still be under $3. Wall time: tens of minutes (about 16 to 40 sequential model calls per run).
