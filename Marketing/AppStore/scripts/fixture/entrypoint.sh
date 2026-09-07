#!/bin/bash
# Installs the capture run's public key, seeds a fictional home, and starts a real sshd.
set -e
if [ -n "${AUTHORIZED_KEY:-}" ]; then
  printf '%s\n' "$AUTHORIZED_KEY" > /home/deploy/.ssh/authorized_keys
  chown deploy:deploy /home/deploy/.ssh/authorized_keys
  chmod 600 /home/deploy/.ssh/authorized_keys
fi
su deploy -s /bin/bash -c /usr/local/bin/seed-home.sh || echo "seed failed (non-fatal)" >&2
exec /usr/sbin/sshd -D -e
