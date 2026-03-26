#!/usr/bin/env bash
set -euo pipefail

# Preflight checks for Linode remote dev server setup
# Run this first to validate the environment before making any changes.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

echo "=== Preflight Checks ==="
echo

# Must be root
if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root"
fi
pass "Running as root"

# Check OS
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "  OS: $PRETTY_NAME"
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        warn "Expected Ubuntu/Debian, got $ID. Scripts may need adjustment."
    else
        pass "OS is $ID $VERSION_ID"
    fi
else
    fail "/etc/os-release not found - cannot determine OS"
fi

# Check internet
if curl -sf --max-time 10 https://github.com > /dev/null 2>&1; then
    pass "Internet connectivity"
else
    fail "Cannot reach https://github.com - check network"
fi

# System info
echo
echo "=== System Info ==="
echo "  Hostname: $(hostname)"
echo "  Kernel:   $(uname -r)"
echo "  Arch:     $(uname -m)"
echo "  CPUs:     $(nproc)"

# RAM check
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
TOTAL_RAM_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL_RAM_MB / 1024}")
echo "  RAM:      ${TOTAL_RAM_GB}GB (${TOTAL_RAM_MB}MB)"
if [[ $TOTAL_RAM_MB -lt 2048 ]]; then
    warn "Less than 2GB RAM. Sipag Docker workers may struggle. Consider adding swap."
else
    pass "RAM is adequate"
fi

# Disk check
DISK_AVAIL_KB=$(df / | awk 'NR==2 {print $4}')
DISK_AVAIL_GB=$((DISK_AVAIL_KB / 1024 / 1024))
DISK_TOTAL_KB=$(df / | awk 'NR==2 {print $2}')
DISK_TOTAL_GB=$((DISK_TOTAL_KB / 1024 / 1024))
echo "  Disk:     ${DISK_AVAIL_GB}GB available / ${DISK_TOTAL_GB}GB total"
if [[ $DISK_AVAIL_GB -lt 20 ]]; then
    warn "Less than 20GB disk available. Docker images and dev tools need space."
else
    pass "Disk space is adequate"
fi

echo
echo "=== Preflight Complete ==="
echo "If everything looks good, proceed with: sudo bash 01-harden.sh"
