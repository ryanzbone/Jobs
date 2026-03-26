#!/usr/bin/env bash
set -euo pipefail

# Install all dependencies: Node.js, Docker, Caddy, Katulong, Sipag, Claude Code
# Run as root after 01-harden.sh

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

section "System Packages"
apt install -y -qq tmux curl git build-essential ca-certificates gnupg python3
info "Base packages installed"

section "Node.js 22 (via NodeSource)"
if command -v node &>/dev/null; then
    NODE_VER=$(node --version)
    warn "Node.js already installed: $NODE_VER"
else
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt install -y -qq nodejs
    info "Node.js $(node --version) installed"
fi

section "Docker Engine"
if command -v docker &>/dev/null; then
    warn "Docker already installed: $(docker --version)"
else
    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt update -qq
    apt install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    info "Docker $(docker --version) installed"
fi

# Add claude to docker group
usermod -aG docker claude
info "claude user added to docker group"

section "Caddy"
if command -v caddy &>/dev/null; then
    warn "Caddy already installed: $(caddy version)"
else
    apt install -y -qq debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
        gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
        tee /etc/apt/sources.list.d/caddy-stable.list
    apt update -qq
    apt install -y -qq caddy
    info "Caddy $(caddy version) installed"
fi

# Stop caddy for now - we'll configure it in script 03
systemctl stop caddy 2>/dev/null || true

section "Katulong"
if command -v katulong &>/dev/null; then
    warn "Katulong already installed"
else
    curl -fsSL https://raw.githubusercontent.com/dorky-robot/katulong/main/install.sh | sh
    info "Katulong installed"
fi

section "Sipag"
if command -v sipag &>/dev/null; then
    warn "Sipag already installed"
else
    curl -fsSL https://raw.githubusercontent.com/Dorky-Robot/sipag/main/scripts/install.sh | sh
    info "Sipag installed"
fi

section "Claude Code CLI"
if command -v claude &>/dev/null; then
    warn "Claude Code already installed: $(claude --version 2>/dev/null || echo 'unknown version')"
else
    npm install -g @anthropic-ai/claude-code
    info "Claude Code CLI installed"
fi

section "Verification"
echo "  Node.js:     $(node --version 2>/dev/null || echo 'NOT FOUND')"
echo "  npm:         $(npm --version 2>/dev/null || echo 'NOT FOUND')"
echo "  Docker:      $(docker --version 2>/dev/null || echo 'NOT FOUND')"
echo "  Caddy:       $(caddy version 2>/dev/null || echo 'NOT FOUND')"
echo "  tmux:        $(tmux -V 2>/dev/null || echo 'NOT FOUND')"
echo "  git:         $(git --version 2>/dev/null || echo 'NOT FOUND')"
echo "  Katulong:    $(katulong --version 2>/dev/null || command -v katulong 2>/dev/null || echo 'NOT FOUND')"
echo "  Sipag:       $(sipag --version 2>/dev/null || command -v sipag 2>/dev/null || echo 'NOT FOUND')"
echo "  Claude Code: $(claude --version 2>/dev/null || command -v claude 2>/dev/null || echo 'NOT FOUND')"

echo
info "All software installed"
echo
echo -e "Next step: ${BOLD}sudo bash 03-configure.sh${NC}"
echo -e "  ${YELLOW}Make sure you've added the DNS A record first:${NC}"
echo -e "  ${YELLOW}  dev.ryanzbone.com -> 45.79.168.176${NC}"
