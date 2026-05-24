#!/bin/bash
# patch-hermes-simplex.sh — Apply required patches to Hermes Agent's Simplex adapter.
#
# The SimpleX Chat plugin shipped in Hermes Agent has bugs that prevent
# it from working. This script fixes them all.
#
# Usage: bash patch-hermes-simplex.sh [container-name]
#   Default container: hermes-webui
#
# Run after recreating the Hermes WebUI container.
# Then restart the gateway: docker exec <container> /app/venv/bin/hermes gateway restart

set -e
C="${1:-hermes-webui}"

echo "=== Patching SimpleX adapter on container: $C ==="

# 1. Install websockets
docker exec "$C" pip install -q websockets 2>/dev/null || \
  docker exec "$C" pip install websockets 2>/dev/null
echo "[1/4] websockets installed"

# 2. Copy missing plugin.yaml
docker exec "$C" bash -c 'cp /home/hermeswebui/.hermes/hermes-agent/plugins/platforms/simplex/plugin.yaml /app/venv/lib/python3.12/site-packages/plugins/platforms/simplex/plugin.yaml' 2>/dev/null
echo "[2/4] plugin.yaml copied"

# 3 & 4: Fix inbound, outbound, and composeMessages bugs
docker exec "$C" python3 << 'PYEOF'
import json, re

path = "/app/venv/lib/python3.12/site-packages/plugins/platforms/simplex/adapter.py"
with open(path) as f:
    code = f.read()

changes = 0

# Fix inbound: chatItems is nested under "resp" key
if 'event.get("chatItems")' in code:
    code = code.replace(
        'items = event.get("chatItems")',
        'items = event.get("resp", {}).get("chatItems")'
    )
    changes += 1
    print("  inbound: fixed chatItems nesting")

# Fix send() — CLI format to /_send API command (4 replacements)
replacements = [
    ('cmd_str = f"#[{group_id}] {content}"', 'chat_ref = f"#{group_id}"'),
    ('cmd_str = f"@[{chat_id}] {content}"', 'chat_ref = f"@{chat_id}"'),
    ('cmd_str = f"#[{group_id}] {message}"', 'chat_ref = f"#{group_id}"'),
    ('cmd_str = f"@[{chat_id}] {message}"', 'chat_ref = f"@{chat_id}"'),
]
for old, new in replacements:
    if old in code:
        code = code.replace(old, new)
        changes += 1

# Add /_send line after chat_ref in send()
send_line = '        cmd_str = f"/_send {chat_ref} json " + json.dumps([{"msgContent": {"type": "text", "text": content}, "mentions": {}}])\n'
old = '        else:\n            chat_ref = f"@{chat_id}"\n\n        payload = {'
new = '        else:\n            chat_ref = f"@{chat_id}"\n' + send_line + '        payload = {'
if old in code:
    code = code.replace(old, new)
    changes += 1
    print("  send(): added /_send API command")

# Add /_send line after chat_ref in standalone_sender
standalone_line = '        cmd_str = f"/_send {chat_ref} json " + json.dumps([{"msgContent": {"type": "text", "text": message}, "mentions": {}}])\n'
old2 = '        else:\n            chat_ref = f"@{chat_id}"\n\n        async with _wsclient.connect'
new2 = '        else:\n            chat_ref = f"@{chat_id}"\n' + standalone_line + '        async with _wsclient.connect'
if old2 in code:
    code = code.replace(old2, new2)
    changes += 1
    print("  standalone_sender(): added /_send API command")

if changes == 0:
    print("  No changes needed — already patched")
else:
    with open(path, 'w') as f:
        f.write(code)

# Verify
try:
    compile(code, path, 'exec')
    syntax_ok = True
except SyntaxError as e:
    syntax_ok = False
    print(f"  SYNTAX ERROR: {e}")

has_api = '/_send' in code
has_inbound = '.get("resp", {}).get("chatItems")' in code
has_array = 'json.dumps([' in code

print(f"  Changes: {changes}")
print(f"  Syntax:  {'OK' if syntax_ok else 'FAIL'}")
print(f"  Inbound: {'OK' if has_inbound else 'FAIL'}")
print(f"  API cmd: {'OK' if has_api else 'FAIL'}")
print(f"  Array:   {'OK' if has_array else 'FAIL'}")

if not all([syntax_ok, has_inbound, has_api, has_array]):
    import sys
    sys.exit(1)
PYEOF

echo "=== Done ==="
echo "Restart gateway: docker exec $C /app/venv/bin/hermes gateway restart"
