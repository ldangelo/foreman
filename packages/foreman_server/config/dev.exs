import Config

# GitHub webhook HMAC-SHA256 secret for /webhooks/github endpoint.
# In production, set FOREMAN_GITHUB_WEBHOOK_SECRET environment variable.
config :foreman_server, :github_webhook_secret,
  System.get_env("FOREMAN_GITHUB_WEBHOOK_SECRET", "")

# Development runtime defaults are resolved by ForemanServer.RuntimeInfo
# from environment variables, then safe built-in fallbacks.
