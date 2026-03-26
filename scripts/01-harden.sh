#!/usr/bin/env bash
set -euo pipefail

# Security hardening, user creation, and firewall setup
# Run as root after 00-preflight.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
section() { echo; echo -e "${BOLD}=== $1 ===${NC}"; }

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[FAIL]${NC} Must be run as root"
    exit 1
fi

section "System Update"
apt update -qq
apt upgrade -y -qq
info "System packages updated"

section "Create claude User"
if id "claude" &>/dev/null; then
    warn "User 'claude' already exists, skipping creation"
else
    useradd -m -s /bin/bash -G sudo claude
    # Generate a random password and set it
    CLAUDE_PASS=$(openssl rand -base64 16)
    echo "claude:${CLAUDE_PASS}" | chpasswd
    info "User 'claude' created with sudo access"
    echo
    echo -e "  ${BOLD}Temporary password for claude:${NC} ${CLAUDE_PASS}"
    echo -e "  ${YELLOW}Save this! You'll need it for initial SSH login as claude.${NC}"
    echo -e "  ${YELLOW}Change it after setting up SSH keys: sudo passwd claude${NC}"
    echo
fi

# Ensure claude has a .ssh directory
mkdir -p /home/claude/.ssh
chmod 700 /home/claude/.ssh

# Copy root's authorized_keys if they exist
if [[ -f /root/.ssh/authorized_keys ]] && [[ -s /root/.ssh/authorized_keys ]]; then
    cp /root/.ssh/authorized_keys /home/claude/.ssh/authorized_keys
    chmod 600 /home/claude/.ssh/authorized_keys
    info "Copied root's SSH keys to claude user"
fi
chown -R claude:claude /home/claude/.ssh

section "SSH Hardening"
# Back up original config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d)
info "Backed up sshd_config"

# Create hardening drop-in config
cat > /etc/ssh/sshd_config.d/hardening.conf << 'SSHEOF'
# Security hardening - installed by setup script
PermitRootLogin prohibit-password
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
SSHEOF
info "SSH hardening config installed"

# Check if there are SSH keys - only disable password auth if keys exist
HAS_KEYS=false
if [[ -f /home/claude/.ssh/authorized_keys ]] && [[ -s /home/claude/.ssh/authorized_keys ]]; then
    HAS_KEYS=true
fi
if [[ -f /root/.ssh/authorized_keys ]] && [[ -s /root/.ssh/authorized_keys ]]; then
    HAS_KEYS=true
fi

if [[ "$HAS_KEYS" == "true" ]]; then
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config.d/hardening.conf
    info "Password authentication disabled (SSH keys detected)"
else
    warn "No SSH keys found - password auth remains ENABLED"
    warn "After adding your SSH key, run:"
    warn "  echo 'PasswordAuthentication no' | sudo tee -a /etc/ssh/sshd_config.d/hardening.conf"
    warn "  sudo systemctl restart sshd"
fi

# Restart SSH
systemctl restart sshd
info "SSH service restarted"

section "Fail2ban"
apt install -y -qq fail2ban
# Create local config so it persists across package updates
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
info "fail2ban installed and configured"

section "Firewall (ufw)"
apt install -y -qq ufw

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP - Let'\''s Encrypt challenge'
ufw allow 443/tcp comment 'HTTPS - Caddy reverse proxy'

ufw --force enable
info "Firewall enabled"
echo
ufw status verbose
echo

section "Summary"
info "claude user created with sudo access"
info "SSH hardened (root login key-only, max 3 attempts)"
info "fail2ban active on SSH"
info "Firewall: only ports 22, 80, 443 open"
if [[ "$HAS_KEYS" != "true" ]]; then
    echo
    warn "ACTION REQUIRED: Add your SSH public key to /home/claude/.ssh/authorized_keys"
    warn "Then disable password auth (see instructions above)"
fi
echo
echo -e "Next step: ${BOLD}sudo bash 02-install.sh${NC}"
