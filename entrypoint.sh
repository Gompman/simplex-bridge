#!/bin/bash
set -e -o pipefail

DATA_DIR="/data"
DB_PREFIX="$DATA_DIR/simplex"
DB_FILE="${DB_PREFIX}_v1_chat.db"

# ── Resolve PUID/PGID ──────────────────────────────────────────────
PUID="${PUID:-99}"
PGID="${PGID:-100}"
echo "[entrypoint] Using PUID=$PUID PGID=$PGID"

# Ensure the 'simplex' user/group matches the runtime-requested IDs.
# Only recreate if the existing user has a different UID/GID.
if getent passwd simplex >/dev/null 2>&1; then
    EXISTING_UID=$(id -u simplex 2>/dev/null)
    EXISTING_GID=$(id -g simplex 2>/dev/null)
    if [ "$EXISTING_UID" = "$PUID" ] && [ "$EXISTING_GID" = "$PGID" ]; then
        echo "[entrypoint] simplex user already has PUID=$PUID PGID=$PGID — no change needed"
    else
        echo "[entrypoint] Recreating simplex user (UID $EXISTING_UID → $PUID, GID $EXISTING_GID → $PGID)..."
        if getent group simplex >/dev/null 2>&1; then
            groupdel simplex 2>/dev/null || true
        fi
        if getent passwd simplex >/dev/null 2>&1; then
            userdel simplex 2>/dev/null || true
        fi
        groupadd --system --gid "$PGID" simplex 2>/dev/null || \
          groupadd --system simplex 2>/dev/null
        useradd --system --no-log-init -g simplex -u "$PUID" --create-home simplex
    fi
else
    groupadd --system --gid "$PGID" simplex 2>/dev/null || \
      groupadd --system simplex 2>/dev/null
    useradd --system --no-log-init -g simplex -u "$PUID" --create-home simplex
fi

# ── Graceful shutdown handler ──────────────────────────────────────
shutdown() {
    signal=$1
    echo "[entrypoint] Received $signal — forwarding to simplex-chat..."
    kill "$-$signal" "$DAEMON_PID" 2>/dev/null || true
    for i in $(seq 1 10); do
        if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
            echo "[entrypoint] simplex-chat exited cleanly"
            break
        fi
        sleep 1
    done
    if [ -n "${SOCAT_PID:-}" ]; then
        kill "$SOCAT_PID" 2>/dev/null || true
    fi
    echo "[entrypoint] Goodbye"
    exit 0
}

trap 'shutdown SIGTERM' SIGTERM
trap 'shutdown SIGINT'  SIGINT

# ── Timezone ───────────────────────────────────────────────────────
if [ -n "$TZ" ] && [ -f "/usr/share/zoneinfo/$TZ" ]; then
    ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
    echo "$TZ" > /etc/timezone
fi

# Fix data dir ownership so the runtime user can write to it
chown -R "$PUID:$PGID" "$DATA_DIR"

# ── Build extra flags (array — no shell re-parsing of env values) ──
FLAGS=(-d "$DATA_DIR/simplex" -p 5225)

# v7.x auto-migrates older DB schemas non-interactively with this flag;
# without it a v6-era data dir triggers an interactive Continue (y/N) prompt
# that dies headless.
FLAGS+=(-y)

if [ ! -f "$DB_FILE" ]; then
    echo "[entrypoint] First run: creating bot profile..."
    FLAGS+=(--create-bot-display-name "$SIMPLEX_DISPLAY_NAME")
    if [ "$SIMPLEX_FILES_ENABLED" = "true" ]; then
        FLAGS+=(--create-bot-allow-files)
    fi
fi

if [ "$SIMPLEX_MARK_READ" = "true" ]; then
    FLAGS+=(-r)
fi

if [ "$SIMPLEX_TOR" = "true" ]; then
    FLAGS+=(-x)
fi

# ── Start simplex-chat daemon as non-root user ─────────────────────
echo "[entrypoint] Starting simplex-chat daemon as UID $PUID..."
echo "[entrypoint]   simplex-chat ${FLAGS[*]}"

gosu "$PUID:$PGID" simplex-chat "${FLAGS[@]}" > "$DATA_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!
echo "[entrypoint]   PID: $DAEMON_PID"

WS_WAIT=45
for i in $(seq 1 "$WS_WAIT"); do
    if ss -tln 2>/dev/null | grep -q ':5225'; then
        echo "[entrypoint] WebSocket API ready on port 5225"
        break
    fi
    if [ "$i" -eq "$WS_WAIT" ]; then
        echo "[entrypoint] ERROR: simplex-chat failed to start within ${WS_WAIT}s"
        tail -10 "$DATA_DIR/daemon.log"
        kill "$DAEMON_PID" 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

SETUP_MARKER="$DATA_DIR/.setup-complete"
BOT_ADDRESS_FILE="$DATA_DIR/bot_address.txt"
if [ ! -f "$SETUP_MARKER" ] || [ ! -f "$BOT_ADDRESS_FILE" ]; then
    sleep 2
    echo "[entrypoint] Setting up bot address..."
    SETUP_LOG="$DATA_DIR/setup.log"
    # Live logs: python3 -u + tee. pipefail keeps python's exit status.
    if gosu "$PUID:$PGID" python3 -u - <<'PYEOF' 2>&1 | tee "$SETUP_LOG"
import asyncio
import json
import os
import socket
import sys
import time

import websockets


CREATE_ATTEMPTS = 5
NET_WAIT_S = 60
SMP_HOST = "smp4.simplex.im"
SMP_PORT = 5223
TOR_HOST = "127.0.0.1"
TOR_PORT = 9050


def log(msg):
    print(f"[setup] {msg}", flush=True)


def store_error_type(resp):
    if resp.get("type") != "chatCmdError":
        return None
    err = resp.get("chatError") or {}
    if err.get("type") != "errorStore":
        return None
    return (err.get("storeError") or {}).get("type")


def is_agent_error(resp):
    if resp.get("type") != "chatCmdError":
        return False
    return (resp.get("chatError") or {}).get("type") == "errorAgent"


def format_chat_error(resp):
    err = resp.get("chatError") or {}
    et = err.get("type", "?")
    parts = [f"type={et}"]
    if et == "errorStore":
        parts.append(f"storeError={(err.get('storeError') or {}).get('type', '?')}")
    elif et == "errorAgent":
        ae = err.get("agentError") or {}
        parts.append(f"agentError={ae.get('type', ae)}")
    else:
        et2 = err.get("errorType") or {}
        if isinstance(et2, dict):
            parts.append(f"errorType={et2.get('type', et2)}")
        elif et2:
            parts.append(f"errorType={et2}")
    return " ".join(parts)


def extract_link(conn_link):
    if not isinstance(conn_link, dict):
        return None
    return conn_link.get("connShortLink") or conn_link.get("connFullLink") or None


def address_from_resp(resp):
    t = resp.get("type")
    if t == "userContactLink":
        cl = (resp.get("contactLink") or {}).get("connLinkContact") or {}
        return extract_link(cl)
    if t == "userContactLinkCreated":
        return extract_link(resp.get("connLinkContact") or {})
    return None


def wait_tcp(host, port, timeout_s):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=3):
                return True
        except OSError:
            time.sleep(1)
    return False


async def recv_corr(ws, corr_id, timeout):
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"no response for corrId={corr_id} within {timeout}s")
        raw = await asyncio.wait_for(ws.recv(), timeout=remaining)
        data = json.loads(raw)
        if data.get("corrId") != corr_id:
            # Log non-response events so they are visible in setup logs
            log(f"event type={data.get('type', '?')} (non-response)")
            continue
        return data.get("resp") or {}


async def send_cmd(ws, corr_id, cmd, timeout):
    await ws.send(json.dumps({"corrId": corr_id, "cmd": cmd}))
    return await recv_corr(ws, corr_id, timeout)


async def show_address(ws, user_id):
    log("checking existing address (/_show_address)")
    return await send_cmd(ws, "show", f"/_show_address {user_id}", 15)


async def setup():
    use_tor = os.environ.get("SIMPLEX_TOR", "false") == "true"
    async with websockets.connect("ws://127.0.0.1:5225", open_timeout=10) as ws:
        log("connected to WebSocket")
        resp = await send_cmd(ws, "user", "/user", 15)
        if resp.get("type") == "chatCmdError":
            log(f"chatCmdError: {format_chat_error(resp)}")
            sys.exit(1)
        user = resp.get("user") or {}
        user_id = user.get("userId")
        if user_id is None:
            log(f"ERROR: no userId in /user response type={resp.get('type')}")
            sys.exit(1)
        log(f"active userId={user_id}")

        if use_tor:
            log(f"waiting for Tor SOCKS {TOR_HOST}:{TOR_PORT}")
            host, port = TOR_HOST, TOR_PORT
        else:
            log(f"waiting for SMP {SMP_HOST}:{SMP_PORT}")
            host, port = SMP_HOST, SMP_PORT
        if not await asyncio.to_thread(wait_tcp, host, port, NET_WAIT_S):
            log(f"ERROR: network not ready after {NET_WAIT_S}s")
            sys.exit(1)
        log("network ready")

        resp = await show_address(ws, user_id)
        se = store_error_type(resp)
        if resp.get("type") == "userContactLink":
            log("address already exists")
            address = address_from_resp(resp)
        elif se == "userContactLinkNotFound":
            log("no address yet (userContactLinkNotFound), creating")
            address = None
            for attempt in range(1, CREATE_ATTEMPTS + 1):
                log(f"creating address (/_address), attempt {attempt}/{CREATE_ATTEMPTS}")
                created = await send_cmd(ws, f"addr{attempt}", f"/_address {user_id}", 45)
                if created.get("type") == "userContactLinkCreated":
                    address = address_from_resp(created)
                    break
                cse = store_error_type(created)
                if cse == "duplicateContactLink":
                    log("duplicateContactLink — treating as success, re-fetching address")
                    shown = await show_address(ws, user_id)
                    if shown.get("type") == "chatCmdError":
                        log(f"chatCmdError: {format_chat_error(shown)}")
                        sys.exit(1)
                    address = address_from_resp(shown)
                    break
                if is_agent_error(created) and attempt < CREATE_ATTEMPTS:
                    log(f"chatCmdError: {format_chat_error(created)}")
                    await asyncio.sleep(2 ** attempt)
                    continue
                if created.get("type") == "chatCmdError":
                    log(f"chatCmdError: {format_chat_error(created)}")
                else:
                    log(f"ERROR: unexpected create response type={created.get('type')}")
                sys.exit(1)
        elif resp.get("type") == "chatCmdError":
            log(f"chatCmdError: {format_chat_error(resp)}")
            sys.exit(1)
        else:
            log(f"ERROR: unexpected show response type={resp.get('type')}")
            sys.exit(1)

        if not address:
            log("ERROR: no contact link received — setup will retry on next start")
            sys.exit(1)

        if os.environ.get("SIMPLEX_AUTO_ACCEPT", "true") == "true":
            settings = json.dumps(
                {"businessAddress": False, "autoAccept": {"acceptIncognito": False}}
            )
            upd = await send_cmd(
                ws, "aset", f"/_address_settings {user_id} {settings}", 15
            )
            if upd.get("type") == "userContactLinkUpdated":
                log("Auto-accept enabled")
            elif upd.get("type") == "chatCmdError":
                log(f"WARN: address settings failed: {format_chat_error(upd)}")
            else:
                log(f"WARN: address settings failed: type={upd.get('type')}")

        log(f"Bot address: {address}")
        with open("/data/bot_address.txt", "w") as f:
            f.write(address + "\n")


asyncio.run(setup())
PYEOF
    then
        if [ -f "$BOT_ADDRESS_FILE" ]; then
            touch "$SETUP_MARKER"
        else
            echo "[entrypoint] WARNING: first-run setup did not complete — will retry on next restart"
        fi
    else
        echo "[entrypoint] WARNING: first-run setup did not complete — will retry on next restart"
    fi
fi

# ── Optional socat bridge ──────────────────────────────────────────
# WARNING: When enabled, the WebSocket API becomes accessible from any
# IP that can reach the container on 0.0.0.0:$SIMPLEX_SOCAT_PORT.
# The simplex-chat WebSocket protocol has no built-in authentication.
# Only enable on trusted networks or behind a firewall.
# This feature is experimental — use at your own risk.
if [ -n "$SIMPLEX_SOCAT_PORT" ]; then
    case "$SIMPLEX_SOCAT_PORT" in
        ''|*[!0-9]*)
            echo "[entrypoint] ERROR: SIMPLEX_SOCAT_PORT must be a numeric TCP port (got: '$SIMPLEX_SOCAT_PORT')"
            exit 1
            ;;
    esac
    if [ "$SIMPLEX_SOCAT_PORT" -lt 1 ] || [ "$SIMPLEX_SOCAT_PORT" -gt 65535 ]; then
        echo "[entrypoint] ERROR: SIMPLEX_SOCAT_PORT must be between 1 and 65535 (got: $SIMPLEX_SOCAT_PORT)"
        exit 1
    fi
    echo "[entrypoint] *** WARNING: Exposing WebSocket API on 0.0.0.0:$SIMPLEX_SOCAT_PORT ***"
    echo "[entrypoint] *** No authentication — only use on trusted networks    ***"
    echo "[entrypoint] Starting socat bridge on 0.0.0.0:$SIMPLEX_SOCAT_PORT → 127.0.0.1:5225"
    socat "TCP-LISTEN:$SIMPLEX_SOCAT_PORT,reuseaddr,fork" TCP:127.0.0.1:5225 &
    SOCAT_PID=$!
    echo "[entrypoint]   socat PID: $SOCAT_PID"
fi

# ── Ready ──────────────────────────────────────────────────────────
echo ""
echo "=== SimpleX Bridge ready ==="
echo "  Bot name: $SIMPLEX_DISPLAY_NAME"
echo "  Running as: PUID=$PUID PGID=$PGID"
if [ -f "$DATA_DIR/bot_address.txt" ]; then
    echo "  Bot address: $(cat "$DATA_DIR/bot_address.txt")"
fi
echo ""

wait "$DAEMON_PID"
