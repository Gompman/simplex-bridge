#!/bin/bash
# patch-hermes-simplex.sh — Enable SimpleX Chat in Hermes Agent.
#
# Hermes Agent v0.14.0+ ships a working SimpleX Chat plugin at
# plugins/platforms/simplex/adapter.py. This script handles the two
# remaining setup steps that can't be done in-image:
#   1. Install the 'websockets' Python package (not bundled)
#   2. Copy plugin.yaml from the source checkout to site-packages
#      (build process drops non-.py files from the installed wheel)
#
# No adapter code patches needed — the shipped adapter is correct.
#
# Usage: bash patch-hermes-simplex.sh [container-name]
#   Default container: hermes-webui
#
# Run after recreating the Hermes WebUI container.
# Then restart the gateway: docker exec <container> /app/venv/bin/hermes gateway restart

set -e
C="${1:-hermes-webui}"

echo "=== Enabling SimpleX Chat plugin on container: $C ==="

# 1. Install websockets
echo "[1/2] Installing websockets..."
docker exec "$C" pip install -q websockets 2>/dev/null || \
  docker exec "$C" pip install websockets 2>/dev/null

# Verify
docker exec "$C" python3 -c "import websockets; print('  → websockets', websockets.__version__)" 2>/dev/null

# 2. Copy missing plugin.yaml
echo "[2/2] Copying plugin.yaml to site-packages..."
SRC_YAML="/home/hermeswebui/.hermes/hermes-agent/plugins/platforms/simplex/plugin.yaml"
DST_DIR="/app/venv/lib/python3.12/site-packages/plugins/platforms/simplex/"

if docker exec "$C" test -f "$DST_DIR/plugin.yaml" 2>/dev/null; then
    echo "  → plugin.yaml already present"
else
    docker exec "$C" cp "$SRC_YAML" "$DST_DIR/plugin.yaml" 2>/dev/null
    if docker exec "$C" test -f "$DST_DIR/plugin.yaml" 2>/dev/null; then
        echo "  → plugin.yaml copied"
    else
        echo "  → FAILED to copy plugin.yaml"
        exit 1
    fi
fi

# 3. Verify plugin is discoverable
echo ""
echo "=== Verification ==="
docker exec "$C" python3 -c "
from hermes_cli.gateway import _all_platforms
simplex = [p for p in _all_platforms() if p['key'] == 'simplex']
if simplex:
    print('✓ SimpleX plugin registered in Hermes gateway')
else:
    print('✗ SimpleX plugin NOT found — plugin.yaml may not be in site-packages')
    import os
    path = '/app/venv/lib/python3.12/site-packages/plugins/platforms/simplex'
    print('  Contents of', path, ':', os.listdir(path))
    exit(1)
" 2>/dev/null

echo ""
echo "=== Done ==="
echo "Restart gateway: docker exec $C /app/venv/bin/hermes gateway restart"
echo "Then verify:    docker exec $C /app/venv/bin/hermes gateway status"
