#!/bin/bash
set -e

DATA_DIR="/data"
DB_PREFIX="$DATA_DIR/simplex"
DB_FILE="${DB_PREFIX}_v1_chat.db"

# Configure timezone
if [ -n "$TZ" ] && [ -f "/usr/share/zoneinfo/$TZ" ]; then
    ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
    echo "$TZ" > /etc/timezone
fi

# Build extra flags
EXTRA_FLAGS=""

# Bot profile — create if first run
if [ ! -f "$DB_FILE" ]; then
    echo "First run: creating bot profile..."
    EXTRA_FLAGS="$EXTRA_FLAGS --create-bot-display-name \"$SIMPLEX_DISPLAY_NAME\""
    if [ "$SIMPLEX_FILES_ENABLED" = "true" ]; then
        EXTRA_FLAGS="$EXTRA_FLAGS --create-bot-allow-files"
    fi
fi

# Mark read
if [ "$SIMPLEX_MARK_READ" = "true" ]; then
    EXTRA_FLAGS="$EXTRA_FLAGS -r"
fi

# Tor support
if [ "$SIMPLEX_TOR" = "true" ]; then
    EXTRA_FLAGS="$EXTRA_FLAGS -x"
fi

# Start simplex-chat daemon
echo "Starting simplex-chat daemon..."
CMD="simplex-chat -d \"$DATA_DIR/simplex\" -p 5225 $EXTRA_FLAGS"
echo "  $CMD"

eval "$CMD" > "$DATA_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!
echo "  PID: $DAEMON_PID"

# Wait for WebSocket port to be ready
for i in $(seq 1 15); do
    if ss -tlnp 2>/dev/null | grep -q 5225 || \
       nc -z 127.0.0.1 5225 2>/dev/null; then
        echo "WebSocket API ready on port 5225"
        break
    fi
    if [ $i -eq 15 ]; then
        echo "ERROR: simplex-chat failed to start. Logs:"
        tail -20 "$DATA_DIR/daemon.log"
        kill $DAEMON_PID 2>/dev/null
        exit 1
    fi
    sleep 1
done

# If this is first run, configure the bot address via WebSocket API
if [ ! -f "${DB_PREFIX}_v1_agent.db" ]; then
    sleep 2
    echo "Setting up bot address..."
    python3 -c "
import asyncio, json, websockets, os

async def setup():
    async with websockets.connect('ws://127.0.0.1:5225', open_timeout=10) as ws:
        await ws.send(json.dumps({'corrId': 's1', 'cmd': '/user'}))
        await asyncio.sleep(1)
        await ws.send(json.dumps({'corrId': 's2', 'cmd': '/ad'}))
        await asyncio.sleep(2)
        address = None
        for _ in range(10):
            try:
                evt = await asyncio.wait_for(ws.recv(), timeout=1)
                data = json.loads(evt)
                resp = data.get('resp', {})
                if resp.get('type') == 'userContactLinkCreated':
                    link = resp.get('connLinkContact', {})
                    address = link.get('connFullLink', link.get('connShortLink', ''))
                elif data.get('corrId') == 's2' and resp.get('type') == 'userContactLinkCreated':
                    link = resp.get('connLinkContact', {})
                    address = link.get('connFullLink', link.get('connShortLink', ''))
            except asyncio.TimeoutError:
                break
        if os.environ.get('SIMPLEX_AUTO_ACCEPT', 'true') == 'true':
            settings = json.dumps({'acceptIncognito': True, 'autoAccept': {'acceptIncognito': True}})
            await ws.send(json.dumps({'corrId': 's3', 'cmd': f'/address_settings 1 {settings}'}))
            await asyncio.sleep(1)
            try:
                evt = await asyncio.wait_for(ws.recv(), timeout=2)
                if 'userContactLinkUpdated' in evt:
                    print('Auto-accept enabled')
            except asyncio.TimeoutError:
                pass
        if address:
            with open('/data/bot_address.txt', 'w') as f:
                f.write(address + '\n')

asyncio.run(setup())
" 2>&1 | tee -a "$DATA_DIR/setup.log"
fi

# Optional socat bridge — exposes port 5225 on all interfaces
# for use with bridge networking (standard Unraid Docker setup).
# Set SIMPLEX_SOCAT_PORT=5225 to enable.
if [ -n "$SIMPLEX_SOCAT_PORT" ]; then
    echo "Starting socat bridge on 0.0.0.0:$SIMPLEX_SOCAT_PORT → 127.0.0.1:5225"
    socat TCP-LISTEN:"$SIMPLEX_SOCAT_PORT",reuseaddr,fork TCP:127.0.0.1:5225 &
    SOCAT_PID=$!
    echo "  socat PID: $SOCAT_PID"
fi

echo ""
echo "=== SimpleX Bridge ready ==="
echo "  Bot name: $SIMPLEX_DISPLAY_NAME"
if [ -f "$DATA_DIR/bot_address.txt" ]; then
    echo "  Bot address: $(cat $DATA_DIR/bot_address.txt)"
fi
echo ""

# Block forever waiting on the daemon
wait $DAEMON_PID
