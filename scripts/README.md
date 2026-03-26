# Linode Remote Dev Server Setup

Sets up a fresh Linode (Ubuntu) as a remote development environment with:
- **Katulong** - browser-based terminal, file browser, port proxy (accessible from iPhone Safari)
- **Sipag** - autonomous dev agent powered by Claude Code
- **Caddy** - reverse proxy with automatic Let's Encrypt HTTPS
- **Security hardening** - dedicated user, firewall, fail2ban, SSH lockdown

## Prerequisites

- Fresh Linode running Ubuntu (tested on 22.04/24.04)
- Root SSH access
- DNS A record: `dev.ryanzbone.com` → `<your-linode-ip>` (set in Linode DNS Manager)

## Usage

SSH into your Linode as root, then run each script in order:

```bash
# Clone or copy scripts to the server, then:
bash 00-preflight.sh    # Validate environment
bash 01-harden.sh       # Security: user, firewall, SSH, fail2ban
bash 02-install.sh      # Install: Node.js, Docker, Caddy, Katulong, Sipag
bash 03-configure.sh    # Configure: systemd services, Caddy TLS, sipag
```

## After Setup

1. Open `https://dev.ryanzbone.com` on your iPhone
2. Register your WebAuthn passkey
3. Start developing!

For Sipag, configure your API keys in `~/.sipag/.env` from the Katulong terminal.
