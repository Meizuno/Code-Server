# CLAUDE.md — Meizuno dev environment (code-server)

> Installed by the Code-Server image and **refreshed on every container start**
> (so it survives the `coder-home` volume). Edit the source in the **Code-Server
> repo** (`CLAUDE.md`), not the copy at `/home/coder/CLAUDE.md` — local edits are
> overwritten on restart.

You (the Claude Code extension) are running inside **code-server** — VS Code in
the browser — the Meizuno development box. This file describes the environment
*around* the projects: what's installed, what you can and can't do, and how to
run things. **Each project has its own `CLAUDE.md`** with its architecture and
conventions — read that when working in a project; this is the surroundings.

## Where you are

- **code-server** served on `:8080`, reached at `https://code.<domain>` on the
  VPS **behind Cloudflare Access** (the only auth — code-server runs `--auth
  none`), or `http://localhost:8080` on a laptop (loopback only).
- Runs as the unprivileged **`coder`** user (uid 1000), which has passwordless
  `sudo`.
- Everything under **`/home/coder` persists** on the `coder-home` volume — your
  code, VS Code settings/extensions, and the inner Docker image store. Container
  re-creates don't lose it.
- Resource ceiling: **3 CPUs / 6 GB RAM / 25 GB disk**. The disk cap is real:
  `/home/coder` is a fixed-size ext4 image loop-mounted on the host, so filling
  it gives you **ENOSPC**, not a full host. The production stack shares the same
  physical disk — that is why the cap exists. When builds fail with "no space
  left on device", prune (below) rather than assuming the host is out of room.

## Docker works here — but it's the INNER rootless daemon

- A full **rootless Docker daemon runs inside this container**. `docker` (CLI,
  `buildx`, `compose`) just works — `DOCKER_HOST=unix:///run/user/1000/docker.sock`
  is already set. You can **build images, run containers, and run devcontainers**.
- Everything you run executes as **uid 1000** — never root on the host.
- **Isolation (read the limit carefully):** the INNER daemon has its own
  images/networks/containers and **cannot see or touch the host Docker or the
  production stack** — no host socket is mounted, `docker ps` shows only inner
  containers, and containers you start here are not on any prod network.
- **The OUTER container is a different matter.** It joins `meizuno_tunnel` so
  that cloudflared (itself a container, so it cannot use the host's loopback)
  can reach code-server by name. Whatever networks the outer container is on
  are reachable from a shell in here — Cloudflare Access gates the edge, never
  container-to-container traffic. So do not attach this box to
  `meizuno_edge`: that reaches Traefik, every app, and a Grafana running with
  anonymous admin, straight past Access. Prod Postgres and Redis stay out of
  reach either way — they are on `internal`.
- Inner images persist (`~/.local/share/docker` on the volume). Prune when disk
  grows: `docker image prune -f` (occasionally `docker system prune`).
- Rootless caveat: things needing host devices, `--privileged`, or host
  networking may not work in the inner daemon.

## Installed — and deliberately NOT installed

Baked in (kept lean):
- **Docker** Engine + CLI + **buildx** + **compose** (rootless).
- **Node.js 22 LTS** + `npm`, and **`@devcontainers/cli`** (`devcontainer`).
- **git**, **curl**, `ca-certificates`.

**NOT installed:** language toolchains — no Python, Go, Rust, Elixir, no global
`pnpm`, etc. **Put toolchains in a per-project devcontainer** (or install them
into the project); don't expect them on the base box. Node is the only exception
(for the devcontainer CLI + JS tooling). If a project needs `pnpm`, enable it
with `corepack enable` or `npm i -g pnpm` inside that project's container.

## Running a project's dev server (and reaching it in the browser)

Ports inside a devcontainer/inner container aren't reachable on their own.
Publish, then use code-server's proxy:

1. Publish the port to the code-server container: `"appPort": [3000]` in
   `devcontainer.json`, or `-p 3000:3000` on `docker run`.
2. Open it:
   - `https://code.<domain>/proxy/3000/` — path-rewriting proxy (most apps).
   - `https://code.<domain>/absproxy/3000/` — for apps that emit absolute paths
     (**Vite**, webpack dev server); set the app's base path to `/absproxy/3000/`.

## devcontainers

```bash
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . -- bash
```

All of it runs on the inner rootless daemon — invisible to the host.

## The Meizuno ecosystem (what you build here)

Projects are separate GitHub repos under **`github.com/Meizuno/*`**, cloned under
`/home/coder`. Known ones:

- **Nuxt 4 / Nitro** apps (Vue 3, **pnpm**): **AIChat**, **MoneyManager**,
  **Notes**, **RecipesBook** — most delegate auth to the central SSO.
- **Go** apps: **Authentication** (central SSO service), **Calories**
  (self-contained Google OAuth + JWT, migrated off the SSO).
- **Infrastructure** — the compose/deploy for the **production** stack (Traefik,
  cloudflared, Postgres, Redis, monitoring, backups). That stack runs on the
  **host**, separate from this sandbox — unreachable from the inner daemon.

Each repo carries its own `CLAUDE.md` (architecture + conventions) and the Nuxt
apps ship `/git-commit`, `/git-sync`, `/verify` skills. **Read the project's
`CLAUDE.md` before working in it.**

## Managing this environment itself (the Code-Server repo)

- One command, identical on laptop and VPS: `docker compose up -d --build` (or
  `docker compose pull && docker compose up -d` for the prebuilt GHCR image).
- Image: `ghcr.io/meizuno/code-server` (CI builds on push to `main` / `v*` tags).
- **Security posture:** the OUTER container is `privileged: true` (required to
  run `dockerd` without a host runtime) — it is **not** a hard host boundary;
  rootless-inner is defense-in-depth. Cloudflare Access + loopback publishing are
  the entire access control. Read the README's "Security posture" before changing
  anything here.
