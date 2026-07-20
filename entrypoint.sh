#!/bin/sh
# Entrypoint (runs as coder, uid 1000): start the ROOTLESS inner Docker
# daemon, wait until it is ready, then hand off to code-server's stock
# entrypoint.
set -eu

export XDG_RUNTIME_DIR=/run/user/1000
export DOCKER_HOST=unix:///run/user/1000/docker.sock

# /run is a root-owned tmpfs, so the per-user runtime dir cannot be baked
# into the image; create it at startup (0700, owned by coder, per the XDG
# spec). coder has passwordless sudo in the codercom/code-server base image.
sudo install -d -m 0700 -o coder -g coder "$XDG_RUNTIME_DIR"

# Launch the rootless daemon (rootlesskit + dockerd as coder, slirp4netns
# networking, fuse-overlayfs storage). Runs entirely as uid 1000 — a
# breakout from it lands as an unprivileged user, not root.
dockerd-rootless.sh >/tmp/dockerd.log 2>&1 &

# Readiness wait: rootlesskit and dockerd take a moment to create the socket
# and answer API calls. `docker info` only succeeds once the daemon is fully
# up, so poll it (1s interval, 30s cap) instead of sleeping a fixed amount.
# Without this, code-server would start fine but early `docker ...` commands
# and devcontainer builds would fail confusingly.
tries=0
until docker info >/dev/null 2>&1; do
  tries=$((tries + 1))
  if [ "$tries" -ge 30 ]; then
    echo "ERROR: rootless dockerd did not become ready within 30s." >&2
    echo "----- last lines of /tmp/dockerd.log -----" >&2
    tail -n 50 /tmp/dockerd.log >&2 || true
    exit 1
  fi
  sleep 1
done
echo "Inner rootless Docker daemon is ready."

# Hand off to code-server's normal entrypoint (fixuid + code-server), bound
# to all interfaces of the container; publishing to the host is restricted
# to 127.0.0.1 in docker-compose.yml. Built-in auth is disabled — access
# control is Cloudflare Access in front of the tunnel (and loopback-only
# publishing locally). Any args (CMD or CLI) are passed through.
exec /usr/bin/entrypoint.sh --bind-addr 0.0.0.0:8080 --auth none "$@"
