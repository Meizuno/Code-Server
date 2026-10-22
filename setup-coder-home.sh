#!/usr/bin/env bash
# One-time host setup: give the code-server sandbox a HARD disk ceiling.
#
# Docker's local volume driver cannot limit a volume's size on ext4, so the
# limit is the filesystem under it: a fixed-size ext4 image, loop-mounted, that
# the `coder-home` volume binds to (see docker-compose.yml). The sandbox then
# gets ENOSPC at the ceiling instead of filling the host disk that production
# shares.
#
# Run as root ON THE HOST, with code-server STOPPED:
#   docker compose down
#   sudo ./setup-coder-home.sh            # 25G default
#   sudo SIZE=40G ./setup-coder-home.sh
#
# Re-runnable: an existing image/mount/fstab entry is left alone.
set -euo pipefail

SIZE="${SIZE:-25G}"
IMG="${IMG:-/var/lib/coder-home.img}"
MNT="${MNT:-/srv/coder-home}"
# Compose prefixes volume names with the project (directory) name, so the real
# volume is code-server_coder-home, not coder-home — `docker volume rm
# coder-home` just answers "no such volume". Find it instead of assuming, and
# still allow an override.
OLD_VOLUME="${OLD_VOLUME:-$(docker volume ls --format '{{.Name}}' 2>/dev/null \
  | grep -E '(^|_)coder-home$' | head -n1)}"

[ "$(id -u)" -eq 0 ] || { echo "✗ run as root (sudo $0)" >&2; exit 1; }

# Migrating while the container writes would lose whatever it writes next.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx code-server; then
  echo "✗ code-server is running — stop it first: docker compose down" >&2
  exit 1
fi

# ── the backing image ───────────────────────────────────────────────────────
if [ -e "$IMG" ]; then
  echo "→ $IMG exists ($(du -h --apparent-size "$IMG" | cut -f1) apparent), leaving it"
else
  # Sparse: the ceiling is the ext4 size, but host space is consumed only as it
  # is actually used. fallocate would claim the whole $SIZE immediately.
  truncate -s "$SIZE" "$IMG"
  mkfs.ext4 -q -F -L coder-home "$IMG"
  echo "→ created $IMG ($SIZE, sparse) with ext4"
fi

# ── mount it ───────────────────────────────────────────────────────────────
mkdir -p "$MNT"
if mountpoint -q "$MNT"; then
  echo "→ $MNT already mounted"
else
  # discard lets deletions inside shrink the sparse file back on the host.
  mount -o loop,discard "$IMG" "$MNT"
  echo "→ mounted $IMG at $MNT"
fi

# ── survive reboots ────────────────────────────────────────────────────────
# nofail: a missing image must not strand the host in emergency mode. The
# mount lands in local-fs.target, before docker.service, so the bind volume
# never sees the bare directory.
if grep -qF " $MNT " /etc/fstab; then
  echo "→ fstab already has $MNT"
else
  printf '%s %s ext4 loop,discard,nofail 0 2\n' "$IMG" "$MNT" >> /etc/fstab
  echo "→ added $MNT to /etc/fstab"
fi

# ── migrate the existing volume, if there is one ───────────────────────────
src="$(docker volume inspect "$OLD_VOLUME" --format '{{.Mountpoint}}' 2>/dev/null || true)"
if [ -n "$src" ] && [ -d "$src" ] && [ -z "$(ls -A "$MNT" | grep -v '^lost+found$' || true)" ]; then
  echo "→ copying $src -> $MNT (this is the slow part)"
  if command -v rsync >/dev/null 2>&1; then
    rsync -aHAX --info=progress2 "$src/" "$MNT/"
  else
    tar -C "$src" -cf - . | tar -C "$MNT" -xf -
  fi
  chown 1000:1000 "$MNT"
  echo "→ copied $(du -sh "$MNT" | cut -f1)"
elif [ -n "$src" ]; then
  echo "→ $MNT is not empty; NOT copying over it"
else
  echo "→ no existing $OLD_VOLUME volume to migrate"
fi

cat <<EOF

Done. $MNT is a $SIZE filesystem:
$(df -h "$MNT" | tail -1)

Two steps left, in this order:

  1. Remove the OLD volume — compose refuses to reuse a volume whose options
     changed, so \`up -d\` fails until it is gone. The data has been copied to
     $MNT above; verify that first, this is irreversible:
       docker volume rm ${OLD_VOLUME:-<none found>}

  2. Start the sandbox against the capped filesystem:
       docker compose up -d

Verify inside, where the ceiling should now read $SIZE rather than the host disk:
       docker compose exec code-server df -h /home/coder
EOF
