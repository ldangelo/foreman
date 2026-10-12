# Foreman Jobsite sandbox image.
#
# Build with:
#   docker build --build-arg AGENT_UID=$(id -u) --build-arg AGENT_GID=$(id -g) \
#     -t foreman-jobsite:<name> .foreman
#
# AGENT_UID/AGENT_GID must match the host user running Foreman so that files
# the agent creates on the bind-mounted worktree are owned by you, not root,
# once the container exits.
FROM elixir:1.18-otp-27-slim

ARG AGENT_UID=1000
ARG AGENT_GID=1000

RUN apt-get update \
  && apt-get install -y --no-install-recommends git curl ca-certificates gnupg \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
  && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
  && apt-get install -y --no-install-recommends gh nodejs \
  && npm install -g @earendil-works/pi-coding-agent @anthropic-ai/claude-code \
  && rm -rf /var/lib/apt/lists/*

# The default iterate prompt drives beads, so the image carries `br` and `bv`
# (installed system-wide as root; bv is pinned to a reviewed commit). Drop this
# for another tracker.
RUN curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh \
    | bash -s -- --dest=/usr/local/bin --easy-mode --no-gum \
  && curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/a43b8e85a39664381566abdfd85dc8fcbfdcb773/install.sh \
    | INSTALL_DIR=/usr/local/bin bash

# Adjust to the agent CLI(s) you actually use; both are installed above so
# either `Agents.pi/2` or `Agents.claude/2` works out of the box.

# -o: the host's GID/UID may collide with one the base image already has
# (macOS staff is GID 20, which is `dialout` in Debian).
RUN groupadd -o -g "${AGENT_GID}" agent \
  && useradd -o -m -u "${AGENT_UID}" -g "${AGENT_GID}" agent

USER agent
WORKDIR /workspace
