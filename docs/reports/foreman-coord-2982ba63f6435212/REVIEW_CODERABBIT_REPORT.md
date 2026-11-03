CodeRabbit review phase complete.

**Engine:** `coderabbit review --agent --base main` → 10 findings, 1 round (stopped early: no Critical/Major left).

**Fixed (7):**
- `components.ex` — `thread_chip` dead `Map.get` default → `Map.fetch!`; removed disagreeing `sender_label`/`message_variant` catch-alls (closed role vocab, raises on unknown); removed `coordinator_chip(_)` "idle" fallback that hid Restart.
- `layouts.ex` — dropped `white-space:pre-wrap` from `.msg` wrapper (blank-line artifact); added missing `.ws-msg` rule (instructions/questions were run-on); capped sticky `.ws-side` to viewport.
- test — strengthened Show-all assertion to pin `details.ws-showall`.

**Declined (3):**
- `--accent #c15f3c` contrast — spec pins the token literally; noted for operator.
- Show-all text duplication — spec §4 mandates full text in DOM; noted for operator.
- Additive helper unit tests — not a defect; §7 contracts already covered.

**Verification:** `mix format --check-formatted` clean; `mix test --warnings-as-errors` on both affected files → **54 passed**, exit 0 (`DATABASE_URL`/`EVENTSTORE_URL` unset).

**Notes:** `foreman_inbox_send`/`foreman_task_add_comment` unavailable — noted in artifact. Fixes left uncommitted. 2 unresolved (operator-decision) findings emitted in the report's findings block. `foreman_env`/`.beads/` untouched; doc gate: no externally visible identifiers changed.