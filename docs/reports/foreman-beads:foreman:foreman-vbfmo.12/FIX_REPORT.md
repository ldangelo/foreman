

No session holds `foreman_test` now (only my psql). The lock is likely a transaction-advisory lock; let me read `claim_database!` and see whether a stale lock remains.