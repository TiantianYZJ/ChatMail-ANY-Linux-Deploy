#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Configure Docker daemon: DNS + registry mirror for Chinese network
DAEMON_CFG="/etc/docker/daemon.json"
mkdir -p /etc/docker

# Build new config using Python (handles merging if daemon.json already exists)
python3 -c "
import json, os
cfg = {}
if os.path.exists('$DAEMON_CFG'):
    with open('$DAEMON_CFG') as f:
        try:
            cfg = json.load(f)
        except json.JSONDecodeError:
            pass
cfg['dns'] = ['223.5.5.5', '223.6.6.6', '8.8.8.8']
cfg['registry-mirrors'] = [
    'https://docker.m.daocloud.io',
    'https://dockerhub.timeweb.cloud',
]
with open('$DAEMON_CFG', 'w') as f:
    json.dump(cfg, f, indent=2)
print('DNS and registry mirrors configured')
"

echo "  Restarting Docker to apply..."
systemctl restart docker
sleep 3

echo "Building Docker image chatmail/relay..."
# Build context is the repo root (needed for COPY chatmaild/...),
# Dockerfile is in docker/.
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
docker build \
    --build-arg VMAIL_UID=$(id -u vmail 2>/dev/null || echo 7000) \
    --build-arg VMAIL_GID=$(id -g vmail 2>/dev/null || echo 7000) \
    -t chatmail/relay:latest \
    -f "$SCRIPT_DIR/Dockerfile" \
    "$REPO_DIR"

echo ""
echo "Done! Image built: chatmail/relay:latest"
