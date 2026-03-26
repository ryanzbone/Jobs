#!/usr/bin/env bash
set -euo pipefail

# Configure services: Katulong systemd service, Caddy reverse proxy, Sipag config
# Run as root after 02-install.sh
# PRE-REQUISITE: DNS A record for dev.ryanzbone.com -> 45.79.168.176 must exist

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

DOMAIN="dev.ryanzbone.com"

info() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
section() { echo; echo -e "${BOLD}=== $1 ===${NC}"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[FAIL]${NC} Must be run as root"
    exit 1
fi

section "DNS Check"
echo "Checking if $DOMAIN resolves..."
RESOLVED_IP=$(dig +short "$DOMAIN" 2>/dev/null || true)
if [[ -z "$RESOLVED_IP" ]]; then
    warn "$DOMAIN does not resolve yet."
    warn "Add an A record in Linode DNS Manager: dev -> 45.79.168.176"
    warn "DNS can take a few minutes to propagate. Caddy will retry automatically."
else
    info "$DOMAIN resolves to $RESOLVED_IP"
fi

section "Katulong Data Directory"
mkdir -p /home/claude/.katulong
chown claude:claude /home/claude/.katulong
info "Created /home/claude/.katulong"

section "Katulong systemd Service"
cat > /etc/systemd/system/katulong.service << 'EOF'
[Unit]
Description=Katulong Web Terminal
After=network.target

[Service]
Type=simple
User=claude
Group=claude
Environment=PORT=3001
Environment=KATULONG_DATA_DIR=/home/claude/.katulong
Environment=SHELL=/bin/bash
ExecStart=/usr/local/bin/katulong
Restart=on-failure
RestartSec=5
WorkingDirectory=/home/claude

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now katulong
info "Katulong service enabled and started"

# Give it a moment to start
sleep 2

# Verify it's running
if systemctl is-active --quiet katulong; then
    info "Katulong is running on port 3001"
else
    warn "Katulong may not have started correctly. Check: journalctl -u katulong -n 20"
fi

section "Caddy Reverse Proxy"
# Back up existing Caddyfile
if [[ -f /etc/caddy/Caddyfile ]]; then
    cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.backup.$(date +%Y%m%d)
fi

cat > /etc/caddy/Caddyfile << EOF
${DOMAIN} {
    reverse_proxy localhost:3001
}
EOF

info "Caddyfile configured for $DOMAIN with automatic HTTPS"

systemctl enable --now caddy
systemctl restart caddy
sleep 2

if systemctl is-active --quiet caddy; then
    info "Caddy is running"
else
    warn "Caddy may not have started. Check: journalctl -u caddy -n 20"
    warn "This is often because DNS hasn't propagated yet. Caddy will retry."
fi

section "Sipag Configuration"
mkdir -p /home/claude/.sipag
cat > /home/claude/.sipag/.env.example << 'EOF'
# Sipag environment - copy to .env and fill in values
# ANTHROPIC_API_KEY=sk-ant-...
# GITHUB_TOKEN=ghp_...
EOF
chown -R claude:claude /home/claude/.sipag
info "Sipag config directory created at /home/claude/.sipag"

section "Final Verification"
echo
echo "Service Status:"
echo "  Katulong: $(systemctl is-active katulong 2>/dev/null || echo 'inactive')"
echo "  Caddy:    $(systemctl is-active caddy 2>/dev/null || echo 'inactive')"
echo "  Docker:   $(systemctl is-active docker 2>/dev/null || echo 'inactive')"
echo
echo "Firewall:"
ufw status | grep -E "^(22|80|443|Status)" || ufw status
echo
echo "Local test:"
CURL_RESULT=$(curl -sf --max-time 5 http://localhost:3001 > /dev/null 2>&1 && echo "OK" || echo "FAILED")
echo "  Katulong on localhost:3001: $CURL_RESULT"

section "Setup Complete!"
echo
echo -e "${BOLD}Access your dev environment:${NC}"
echo -e "  ${GREEN}https://${DOMAIN}${NC}"
echo
echo -e "${BOLD}From your iPhone Safari:${NC}"
echo "  1. Open https://${DOMAIN}"
echo "  2. Register your passkey (WebAuthn - first time only)"
echo "  3. You now have terminal, file browser, and port proxy access"
echo
echo -e "${BOLD}Sipag setup (from Katulong terminal):${NC}"
echo "  1. cp ~/.sipag/.env.example ~/.sipag/.env"
echo "  2. Edit ~/.sipag/.env with your ANTHROPIC_API_KEY and GITHUB_TOKEN"
echo "  3. Run: sipag configure <your-repo>"
echo "  4. Run: sipag dispatch <task>"
echo
if [[ -z "$RESOLVED_IP" ]]; then
    echo -e "${YELLOW}NOTE: DNS for $DOMAIN hasn't propagated yet.${NC}"
    echo -e "${YELLOW}Caddy will automatically provision the TLS certificate once DNS resolves.${NC}"
    echo -e "${YELLOW}Check status with: journalctl -u caddy -f${NC}"
    echo
fi
echo -e "${BOLD}Useful commands:${NC}"
echo "  journalctl -u katulong -f    # Katulong logs"
echo "  journalctl -u caddy -f       # Caddy logs"
echo "  systemctl restart katulong   # Restart Katulong"
echo "  systemctl restart caddy      # Restart Caddy"
