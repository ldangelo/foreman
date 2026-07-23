import Config

# Development runtime defaults are resolved by ForemanServer.RuntimeInfo
# from environment variables, then safe built-in fallbacks.

# Runtime values such as FOREMAN_GITHUB_WEBHOOK_SECRET are read at startup/call time
# by ForemanServer.RuntimeInfo instead of compile-time dev config.
