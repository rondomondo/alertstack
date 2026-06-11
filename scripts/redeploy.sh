#!/usr/bin/env bash
# Pull the latest alertstack from git and restart the stack.
# Runs on the EC2 instance.
# Usage: sudo /usr/local/bin/redeploy.sh
set -euo pipefail

APP_DIR="/opt/alertstack"
REPO_URL="https://github.com/rondomondo/alertstack.git"

log()  { echo "[redeploy] $*"; }
fail() { echo "[redeploy] ERROR: $*" >&2; exit 1; }

log "Starting redeploy of alertstack"

if [[ -d "$APP_DIR/.git" ]]; then
  log "Pulling latest changes"
  git -C "$APP_DIR" pull --ff-only
else
  log "Cloning repo"
  git clone "$REPO_URL" "$APP_DIR"
  chown -R ubuntu:ubuntu "$APP_DIR"
fi

log "Restarting stack"
sudo -u ubuntu bash -lc "cd $APP_DIR && make stack-down 2>/dev/null || true"
sudo -u ubuntu bash -lc "cd $APP_DIR && make stack-up"

log "Redeploy complete."
