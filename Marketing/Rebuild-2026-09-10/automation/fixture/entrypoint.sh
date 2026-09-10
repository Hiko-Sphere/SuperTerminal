#!/bin/bash
# Installs the capture run's public key, seeds a fictional home, starts the desktop and the
# forward target, then runs a real sshd in the foreground.
set -e
if [ -n "${AUTHORIZED_KEY:-}" ]; then
  printf '%s\n' "$AUTHORIZED_KEY" > /home/deploy/.ssh/authorized_keys
  chown deploy:deploy /home/deploy/.ssh/authorized_keys
  chmod 600 /home/deploy/.ssh/authorized_keys
fi
if [ -n "${DEPLOY_PASSWORD:-}" ]; then
  printf '%s\n%s\n' "$DEPLOY_PASSWORD" "$DEPLOY_PASSWORD" | passwd deploy >/dev/null 2>&1
fi
su deploy -s /bin/bash -c /usr/local/bin/seed-home.sh || echo "seed failed (non-fatal)" >&2
if [ "${WITH_DESKTOP:-0}" = "1" ]; then
  su deploy -s /bin/bash -c /usr/local/bin/desktop.sh || echo "desktop failed (non-fatal)" >&2
fi
su deploy -s /bin/bash -c 'python3 /usr/local/bin/service.py' >/dev/null 2>&1 &
exec /usr/sbin/sshd -D -e
