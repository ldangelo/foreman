Describe the feature or fix to implement here.

The agent may take several turns. When — and only when — the task is
genuinely complete, end your final message with exactly:

    <promise>COMPLETE</promise>

After this first pass, `review.exs` runs `mix test` on the host's behalf
and feeds any failures back to the agent for up to 3 more attempts.
