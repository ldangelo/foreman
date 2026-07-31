import Config

# Secrets are loaded at release boot via SecretsProvider (wired in mix.exs).
# Set FOREMAN_SERVER_SECRETS_FILE to a .env-style file containing:
#   DATABASE_URL=postgresql://user:pass@host:5432/foreman
#   FOREMAN_SERVER_EVENT_STORE_ADAPTER=postgres  # or "term"
#   FOREMAN_SERVER_REPO_URL=postgresql://user:pass@host:5432/foreman
# If FOREMAN_SERVER_SECRETS_FILE is unset or points to a missing file, the
# provider is a no-op and app config is used as-is.
