# Context over 200k tokens for a gateway model through a real Foreman run: live run, 2026-11-01

Bead `foreman-gppjx` (hypothesis from `foreman-c3ke`: the claude CLI assumes a 200k-token window for `Minimax-M3`, which LiteLLM declares as 512000).
The zero-spend half is [`context-window-probe.md`](context-window-probe.md); this is the run that document prepared and left unrun. Harness:
`scripts/e2e/context_window_live.sh` with its helpers in `scripts/e2e/context_window_live/` (own server port 4835 and hook port 4935, own database
`foreman_e2e_claude_projects_cwlive`, a scratch git repository with a local bare origin, a PRIVATE claude HOME, the harness of
`scripts/e2e/claude_projects/lib.sh`). The proxy's base URL and key come from a file the owner staged (`CW_LITELLM_FILE`, two lines, never in the
repository); they are not in this document, in a command line, in an environment variable of any process the run started, or in any evidence
file (counts below). Run it as `CW_LITELLM_FILE=<file> devbox run -- bash scripts/e2e/context_window_live.sh` (this workstation wraps heavy runs in its slot lock,
`~/.omp/foreman-ledger/heavy.sh`).

**Verdict: PASS on the bead's own acceptance** ("a real claude run over 200k tokens through the proxy"), through the route the user guide documents
(`foreman project env set <id> CLAUDE_CODE_MAX_CONTEXT_TOKENS=512000` plus the key as a project secret). What is NOT proven is listed at the end; the
bead's literal ask, a per-model window declared in config and exported to the worker, is still not built (see "Not proven").

## Result

| What | Result |
|---|---|
| live attempt 1 (the only live attempt), real claude CLI 2.1.309, model alias `Minimax-M3` through a LiteLLM proxy | `passed=41 failed=0 unverified=0 wall=256s` (smoke, run A, run B) |
| zero-spend rehearsals before it (no provider): `CW_GATEWAY=standin`, a scripted stand-in gateway started by the script | `passed=53 failed=0 unverified=0 wall=137s` (A, B and the optional C through the full Foreman stack) |
| zero-spend rehearsals through the live code path (a stand-in gateway named in `CW_LITELLM_FILE`, so the ledger, the combined-ceiling guard and the cancel path ran) | A and B `passed=41 failed=0 unverified=1 wall=81s` (C refused by the guard: that rehearsal's ledger held 2256570 tokens of a 4000000 ceiling); B refused by a 900000 ceiling (`passed=23 failed=0 unverified=2 wall=31s`); B cancelled at its time bound (`passed=22 failed=5 unverified=1 wall=46s`, the five failures are the expected ones) |
| run C (same corpus, variable unset, real provider) | NOT run: run B's outcome was not ambiguous, the zero-spend probe had measured that contrast, and the owner's budget for this bead was about 1 to 1.5 USD (see "Spend") |

Environment: the claude CLI of this host, `claude 2.1.309` (the agent images pin 2.1.308; `context_window_probe.sh` was re-run on 2.1.309 first and gave
the same ten results, `passed=10 failed=0 unverified=0`), Foreman server in the dev environment under devbox (Erlang/OTP 28), the workflow run on the
server host (not a docker jobsite). The proxy declares for `Minimax-M3`: `max_input_tokens` 512000, `max_output_tokens` 131072, prompt caching supported,
prices 0.30 USD per million input tokens, 0.12 per million output tokens and 0.06 per million cached input tokens (its config calls them illustrative);
its upstream is the real provider's Anthropic-compatible endpoint, so the tokens below were really processed.

## What the run did

1. **Smoke, once** (`context_window_live.sh` stops here when any check fails): one `POST /v1/messages` with `model: "Minimax-M3"` spelled as the workflow spells it,
   `max_tokens` 16: HTTP 200, `type: message`, `role: assistant`, `model` echoed verbatim, a `usage` block with `input_tokens` 1 and `cache_read_input_tokens` 182 (the proxy's reply for a prompt of 183 tokens).
   The proxy answered `/health/liveliness`, `/health/readiness` and `/v1/models` (12 aliases, `Minimax-M3` among them) and declares a window of 512000
   (the run is refused below 300000: it would prove nothing).
2. **Setup.** A throwaway project over a scratch repository that holds `ballast/part-01..03.txt` (`make_ballast.py`: 79919 bytes, 1095 numbered lines of common
   English words, the last line `CHECKSUM part-NN <12 hex>`; a direct proxy request with one part measured 17588 input tokens, 4.5 bytes per token). One
   workflow, `claudegw`: one phase, `provider: claude`, `approval_mode: auto_approve`, `models.default: Minimax-M3`. The project environment:
   `ANTHROPIC_BASE_URL` (plain variable), `DISABLE_AUTOUPDATER=1`, `DISABLE_TELEMETRY=1`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (the plumbing of the zero-spend
   probe), and `ANTHROPIC_API_KEY` as a project SECRET (`foreman project secret set`, the value on stdin: version 1, absent from `env list`).
   The server's own environment had no `ANTHROPIC_*` and no `CLAUDE_*` variable. A recorder (`bin/claude`) stood first on the server's PATH: it logs what the
   CLI is given and passes the CLI's stdout through unchanged.
3. **Run A, canary and baseline** (2 parts, `CLAUDE_CODE_MAX_CONTEXT_TOKENS` unset). **Run B, the acceptance** (the variable set to 512000 in the PROJECT
   environment with `foreman project env set`, adaptive ballast): the harness adds `part-04`, `part-05`, ... to the run's worktree while the agent reads, always
   two ahead of the highest part the agent has asked for, until the claude session file shows a request above 200000 tokens; from then on it adds none and the next
   `Read` answers "File does not exist", which the prompt says ends the corpus. The crossing is observed, not assumed from a file count.

## The numbers

### Run B (variable set), request by request

`context` is `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` of the assistant record in the claude session file; the proxy's own
per-request log (`/spend/logs`) gave the SAME `prompt_tokens` for all 16 requests, every one `success`.

| request | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| context | 11317 | 30185 | 49002 | 67468 | 85902 | 104469 | 122863 | 141466 |

| request | 9 | 10 | 11 | **12** | **13** | **14** | **15** | **16** |
|---|---|---|---|---|---|---|---|---|
| context | 159950 | 178495 | 197036 | **215490** | **233872** | **252363** | **252205** | **252542** |

- Largest request **252542** tokens; **5 requests above 200000**; the first above it is request 12 (215490) after 11 parts had been read. No `compact_boundary`
  record and no `isCompactSummary` record in the session file: **no compaction**, including at 178495 and 197036, the sizes at which the CLI compacts when it believes
  in a 200000 window (176000 claimed tokens in the probe).
- 14 `Read` calls (parts 01 to 14, one per call, no parallel reads), 1 `Write`. The harness froze the corpus at part 13 when it saw request 12; the agent's `Read` of
  part 14 got `File does not exist`, it said `Corpus complete at part-13 (part-14 does not exist). Creating report.txt.`, wrote `report.txt` and replied `done`. The run
  completed (`completed` in Foreman after 212 s; 16 turns, 210.5 s of API time).
- `report.txt` on the run's branch holds the `CHECKSUM` lines of `part-01` and `part-13` exactly as the files have them: the agent kept the first part's line across
  252k tokens of context (a model-quality observation; the harness does not assert it).
- Each request carried the whole conversation (about 18.5k tokens added per part read, 11.3k base); the provider cached the previous request's prefix: of 2354625 prompt
  tokens, 1877389 (80%) were cache reads.

### Run A (variable unset, 2 parts) against run B: the contrast the real runs show

| | run A | run B |
|---|---|---|
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` in the CLI's own environment (the recorder) | `<unset>` | `512000` |
| window the CLI reports for `Minimax-M3` (`modelUsage.<model>.contextWindow` of its own `result` record) | **200000** | **512000** |
| the CLI's `unrecognized_model` diagnostic on stderr | printed | printed |
| requests, largest context, compactions | 4, 48950, 0 | 16, 252542, 0 |

Everything else was the same (workflow, model string, CLI, project, proxy, key); only the prompt differs (run A reads two parts, run B reads until the corpus ends). So the variable set in
the project environment reached the CLI process and changed the window it believes in from 200000 to 512000; the recorder shows it in the CLI's environment, not only in Foreman's
computation of the map. That the same corpus WITHOUT the variable compacts near 176000 was not run against the real provider (budget, see "Spend"); it was measured against a
stand-in gateway by the probe (`context-window-probe.md`: compaction between 175000 and 177000 claimed tokens without the variable, between 480000 and 490000 with it), and through
the full Foreman stack by the scripted rehearsal at the end of this document.

### Foreman's own record and the proxy's

| | run A | run B |
|---|---|---|
| Foreman `UsageRecorded` input / cache read / output tokens | 67378 / 71824 / 406 | 477236 / 1877389 / 1612 |
| input side (input + cache read) | 139202 | 2354625 |
| the proxy's own log: requests, prompt tokens, completion tokens | 4, 139202, 406 | 16, 2354625, 1612 |
| proxy spend (its price table, cache reads at 0.06 per million) | 0.0246 USD | 0.2560 USD |
| Foreman `cost_usd` | 0.2920 | 2.3167 |

Foreman's token counts equal the proxy's and the session file's exactly. Foreman's `cost_usd` does NOT describe this spend: it is the CLI's own estimate for a model it does not
recognise (`modelUsage.<model>.costBasis` is `unknown`), about nine times the proxy's figure. `foreman usage --by model` therefore reports 2.61 USD for a pair of runs that cost
0.28 USD at the proxy's prices. Not fixed here (it is not on the variable's path).

> **Forward pointer (`foreman-g5u3h`).** Addressed after this run was recorded; the observation above stands as written. The
> figure reproduces exactly from the run's own tokens at the rates of the CLI's default model, 4 / 0.20 / 20 USD per million
> input / cache-read / output tokens (the `tier_4_20_cache_read_0_20` row of the CLI's price catalog): run A
> `(67378·4 + 71824·0.2 + 406·20) / 1e6 = 0.2919968`, run B `(477236·4 + 1877389·0.2 + 1612·20) / 1e6 = 2.3166618`. The claude
> adapter now reports no cost when the CLI's `costBasis` for a model is not `list` or `managed`, so such a run is recorded with its
> tokens and an unknown cost (`-` in `foreman usage`); see "Usage and cost" in `docs/user-guide.md`.

### Spend

| | tokens | USD |
|---|---|---|
| this invocation (A and B, proxy's log) | 2493827 prompt + 2018 completion | 0.2806 by the proxy's price table; 0.7484 computed at 0.30 per million in and 0.12 per million out with no cache discount |
| the two direct requests made while measuring the ballast, before the script | 17893 + 2 | 0.0053 |
| all real-provider runs together (the script's ledger) | 2513740 | 0.2859 by the proxy; 0.7538 computed without a cache discount |

The owner's ceiling for all real runs together was 4000000 tokens (about 1.2 USD of input at 0.30 per million); the ledger (`CW_LEDGER`, one line per run, read by every
invocation) held 63% of it. The expected size of run B was printed before it started: about 2.38M input tokens, 0.72 USD without a cache discount (the run used 2.35M). One
pi coordinator turn (`minimax/MiniMax-M2.7-highspeed`, 4416 input + 8532 cache read + 589 output, 0.0046 USD by pi's own prices) was made by the throwaway project's
coordinator after run A; it did not go through the proxy and is not in the ledger.

## The mechanical `[INFERENCE]` items of the probe document, checked

- **The CLI receives the model string verbatim.** The recorder logged `--model Minimax-M3` for both runs (the adapter builds `--model` from the request's model with no
  rewriting); the server log's resolution line says `provider=claude model="Minimax-M3" source=phase_declared`.
- **The claude adapter hands the project environment to the CLI.** The recorder saw, in the CLI process: `ANTHROPIC_BASE_URL` (the proxy), `ANTHROPIC_API_KEY` (set, 36
  characters, from the project secret; the server's own environment had none), `DISABLE_*` plumbing, `FOREMAN_RUN_ID` of the run, and, in run B only,
  `CLAUDE_CODE_MAX_CONTEXT_TOKENS=512000`. The route is `RunExecutor` env map, `JidoHarnessWorker.put_env`, the harness request's `env`, the process spec's `env` overlaid on the
  server's environment. No allowlist is involved on this door.
- **Where the claude session file lands.** In the server's HOME (here the harness's private `$WORK/home`; the recorder shows `HOME=$WORK/home` in the CLI's environment):
  `$HOME/.claude/projects/<working directory with / and . turned into ->/<session id>.jsonl`, one file per run, in the directory named after the run's worktree.
- The adapter starts the CLI with `--print --output-format stream-json --include-partial-messages --verbose --input-format stream-json --replay-user-messages --model ... --permission-mode
  bypassPermissions`: the prompt arrives on stdin, which is why the recorder shows no prompt argument.
- `foreman project secret set` trims one trailing newline (`docs/cli-reference.md`); the harness sends the value without one, from a shell variable, on stdin.

## The key

The harness counts the files that hold the key (raw, hex, URL-encoded) before anything leaves the work dir and again before cleanup. Final counts: the work dir (205 files: server
log, database data dump, claude session files, worktrees, run artifacts), the evidence directory (80 files: session files, recorder logs, the event store dump, the proxy's
per-request log, Foreman's usage records, `ps` lines of the server's process tree) and the committed harness files: **0**. The write-only secret store holds it in exactly **one** file
(`~/.foreman/secrets/<project>.json` under the private HOME). The key never appeared on a command line (it reached Foreman on stdin; the proxy was queried from a Python process that read it
itself; the recorder logs its length only).

## Not proven

- **No run of the same corpus without the variable on the real provider.** The real-run contrast is the CLI's reported window (200000 against 512000) and the absence of any compaction at 178k and
  197k with the variable set; the compaction threshold without it is the probe's measurement against a stand-in (and, through Foreman, the rehearsal's: the same corpus compacted at 163471 tokens
  without the variable and not at all, up to 251419 claimed tokens, with it). Run C of the script (`CW_STAGES=C CW_LARGE_FILES=13`) does it for about 1.3M tokens.
- One model, one proxy, one run of 16 requests in 3.5 minutes. The original report (`foreman-c3ke`) is not reproduced: the proxy's spend log of that day showed 403 requests over 31 minutes
  whose context grew to 176092 and then restarted at about 31k (a timing match only, never tied to the run id), and the CLI version inside that container is unknown.
- The agent ran on the server host (a workflow run). A docker jobsite with `FOREMAN_JOBSITES_AGENT_ENV_ALLOWLIST` and the network policy were not exercised; the image's pinned CLI 2.1.308 was
  not run (2.1.309 was; the zero-spend probe matches on both).
- The harness caps the context near 300000 tokens (by design: the cost); nothing was sent above 252542, so the window up to 512000 is not exercised, only the absence of the 200000 ceiling.
- The bead's literal ask, a per-model window declared in configuration and exported to the worker environment, is NOT built: the only channel is the project environment. That is a design
  decision for the owner; this run shows the channel works.
- The CLI still prints its `unrecognized_model` diagnostic with the variable set (as the probe found): the variable changes the window, it does not make the model "recognised".

## Findings

- `scripts/e2e/claude_projects/claude_home.sh` `claude_session_files` runs `stat -f %m` first; under devbox `stat` is GNU `stat`, where `-f` is "file system status", so each line it lists is
  preceded by the file system's report (the real path is still its last token, which is why the scripts that use it worked). `context_window_live.sh` lists sessions with `find`. The helper is not
  changed here.
- `foreman usage` `cost_usd` for a gateway model is the CLI's estimate with an unknown cost basis (above). Not a defect of the variable route; a misleading number for this model.
  Addressed by `foreman-g5u3h` (forward pointer under "Foreman's own record and the proxy's").
- No defect was found in the route this bead is about: `project env set` (plain variable) and `project secret set` (stdin) reached the CLI, and the variable changed its window.

## Zero-spend rehearsal (the same script, a scripted stand-in gateway)

`CW_GATEWAY=standin` starts `fake_agent_gateway.py`: a scripted "model" that reads the parts, writes `report.txt` and says `done`, and claims `input_tokens` equal to the request body's bytes / 4
(the CLI's own estimate rule), so the CLI's compaction decision is the real one. Through the full Foreman stack, `passed=53 failed=0 unverified=0 wall=137s`: run A window 200000; run B
(variable set) crossing at request 10 (207633 claimed), largest 251419, no compaction, window 512000; run C (variable unset, 11 parts) compaction `trigger auto, preTokens 163471`, window
200000. That shows the harness and Foreman's env plumbing, not a model's behaviour.
