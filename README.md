# simplex-bridge

**SimpleX Chat bot daemon — WebSocket API for Hermes Agent and messaging bots**

Run a SimpleX Chat bot as a Docker container. On first start it creates a bot profile and connection address. Connect your Hermes Agent or custom bot framework via WebSocket.

## What is SimpleX Chat?

SimpleX Chat is a fully private, decentralised messaging network. Unlike Signal, Telegram, or WhatsApp, it has **no persistent user identifiers** — no phone numbers, usernames, or IDs. Every connection uses unique, ephemeral queues. Even the servers cannot determine who is talking to whom.

This container runs the [SimpleX Chat CLI](https://github.com/simplex-chat/simplex-chat) in WebSocket server mode (`-p 5225`), giving your bot framework a JSON-based API to send and receive messages.

## Quick Start

```bash
# Run with host networking (simplest — daemon binds to 127.0.0.1)
docker run -d \
  --name simplex-bridge \
  --network host \
  -v simplex-data:/data \
  ghcr.io/libre-7/simplex-bridge:latest

# Get the bot address to share with contacts
cat $(docker volume inspect simplex-data --format '{{.Mountpoint}}')/bot_address.txt
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SIMPLEX_DISPLAY_NAME` | `Simplex Bridge` | Name shown to contacts connecting to your bot |
| `SIMPLEX_AUTO_ACCEPT` | `true` | Auto-accept incoming contact requests |
| `SIMPLEX_FILES_ENABLED` | `true` | Allow file transfers from contacts |
| `SIMPLEX_MARK_READ` | `true` | Auto-mark received messages as read |
| `SIMPLEX_TOR` | `false` | Route through Tor SOCKS5 proxy (requires Tor on port 9050) |
| `SIMPLEX_SOCAT_PORT` | (empty) | Set to `5225` to expose WebSocket on all interfaces via socat bridge |
| `TZ` | `UTC` | Container timezone |

### Network Configuration

The daemon binds to `127.0.0.1:5225` only (security by design). Two networking options:

**Host networking** (recommended): Both containers share the host's loopback. Hermes connects to `ws://127.0.0.1:5225`. Set `--network host` on both containers.

**Bridge networking** (alternative): Set `SIMPLEX_SOCAT_PORT=5225` to start a socat proxy that forwards `0.0.0.0:5225 → 127.0.0.1:5225`. Hermes connects to `ws://<unraid-ip>:5225`. Use `-p 5225:5225` to expose the port.

## Integration with Hermes Agent

Hermes Agent ships a built-in SimpleX Chat plugin — no code needed.

1. **Fix the missing plugin.yaml** (one-time, until the Hermes image is updated):
   ```bash
   docker exec hermes-webui bash -c 'cp \
     /home/hermeswebui/.hermes/hermes-agent/plugins/platforms/simplex/plugin.yaml \
     /app/venv/lib/python3.12/site-packages/plugins/platforms/simplex/plugin.yaml'
   ```

2. **Set env vars** on the Hermes WebUI container:
   ```
   SIMPLEX_WS_URL=ws://127.0.0.1:5225
   SIMPLEX_ALLOW_ALL_USERS=true
   SIMPLEX_HOME_CHANNEL=1
   ```
   (Use `<unraid-ip>` instead of `127.0.0.1` with socat bridge.)

3. **Restart the Hermes gateway**:
   ```bash
   docker exec hermes-webui /app/venv/bin/hermes gateway restart
   ```

4. **Share your bot address** (from `/data/bot_address.txt` inside the simplex container) with contacts via any other channel.

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

This container is designed for Unraid's Community Apps. Once approved in CA:

1. Install from **Apps** → search "simplex-bridge"
2. Set desired env vars in the template
3. Start the container
4. Read the bot address from `/mnt/user/appdata/simplex-bridge/bot_address.txt`

### Required Unraid Template Fields

The template automatically configures:
- Port: `5225` (WebSocket API)
- Volume: `/mnt/user/appdata/simplex-bridge` → `/data`
- Network: `bridge` (use `SIMPLEX_SOCAT_PORT=5225` for external access)

## Bot Address Format

The bot address looks like:

```
simplex:/contact#/?v=2-7&smp=smp%3A%2F%2F...%3D%40smp4.simplex.im%2F...%23%2F%3Fv%3D...
```

You share this once with each contact via any other channel (email, another messenger, QR code, NFC). Each use creates a permanent end-to-end encrypted connection. The address is single-use by default — create a new one with `/ad` for each contact.

## FAQ

**Q: Can I use this without Hermes Agent?**
Yes — any program that speaks WebSocket JSON can use the API. See the [SimpleX Bot API docs](https://github.com/simplex-chat/simplex-chat/blob/stable/bots/README.md).

**Q: How is this different from a Telegram/Discord bot?**
SimpleX has no central servers that know who users are. There are no phone numbers, no usernames, no IPs logged. Your bot exists on a peer-to-peer network where only your contacts know it exists.

**Q: Can I run multiple bots?**
Yes — use separate data directories (volumes) and ports. The WebSocket API supports multiple users.

## License

MIT
