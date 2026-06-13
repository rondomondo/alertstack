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
ALERTSTACK_HOST=$(grep -oP '(?<=export ALERTSTACK_HOST=)\S+' /home/ubuntu/.bashrc | tail -1)
if [[ -z "$ALERTSTACK_HOST" ]]; then
  log "WARNING: ALERTSTACK_HOST not found in /home/ubuntu/.bashrc, falling back to .env"
  sudo -u ubuntu bash -lc "cd $APP_DIR && make stack-down 2>/dev/null || true"
  sudo -u ubuntu bash -lc "cd $APP_DIR && make stack-up"
else
  log "Using ALERTSTACK_HOST=$ALERTSTACK_HOST (from /home/ubuntu/.bashrc)"
  sudo -u ubuntu bash -lc "cd $APP_DIR && make stack-down ALERTSTACK_HOST=$ALERTSTACK_HOST 2>/dev/null || true"
  sudo -u ubuntu bash -lc "cd $APP_DIR && make stack-up ALERTSTACK_HOST=$ALERTSTACK_HOST"
fi

log "Redeploy complete."
