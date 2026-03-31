# Implement All Debug Recommendations

## P0 (Done ✅)
- [x] Guard `branch-ready` only on finalize success
- [x] Explorer failure → no merge

## P1 (Done ✅)
- [x] Rate limit backoff: 30s/60s/120s when 429 received
- [x] Circuit breaker: Explorer fails 3x → fail fast
- [x] Alert when rate limit detected in logs
- [x] Stagger delay: `foreman run --stagger=30s`

## P2 (Done ✅)
- [x] Haiku fallback to Sonnet on rate limit
- [x] Per-model rate limit tracking in store

## P3 (Done ✅)
- [x] Per-model rate limit visualization (via `getRecentRateLimitEvents()`)

## Files Modified
- `src/lib/config.ts` - Added `RATE_LIMIT_BACKOFF_CONFIG`
- `src/lib/store.ts` - Added rate limit events table and query methods
- `src/orchestrator/pipeline-executor.ts` - Circuit breaker, rate limit handling, Haiku fallback
- `src/orchestrator/agent-worker.ts` - Added `onRateLimit` callback
- `src/cli/commands/run.ts` - Added `--stagger` option
- `src/orchestrator/dispatcher.ts` - Added stagger delay between dispatches

## Tests
- 3660 tests pass
