#!/bin/bash
# patch-hermes-simplex.sh — Apply required patches to Hermes Agent's Simplex adapter.
#
# The SimpleX Chat plugin shipped in Hermes Agent has two bugs that prevent
# it from working correctly. This script fixes them.
#
# Usage: bash patch-hermes-simplex.sh [container-name]
#   Default container: hermes-webui
#
# Run this after recreating/updating the Hermes WebUI container.
# Then restart the gateway: docker exec <container> /app/venv/bin/hermes gateway restart

set -e
C="${1:-hermes-webui}"
A="/app/venv/lib/python3.12/site-packages/plugins/platforms/simplex/adapter.py"

echo "=== Patching SimpleX adapter on container: $C ==="

# 1. Install websockets
docker exec "$C" pip install -q websockets 2>/dev/null || \
  docker exec "$C" pip install websockets 2>/dev/null
echo "[1/4] websockets installed"

# 2. Copy missing plugin.yaml
docker exec "$C" bash -c 'cp /home/hermeswebui/.hermes/hermes-agent/plugins/platforms/simplex/plugin.yaml /app/venv/lib/python3.12/site-packages/plugins/platforms/simplex/plugin.yaml' 2>/dev/null
echo "[2/4] plugin.yaml copied"

# 3 & 4: Fix inbound and outbound bugs
docker exec "$C" python3 << 'PYEOF'
import json

path = "/app/venv/lib/python3.12/site-packages/plugins/platforms/simplex/adapter.py"
with open(path) as f:
    code = f.read()

changes = 0

# Fix inbound: chatItems is nested under "resp" key
if 'items = event.get("chatItems")' in code:
    code = code.replace(
        'items = event.get("chatItems")',
        'items = event.get("resp", {}).get("chatItems")'
    )
    changes += 1

# Fix send() — CLI format to /_send API command
if 'cmd_str = f"#[{group_id}] {content}"' in code:
    code = code.replace(
        'cmd_str = f"#[{group_id}] {content}"',
        'chat_ref = f"#{group_id}"'
    )
    changes += 1
if 'cmd_str = f"@[{chat_id}] {content}"' in code:
    code = code.replace(
        'cmd_str = f"@[{chat_id}] {content}"',
        'chat_ref = f"@{chat_id}"'
    )
    changes += 1

# Fix standalone sender — same CLI format issue
if 'cmd_str = f"#[{group_id}] {message}"' in code:
    code = code.replace(
        'cmd_str = f"#[{group_id}] {message}"',
        'chat_ref = f"#{group_id}"'
    )
    changes += 1
if 'cmd_str = f"@[{chat_id}] {message}"' in code:
    code = code.replace(
        'cmd_str = f"@[{chat_id}] {message}"',
        'chat_ref = f"@{chat_id}"'
    )
    changes += 1

# Add /_send API line after chat_ref in send() method
send_line = '        cmd_str = f"/_send {chat_ref} json " + json.dumps({"msgContent": {"type": "text", "text": content}, "mentions": {}})\n'
old = '        else:\n            chat_ref = f"@{chat_id}"\n\n        payload = {'
new = '        else:\n            chat_ref = f"@{chat_id}"\n' + send_line + '        payload = {'
if old in code:
    code = code.replace(old, new)
    changes += 1

# Add /_send API line after chat_ref in standalone_sender
send_standalone = '        cmd_str = f"/_send {chat_ref} json " + json.dumps({"msgContent": {"type": "text", "text": message}, "mentions": {}})\n'
old2 = '        else:\n            chat_ref = f"@{chat_id}"\n\n        async with _wsclient.connect'
new2 = '        else:\n            chat_ref = f"@{chat_id}"\n' + send_standalone + '        async with _wsclient.connect'
if old2 in code:
    code = code.replace(old2, new2)
    changes += 1

# Write back
with open(path, 'w') as f:
    f.write(code)

print(f"[3&4/4] {changes} fix(es) applied")

# Verify syntax
try:
    compile(code, path, 'exec')
    print("       syntax: OK")
except SyntaxError as e:
    print(f"       syntax: ERROR — {e}")
    import sys
    sys.exit(1)

# Verify key fixes are present
api = '/_send' in code
inbound = '.get("resp", {}).get("chatItems")' in code
print(f"       API command:   {'YES' if api else 'MISSING — ERROR'}")
print(f"       Inbound fix:   {'YES' if inbound else 'MISSING — ERROR'}")
if not api or not inbound:
    import sys
    sys.exit(1)
PYEOF

echo ""
echo "=== All patches applied successfully ==="
echo "Restart gateway: docker exec $C /app/venv/bin/hermes gateway restart"
