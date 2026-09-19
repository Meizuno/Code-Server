# code-server + ROOTLESS inner Docker daemon (rootless Docker-in-Docker).
#
# No host runtime (Sysbox etc.) is required — the same image and the same
# run command work identically on a laptop and on the VPS. The inner dockerd
# runs as the unprivileged `coder` user via rootlesskit.
#
# HONEST caveat: the OUTER container still needs to be privileged (see
# docker-compose.yml). Rootless-inner is defense-in-depth only: a breakout
# from the inner daemon lands as an unprivileged user, not root.
#
# Keep this image lean: language toolchains (Python, Rust, Elixir, ...)
# belong in per-project devcontainers, not here.
FROM codercom/code-server:4.101.2

USER root

# --- Rootless Docker stack + git + curl -------------------------------------
# The Docker apt repo entry derives the codename from /etc/os-release, so it
# always matches the base image's Debian release.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg git \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      docker-ce docker-ce-cli containerd.io docker-ce-rootless-extras \
      docker-buildx-plugin docker-compose-plugin \
      fuse-overlayfs slirp4netns uidmap iptables iproute2 \
 && rm -rf /var/lib/apt/lists/*

# Subordinate uid/gid ranges so rootlesskit can map user namespaces for coder.
RUN echo "coder:100000:65536" > /etc/subuid \
 && echo "coder:100000:65536" > /etc/subgid

# --- Node.js 22 LTS + @devcontainers/cli ------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g @devcontainers/cli \
 && npm cache clean --force \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint-dind.sh
RUN chmod +x /usr/local/bin/entrypoint-dind.sh

# Environment description for the Claude Code extension. Baked in here; the
# entrypoint copies it to /home/coder/CLAUDE.md on start so it stays current
# past the persistent coder-home volume.
COPY CLAUDE.md /opt/meizuno/CLAUDE.md

# Everything — code-server AND dockerd — runs as coder (uid 1000).
USER coder

# Make every shell (including code-server's integrated terminal) talk to the
# rootless daemon's socket. Data root defaults to ~/.local/share/docker,
# which lives on the /home/coder volume, so inner images persist.
ENV XDG_RUNTIME_DIR=/run/user/1000 \
    DOCKER_HOST=unix:///run/user/1000/docker.sock

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint-dind.sh"]
# Default folder code-server opens.
CMD ["/home/coder"]
