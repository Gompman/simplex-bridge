# simplex-bridge

**SimpleX Chat bot daemon — WebSocket API for Hermes Agent and messaging bots**

[![Docker](https://github.com/libre-7/simplex-bridge/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/libre-7/simplex-bridge/actions/workflows/docker-publish.yml)
[![Docker Hub](https://img.shields.io/docker/pulls/libre7/simplex-bridge?label=Docker%20Hub)](https://hub.docker.com/r/libre7/simplex-bridge)
[![GHCR](https://img.shields.io/badge/GHCR-libre--7%2Fsimplex--bridge-blue?logo=github)](https://ghcr.io/libre-7/simplex-bridge)
[![License](https://img.shields.io/github/license/libre-7/simplex-bridge)](LICENSE)

---

Run a SimpleX Chat bot as a Docker container. On first start it creates a bot profile and connection address. Connect your [Hermes Agent](https://github.com/nousresearch/hermes-agent) or custom bot framework via WebSocket.

| Registry | Pull Command |
|----------|-------------|
| **GitHub Container Registry** (primary) | `docker pull ghcr.io/libre-7/simplex-bridge:latest` |
| **Docker Hub** | `docker pull libre7/simplex-bridge:latest` |

## What is SimpleX Chat?


SimpleX Chat is a fully private, decentralised messaging network. Unlike Signal, Telegram, or WhatsApp, it has **no persistent user identifiers** — no phone numbers, usernames, or IDs. Every connection uses unique, ephemeral queues. Even the servers cannot determine who is talking to whom.

This container runs the [SimpleX Chat CLI](https://github.com/simplex-chat/simplex-chat) in WebSocket server mode (`-p 5225`), giving your bot framework a JSON-based API to send and receive messages.

## Quick Start

```bash
docker run -d \
  --name simplex-bridge \
  --network host \
  -v simplex-data:/data \
  libre7/simplex-bridge:latest

# Get the bot address to share with contacts
cat $(docker volume inspect simplex-data --format '{{.Mountpoint}}')/bot_address.txt
```

## Images

| Registry | Pull URL | Latest Tag |
|----------|----------|------------|
| **Docker Hub** | `docker pull libre7/simplex-bridge` | `latest`, `sha-<commit>` |
| **GitHub Container Registry** | `docker pull ghcr.io/libre-7/simplex-bridge` | `latest`, `sha-<commit>`, `v*` |

Tags are automatically built and pushed on every push to `main`:
- **`latest`** — most recent commit on `main`
- **`sha-<7char>`** — immutable commit hash (use this for pinning in production)
- **`vX.Y.Z`** — Git tag releases

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SIMPLEX_DISPLAY_NAME` | `Simplex Bridge` | Name shown to contacts connecting to your bot |
| `SIMPLEX_AUTO_ACCEPT` | `true` | Auto-accept incoming contact requests |
| `SIMPLEX_FILES_ENABLED` | `true` | Allow file transfers from contacts |
| `SIMPLEX_MARK_READ` | `true` | Auto-mark received messages as read |
| `SIMPLEX_TOR` | `false` | Route through Tor SOCKS5 proxy (requires Tor on port 9050) |
| `SIMPLEX_SOCAT_PORT` | (empty) | Set to `5225` to expose WebSocket on all interfaces via socat bridge |
| `PUID` | `99` | User ID for file permissions (Unraid: 99) |
| `PGID` | `100` | Group ID for file permissions (Unraid: 100) |
| `TZ` | `UTC` | Container timezone |

### Network Configuration

The daemon binds to `127.0.0.1:5225` only (security by design). The Unraid template defaults to host networking so Hermes connects via `ws://127.0.0.1:5225` directly.

**Bridge networking** (alternative): Set `SIMPLEX_SOCAT_PORT=5225` to start a socat proxy that forwards `0.0.0.0:5225 → 127.0.0.1:5225`. When using bridge, also change the Unraid template network type from `host` to `bridge` and set `-p 5225:5225`.

### Tagging & Pinning

For production stability, pin to a SHA tag (immutable):

```yaml
# docker-compose.yml
image: ghcr.io/libre-7/simplex-bridge:sha-a1b2c3d
```

SHA tags never change — the same commit always produces the same binary. The `latest` tag follows `main`.

## Integration with Hermes Agent

Hermes Agent ships a built-in SimpleX Chat plugin but the shipped version has bugs that prevent it from working correctly. Apply the one-command patch script after each Hermes container update.

### One-command patch

```bash
curl -fsSL https://raw.githubusercontent.com/libre-7/simplex-bridge/main/patch-hermes-simplex.sh | bash
docker exec hermes-webui /app/venv/bin/hermes gateway restart
```

The script installs `websockets`, copies the missing `plugin.yaml`, and fixes:
- **Inbound**: messages were silently dropped (wrong `chatItems` nesting)
- **Outbound**: replies used CLI format instead of the `/_send` API command
- **composedMessages**: payload was a single object instead of a JSON array

### Environment variables

Set these on the Hermes WebUI container:

```
SIMPLEX_WS_URL=ws://127.0.0.1:5225
SIMPLEX_ALLOW_ALL_USERS=true
SIMPLEX_HOME_CHANNEL=1
```

(Use `ws://<unraid-ip>:5225` with socat bridge.)

### Share your bot address

```bash
docker logs simplex-bridge | grep "Bot address"
```

Or read `/mnt/user/appdata/simplex-bridge/bot_address.txt`.

## Docker Compose

```yaml
services:
  simplex-bridge:
    image: ghcr.io/libre-7/simplex-bridge:latest
    container_name: simplex-bridge
    network_mode: host
    volumes:
      - simplex-data:/data
    environment:
      SIMPLEX_DISPLAY_NAME: "My Bot"
      SIMPLEX_AUTO_ACCEPT: "true"
    restart: unless-stopped

volumes:
  simplex-data:
```

## Unraid / Community Applications

This container is designed for Unraid's Community Apps.

1. Install from **Apps** → search "simplex-bridge"
2. Set desired env vars in the template
3. Start the container
4. Read bot address from `/mnt/user/appdata/simplex-bridge/bot_address.txt`

The Unraid template:
- Defaults to **host networking** (simplex binds to 127.0.0.1)
- Bridges WebSocket externally via `SIMPLEX_SOCAT_PORT` env var
- Persists database to `/mnt/user/appdata/simplex-bridge`
- Runs as `PUID=99 PGID=100` (Unraid defaults)

## Bot Address Format

```
simplex:/contact#/?v=2-7&smp=smp%3A%2F%2F...%3D%40smp4.simplex.im%2F...
```

Share this once with each contact via any other channel (email, another messenger, QR code). Each use creates a permanent end-to-end encrypted connection.

## FAQ

**Q: Can I use this without Hermes Agent?**
Yes — any program that speaks WebSocket JSON can use the API. See the [SimpleX Bot API docs](https://github.com/simplex-chat/simplex-chat/blob/stable/bots/README.md).

**Q: What platforms does this support?**
`linux/amd64` only. The `simplex-chat` upstream binary is distributed as an x86_64 Ubuntu executable — no ARM64 build is published.

**Q: How is this different from a Telegram/Discord bot?**
SimpleX has no central servers that know who users are. No phone numbers, no usernames, no IPs logged. Your bot exists on a peer-to-peer network where only your contacts know it exists.

**Q: What port does this use?**
Port 5225 for the WebSocket API. With host networking, no port mapping is needed. With bridge networking, map `-p 5225:5225` and set `SIMPLEX_SOCAT_PORT=5225`.

**Q: Can I run multiple bots?**
Yes — use separate data directories and ports.

## Building from Source

```bash
docker build -t simplex-bridge .
docker run --rm --network host -v $PWD/data:/data simplex-bridge
```

## License

GNU General Public License v3.0

## Tags Reference

| Tag | When | Stability |
|-----|------|-----------|
| `latest` | Every push to `main` | Rolling |
| `sha-<commit>` | Every push to `main` | ✅ Immutable |
| `vX.Y.Z` | Git tag pushed | ✅ Immutable, versioned |
