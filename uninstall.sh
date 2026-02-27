#!/usr/bin/env bash
set -euo pipefail

# ─── Remnawave Monitoring — Uninstall Script ──────────────────────────────────

INSTALL_DIR="/opt/remnawave/monitoring"
LOG_DIR="/opt/remnawave/logs"
CRON_COMMENT="remnawave-sync-nodes"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root (use sudo)"
fi

echo -e "${YELLOW}═══ Remnawave Monitoring Uninstall ═══${NC}"
echo ""

# ─── Stop containers ─────────────────────────────────────────────────────────
if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
    info "Stopping Docker containers..."
    cd "$INSTALL_DIR"
    if docker compose version >/dev/null 2>&1; then
        docker compose down || true
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose down || true
    fi
    ok "Containers stopped"
else
    warn "docker-compose.yml not found, skipping container stop"
fi

# ─── Remove cron job ─────────────────────────────────────────────────────────
info "Removing cron job..."
(crontab -l 2>/dev/null | grep -v "$CRON_COMMENT" || true) | crontab -
ok "Cron job removed"

# ─── Ask about data removal ──────────────────────────────────────────────────
echo ""
read -rp "Delete Docker volumes (Prometheus & Grafana data)? [y/N]: " DELETE_VOLUMES
DELETE_VOLUMES="${DELETE_VOLUMES:-N}"

if [[ "$DELETE_VOLUMES" =~ ^[Yy]$ ]]; then
    info "Removing Docker volumes..."
    # Determine compose project name (directory name of INSTALL_DIR)
    PROJECT_NAME="$(basename "$INSTALL_DIR")"
    for vol in $(docker volume ls -q --filter "name=${PROJECT_NAME}_" 2>/dev/null); do
        docker volume rm "$vol" 2>/dev/null && ok "Removed volume: $vol" || warn "Failed to remove: $vol"
    done
    ok "Volume cleanup complete"
else
    info "Keeping Docker volumes"
fi

# ─── Ask about file removal ──────────────────────────────────────────────────
read -rp "Delete installation directory (${INSTALL_DIR})? [y/N]: " DELETE_FILES
DELETE_FILES="${DELETE_FILES:-N}"

if [[ "$DELETE_FILES" =~ ^[Yy]$ ]]; then
    info "Removing ${INSTALL_DIR}..."
    rm -rf "$INSTALL_DIR"
    ok "Installation directory removed"

    # Remove log dir if empty
    if [ -d "$LOG_DIR" ]; then
        rmdir "$LOG_DIR" 2>/dev/null && ok "Log directory removed" || info "Log directory not empty, keeping"
    fi

    # Remove parent dir if empty
    rmdir /opt/remnawave 2>/dev/null || true
else
    info "Keeping installation files"
fi

echo ""
echo -e "${GREEN}Remnawave Monitoring has been uninstalled.${NC}"
echo ""
