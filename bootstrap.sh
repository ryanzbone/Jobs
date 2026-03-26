#!/usr/bin/env bash
set -euo pipefail

# Single bootstrap script for Linode remote dev server setup
# Combines preflight, hardening, install, and configuration
#
# Usage: curl -fsSL https://raw.githubusercontent.com/ryanzbone/Jobs/claude/setup-linode-remote-dev-zWAza/bootstrap.sh | bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
section() { echo; echo -e "${BOLD}========================================${NC}"; echo -e "${BOLD}  $1${NC}"; echo -e "${BOLD}========================================${NC}"; echo; }

DOMAIN="dev.ryanzbone.com"

########################################
# PHASE 0: PREFLIGHT
########################################
section "Phase 0: Preflight Checks"

if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root"
fi
info "Running as root"

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    info "OS: $PRETTY_NAME"
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        warn "Expected Ubuntu/Debian, got $ID. Script may need adjustment."
    fi
else
    fail "/etc/os-release not found"
fi

if curl -sf --max-time 10 https://github.com > /dev/null 2>&1; then
    info "Internet connectivity OK"
else
    fail "Cannot reach https://github.com"
fi

TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
info "RAM: ${TOTAL_RAM_MB}MB | CPUs: $(nproc) | Disk avail: $(df -h / | awk 'NR==2{print $4}')"

if [[ $TOTAL_RAM_MB -lt 2048 ]]; then
    warn "Less than 2GB RAM - Docker workers may struggle"
fi

########################################
# PHASE 1: SECURITY HARDENING
########################################
section "Phase 1: Security Hardening"

info "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt update -qq
apt -y -qq -o Dpkg::Options::="--force-confold" upgrade
info "System updated"

# Create claude user
if id "claude" &>/dev/null; then
    warn "User 'claude' already exists"
else
    useradd -m -s /bin/bash -G sudo claude
    CLAUDE_PASS=$(openssl rand -base64 16)
    echo "claude:${CLAUDE_PASS}" | chpasswd
    info "User 'claude' created"
    echo
    echo -e "  ${BOLD}Password for claude:${NC} ${CLAUDE_PASS}"
    echo -e "  ${YELLOW}Save this now! Change later with: sudo passwd claude${NC}"
    echo
fi

mkdir -p /home/claude/.ssh
chmod 700 /home/claude/.ssh
if [[ -f /root/.ssh/authorized_keys ]] && [[ -s /root/.ssh/authorized_keys ]]; then
    cp /root/.ssh/authorized_keys /home/claude/.ssh/authorized_keys
    chmod 600 /home/claude/.ssh/authorized_keys
    info "Copied root SSH keys to claude"
fi
chown -R claude:claude /home/claude/.ssh

# SSH hardening
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d) 2>/dev/null || true
cat > /etc/ssh/sshd_config.d/hardening.conf << 'SSHEOF'
PermitRootLogin prohibit-password
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
SSHEOF

HAS_KEYS=false
if [[ -f /home/claude/.ssh/authorized_keys ]] && [[ -s /home/claude/.ssh/authorized_keys ]]; then
    HAS_KEYS=true
fi
if [[ -f /root/.ssh/authorized_keys ]] && [[ -s /root/.ssh/authorized_keys ]]; then
    HAS_KEYS=true
fi
if [[ "$HAS_KEYS" == "true" ]]; then
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config.d/hardening.conf
    info "Password auth disabled (SSH keys found)"
else
    warn "No SSH keys - password auth stays enabled"
    warn "Add keys later, then: echo 'PasswordAuthentication no' | sudo tee -a /etc/ssh/sshd_config.d/hardening.conf && sudo systemctl restart sshd"
fi
systemctl restart sshd
info "SSH hardened"

# fail2ban
apt install -y -qq fail2ban
cat > /etc/fail2ban/jail.local << 'F2BEOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
F2BEOF
systemctl enable --now fail2ban
info "fail2ban active"

# Firewall
apt install -y -qq ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP - LE challenge'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable
info "Firewall: ports 22, 80, 443 only"

########################################
# PHASE 2: INSTALL SOFTWARE
########################################
section "Phase 2: Installing Software"

apt install -y -qq tmux curl git build-essential ca-certificates gnupg python3
info "Base packages installed"

# Node.js 22
if command -v node &>/dev/null; then
    warn "Node.js already installed: $(node --version)"
else
    info "Installing Node.js 22..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt install -y -qq nodejs
    info "Node.js $(node --version) installed"
fi

# Docker
if command -v docker &>/dev/null; then
    warn "Docker already installed"
else
    info "Installing Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update -qq
    apt install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    info "Docker installed"
fi
usermod -aG docker claude
info "claude added to docker group"

# Caddy
if command -v caddy &>/dev/null; then
    warn "Caddy already installed"
else
    info "Installing Caddy..."
    apt install -y -qq debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
        gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
        tee /etc/apt/sources.list.d/caddy-stable.list
    apt update -qq
    apt install -y -qq caddy
    info "Caddy installed"
fi
systemctl stop caddy 2>/dev/null || true

# Katulong
if command -v katulong &>/dev/null; then
    warn "Katulong already installed"
else
    info "Installing Katulong..."
    curl -fsSL https://raw.githubusercontent.com/dorky-robot/katulong/main/install.sh | sh
    info "Katulong installed"
fi

# Sipag
if command -v sipag &>/dev/null; then
    warn "Sipag already installed"
else
    info "Installing Sipag..."
    curl -fsSL https://raw.githubusercontent.com/Dorky-Robot/sipag/main/scripts/install.sh | sh
    info "Sipag installed"
fi

# Claude Code
if command -v claude &>/dev/null; then
    warn "Claude Code already installed"
else
    info "Installing Claude Code CLI..."
    npm install -g @anthropic-ai/claude-code
    info "Claude Code installed"
fi

########################################
# PHASE 3: CONFIGURE SERVICES
########################################
section "Phase 3: Configuring Services"

# DNS check
info "Checking DNS for $DOMAIN..."
RESOLVED_IP=$(dig +short "$DOMAIN" 2>/dev/null || true)
if [[ -z "$RESOLVED_IP" ]]; then
    warn "$DOMAIN doesn't resolve yet - Caddy will retry automatically"
else
    info "$DOMAIN resolves to $RESOLVED_IP"
fi

# Katulong data dir
mkdir -p /home/claude/.katulong
chown claude:claude /home/claude/.katulong

# Katulong systemd service
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
sleep 2
if systemctl is-active --quiet katulong; then
    info "Katulong running on port 3001"
else
    warn "Katulong may not have started - check: journalctl -u katulong -n 20"
fi

# Caddy
if [[ -f /etc/caddy/Caddyfile ]]; then
    cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.backup.$(date +%Y%m%d) 2>/dev/null || true
fi
cat > /etc/caddy/Caddyfile << EOF
${DOMAIN} {
    reverse_proxy localhost:3001
}
EOF

systemctl enable --now caddy
systemctl restart caddy
sleep 2
if systemctl is-active --quiet caddy; then
    info "Caddy running with auto-HTTPS for $DOMAIN"
else
    warn "Caddy may not have started - check: journalctl -u caddy -n 20"
fi

# Sipag config
mkdir -p /home/claude/.sipag
cat > /home/claude/.sipag/.env.example << 'EOF'
# Copy to .env and fill in:
# ANTHROPIC_API_KEY=sk-ant-...
# GITHUB_TOKEN=ghp_...
EOF
chown -R claude:claude /home/claude/.sipag
info "Sipag config dir ready"

########################################
# DONE
########################################
section "Setup Complete!"

echo "Service Status:"
echo "  Katulong: $(systemctl is-active katulong 2>/dev/null || echo 'inactive')"
echo "  Caddy:    $(systemctl is-active caddy 2>/dev/null || echo 'inactive')"
echo "  Docker:   $(systemctl is-active docker 2>/dev/null || echo 'inactive')"
echo
echo "Firewall:"
ufw status | head -10
echo

CURL_RESULT=$(curl -sf --max-time 5 http://localhost:3001 > /dev/null 2>&1 && echo "OK" || echo "waiting")
echo "Katulong local: $CURL_RESULT"
echo

echo -e "${BOLD}Next steps:${NC}"
echo
echo -e "  1. Open ${GREEN}https://${DOMAIN}${NC} on your iPhone"
echo "  2. Register your passkey (first time only)"
echo "  3. You're in!"
echo
echo "  For Sipag: cp ~/.sipag/.env.example ~/.sipag/.env"
echo "  Then edit with your API keys"
echo
echo -e "${BOLD}Useful commands:${NC}"
echo "  journalctl -u katulong -f"
echo "  journalctl -u caddy -f"
echo "  systemctl restart katulong"
echo "  systemctl restart caddy"

if [[ -z "$RESOLVED_IP" ]]; then
    echo
    echo -e "${YELLOW}DNS hasn't propagated yet. Caddy will auto-provision"
    echo -e "the TLS cert once it does. Watch with: journalctl -u caddy -f${NC}"
fi
