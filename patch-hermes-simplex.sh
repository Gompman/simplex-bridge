#!/bin/bash
# patch-hermes-simplex.sh — Apply required patches to the Hermes SimpleX adapter.
# Re-run after recreating the Hermes WebUI container.

set -e
C="${1:-hermes-webui}"
A="/app/venv/lib/python3.12/site-packages/plugins/platforms/simplex/adapter.py"

echo "=== Patching SimpleX adapter on container: $C ==="

docker exec "$C" pip install -q websockets
echo "[1/4] websockets installed"

docker exec "$C" bash -c 'cp /home/hermeswebui/.hermes/hermes-agent/plugins/platforms/simplex/plugin.yaml /app/venv/lib/python3.12/site-packages/plugins/platforms/simplex/plugin.yaml' 2>/dev/null
echo "[2/4] plugin.yaml copied"

docker exec "$C" sed -i 's/items = event\.get("chatItems")/items = event.get("resp", {}).get("chatItems")/' "$A"
echo "[3/4] inbound handler fixed"

docker exec "$C" python3 << 'PYEOF'
import json
path = "/app/venv/lib/python3.12/site-packages/plugins/platforms/simplex/adapter.py"
with open(path) as f:
    c = f.read()

# Replace CLI-style send with /_send API command
# send() method
c = c.replace(
    'cmd_str = f"#[{group_id}] {content}"',
    'chat_ref = f"#{group_id}"'
)
c = c.replace(
    'cmd_str = f"@[{chat_id}] {content}"',
    'chat_ref = f"@{chat_id}"'
)

# Fix _standalone_send() too
c = c.replace(
    'cmd_str = f"#[{group_id}] {message}"',
    'chat_ref = f"#{group_id}"'
)
c = c.replace(
    'cmd_str = f"@[{chat_id}] {message}"',
    'chat_ref = f"@{chat_id}"'
)

# After the second occurrence of "chat_ref = f"@{chat_id}"" which is in standalone,
# we need to add the _send line. Let's do targeted replacements.
SEND_INSERT = '\n\n        cmd_str = f"/_send {chat_ref} json " + json.dumps({"msgContent": {"type": "text", "text": content}, "mentions": {}})\n'
SEND_INSERT_STANDALONE = '\n\n        cmd_str = f"/_send {chat_ref} json " + json.dumps({"msgContent": {"type": "text", "text": message}, "mentions": {}})\n'

# Insert after chat_ref in send()
c = c.replace(
    '        else:\n            chat_ref = f"@{chat_id}"\n\n        payload = {',
    '        else:\n            chat_ref = f"@{chat_id}"' + SEND_INSERT + '\n        payload = {'
)
# Insert after chat_ref in _standalone_send()
c = c.replace(
    '        else:\n            chat_ref = f"@{chat_id}"\n\n        async with _wsclient.connect',
    '        else:\n            chat_ref = f"@{chat_id}"' + SEND_INSERT_STANDALONE + '\n        async with _wsclient.connect'
)

with open(path, 'w') as f:
    f.write(c)
print("[4/4] outbound sender fixed")
PYEOF

echo ""
echo "=== All patches applied ==="
echo "Restart gateway: docker exec $C /app/venv/bin/hermes gateway restart"
