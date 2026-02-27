#!/usr/bin/env bash
set -euo pipefail

# ─── Remnawave Monitoring — Installation Script ───────────────────────────────
# Usage:
#   bash <(curl -sSL https://raw.githubusercontent.com/alkhilaev/monitoring/main/setup.sh)
# ──────────────────────────────────────────────────────────────────────────────

VERSION="1.0.0"
INSTALL_DIR="/opt/remnawave/monitoring"
LOG_DIR="/opt/remnawave/logs"
REPO_URL="https://github.com/alkhilaev/monitoring.git"
REPO_BRANCH="main"
CRON_COMMENT="remnawave-sync-nodes"

if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo "Remnawave Monitoring v${VERSION}"
    exit 0
fi

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── Check root ───────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root (use sudo)"
fi

# ─── Check dependencies ──────────────────────────────────────────────────────
info "Checking dependencies..."

command -v docker >/dev/null 2>&1 || error "Docker is not installed. Please install Docker first: https://docs.docker.com/engine/install/"

if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    error "Docker Compose is not installed. Please install Docker Compose first."
fi

command -v python3 >/dev/null 2>&1 || error "Python 3 is not installed. Please install Python 3."

ok "All dependencies found (docker, ${COMPOSE_CMD}, python3)"

# ─── Detect existing installation ─────────────────────────────────────────────
UPGRADE=false
if [ -f "${INSTALL_DIR}/.env" ]; then
    warn "Existing installation detected in ${INSTALL_DIR}"
    read -rp "Upgrade (keep existing .env)? [Y/n]: " UPGRADE_CONFIRM
    UPGRADE_CONFIRM="${UPGRADE_CONFIRM:-Y}"
    if [[ "$UPGRADE_CONFIRM" =~ ^[Yy]$ ]]; then
        UPGRADE=true
        info "Upgrade mode: will update files but keep existing .env"
    else
        warn "Proceeding with fresh install (existing .env will be overwritten)"
    fi
fi

# ─── Interactive configuration ────────────────────────────────────────────────
echo ""
echo -e "${CYAN}═══ Remnawave Monitoring Setup ═══${NC}"
echo ""

INSTALL_WHITEBOX=false
INSTALL_XRAY_CHECKER=false
COMPOSE_PROFILES=""

if [ "$UPGRADE" = false ]; then
    read -rp "Remnawave API URL (e.g. https://your-panel.com/api/nodes): " REMNAWAVE_API_URL
    while [ -z "$REMNAWAVE_API_URL" ]; do
        warn "API URL cannot be empty"
        read -rp "Remnawave API URL: " REMNAWAVE_API_URL
    done

    while true; do
        read -rp "Remnawave API Token: " REMNAWAVE_API_TOKEN
        if [ -n "$REMNAWAVE_API_TOKEN" ]; then
            break
        fi
        warn "API token cannot be empty"
    done

    read -rp "Grafana admin username [admin]: " INPUT_GRAFANA_USER
    GRAFANA_ADMIN_USER="${INPUT_GRAFANA_USER:-admin}"

    while true; do
        read -rsp "Grafana admin password: " GRAFANA_ADMIN_PASSWORD
        echo ""
        if [ -n "$GRAFANA_ADMIN_PASSWORD" ]; then
            break
        fi
        warn "Password cannot be empty"
    done

    # ─── Optional components ─────────────────────────────────────────────────
    echo ""
    echo -e "${CYAN}── Optional components ──${NC}"
    echo ""

    COMPOSE_PROFILES_LIST=()

    read -rp "Install Whitebox (VPN tunnel probing)? [y/N]: " INPUT_WHITEBOX
    if [[ "${INPUT_WHITEBOX:-N}" =~ ^[Yy]$ ]]; then
        INSTALL_WHITEBOX=true
        COMPOSE_PROFILES_LIST+=("whitebox")
    fi

    read -rp "Install xray-checker (proxy monitoring)? [y/N]: " INPUT_XRAY_CHECKER
    if [[ "${INPUT_XRAY_CHECKER:-N}" =~ ^[Yy]$ ]]; then
        INSTALL_XRAY_CHECKER=true
        COMPOSE_PROFILES_LIST+=("xray-checker")

        while true; do
            read -rp "  Subscription URL: " XRAY_CHECKER_SUBSCRIPTION_URL
            if [ -n "$XRAY_CHECKER_SUBSCRIPTION_URL" ]; then
                break
            fi
            warn "Subscription URL cannot be empty"
        done

        read -rp "  Metrics username [admin]: " INPUT_XRAY_USER
        XRAY_CHECKER_USER="${INPUT_XRAY_USER:-admin}"

        read -rsp "  Metrics password [changeme]: " INPUT_XRAY_PASS
        echo ""
        XRAY_CHECKER_PASSWORD="${INPUT_XRAY_PASS:-changeme}"
    fi

    # Build COMPOSE_PROFILES string
    if [ ${#COMPOSE_PROFILES_LIST[@]} -gt 0 ]; then
        COMPOSE_PROFILES=$(IFS=,; echo "${COMPOSE_PROFILES_LIST[*]}")
    fi

    # ─── Confirm ─────────────────────────────────────────────────────────────
    echo ""
    info "Configuration:"
    echo "  API URL:       ${REMNAWAVE_API_URL}"
    echo "  API Token:     ${REMNAWAVE_API_TOKEN:0:20}..."
    echo "  Grafana User:  ${GRAFANA_ADMIN_USER}"
    echo "  Grafana Pass:  ********"
    if [ "$INSTALL_WHITEBOX" = true ]; then
        echo "  Whitebox:      enabled"
    fi
    if [ "$INSTALL_XRAY_CHECKER" = true ]; then
        echo "  xray-checker:  enabled"
        echo "    Sub URL:     ${XRAY_CHECKER_SUBSCRIPTION_URL}"
        echo "    Metrics user: ${XRAY_CHECKER_USER}"
    fi
    echo ""
    read -rp "Continue with these settings? [Y/n]: " CONFIRM
    CONFIRM="${CONFIRM:-Y}"
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "Aborted by user"
        exit 0
    fi
fi

# ─── Install files ────────────────────────────────────────────────────────────
info "Installing to ${INSTALL_DIR}..."

mkdir -p "$INSTALL_DIR"
mkdir -p "$LOG_DIR"

download_files() {
    local base="https://raw.githubusercontent.com/alkhilaev/monitoring/${REPO_BRANCH}"
    local files="docker-compose.yml prometheus.yml sync-nodes.py whitebox-sd-config.yml whitebox.yml .env.example setup.sh uninstall.sh"
    for f in $files; do
        curl -sSL "${base}/${f}" -o "${INSTALL_DIR}/${f}" || error "Failed to download ${f}"
    done
}

if [ -d "${INSTALL_DIR}/.git" ]; then
    info "Existing git repo found, pulling latest changes..."
    git -C "$INSTALL_DIR" pull origin "$REPO_BRANCH" || warn "git pull failed, continuing with existing files"
elif command -v git >/dev/null 2>&1; then
    info "Cloning repository..."
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR" 2>/dev/null || {
        warn "git clone failed, downloading files via curl..."
        download_files
    }
else
    info "git not found, downloading files via curl..."
    download_files
fi

# ─── Create .env ──────────────────────────────────────────────────────────────
if [ "$UPGRADE" = true ]; then
    ok "Keeping existing .env file"
    # Read COMPOSE_PROFILES from existing .env to determine what's enabled
    COMPOSE_PROFILES=$(grep -E '^COMPOSE_PROFILES=' "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2- || true)
    if [[ "$COMPOSE_PROFILES" == *"whitebox"* ]]; then INSTALL_WHITEBOX=true; fi
    if [[ "$COMPOSE_PROFILES" == *"xray-checker"* ]]; then
        INSTALL_XRAY_CHECKER=true
        XRAY_CHECKER_USER=$(grep -E '^XRAY_CHECKER_USER=' "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2- || echo "admin")
        XRAY_CHECKER_PASSWORD=$(grep -E '^XRAY_CHECKER_PASSWORD=' "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2- || echo "changeme")
    fi
else
    info "Creating .env file..."

    cat > "${INSTALL_DIR}/.env" <<EOF
REMNAWAVE_API_URL=${REMNAWAVE_API_URL}
REMNAWAVE_API_TOKEN=${REMNAWAVE_API_TOKEN}
GRAFANA_ADMIN_USER=${GRAFANA_ADMIN_USER}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
COMPOSE_PROFILES=${COMPOSE_PROFILES}
EOF

    if [ "$INSTALL_XRAY_CHECKER" = true ]; then
        cat >> "${INSTALL_DIR}/.env" <<EOF
XRAY_CHECKER_SUBSCRIPTION_URL=${XRAY_CHECKER_SUBSCRIPTION_URL}
XRAY_CHECKER_USER=${XRAY_CHECKER_USER}
XRAY_CHECKER_PASSWORD=${XRAY_CHECKER_PASSWORD}
EOF
    fi

    chmod 600 "${INSTALL_DIR}/.env"
    ok ".env created with restricted permissions (600)"
fi

# ─── Configure prometheus.yml ────────────────────────────────────────────────
info "Configuring Prometheus scrape jobs..."

PROM_CFG="${INSTALL_DIR}/prometheus.yml"

if [ "$INSTALL_XRAY_CHECKER" = true ]; then
    # Uncomment xray-checker block
    sed -i.bak '/job_name.*xray-checker/,/targets.*xray-checker/ s/^#  /  /' "$PROM_CFG"
    # Replace credential placeholders
    sed -i.bak "s/__XRAY_CHECKER_USER__/${XRAY_CHECKER_USER}/" "$PROM_CFG"
    sed -i.bak "s/__XRAY_CHECKER_PASSWORD__/${XRAY_CHECKER_PASSWORD}/" "$PROM_CFG"
    ok "xray-checker scrape job enabled in prometheus.yml"
fi

if [ "$INSTALL_WHITEBOX" = true ]; then
    # Uncomment whitebox block
    sed -i.bak '/job_name.*whitebox/,/replacement.*whitebox/ s/^#  /  /' "$PROM_CFG"
    ok "whitebox scrape job enabled in prometheus.yml"
fi

# Clean up sed backup files
rm -f "${PROM_CFG}.bak"

# ─── Create Docker network ───────────────────────────────────────────────────
if ! docker network inspect remnawave-network >/dev/null 2>&1; then
    info "Creating Docker network 'remnawave-network'..."
    docker network create remnawave-network
    ok "Network created"
else
    ok "Docker network 'remnawave-network' already exists"
fi

# ─── Create empty vpn-nodes.json if missing ──────────────────────────────────
if [ ! -f "${INSTALL_DIR}/vpn-nodes.json" ]; then
    echo "[]" > "${INSTALL_DIR}/vpn-nodes.json"
fi

# ─── First sync ──────────────────────────────────────────────────────────────
info "Running initial node sync..."
cd "$INSTALL_DIR"

if python3 sync-nodes.py 2>&1 | tee -a "${LOG_DIR}/sync-nodes.log"; then
    ok "Node sync completed"
else
    warn "Node sync failed (will retry via cron). Check: ${LOG_DIR}/sync-nodes.log"
fi

# ─── Setup cron ───────────────────────────────────────────────────────────────
info "Setting up cron job (every 10 minutes)..."

CRON_LINE="*/10 * * * * cd ${INSTALL_DIR} && /usr/bin/python3 ${INSTALL_DIR}/sync-nodes.py >> ${LOG_DIR}/sync-nodes.log 2>&1 # ${CRON_COMMENT}"

# Remove old cron entry if exists, then add new one
(crontab -l 2>/dev/null | grep -v "$CRON_COMMENT" || true; echo "$CRON_LINE") | crontab -
ok "Cron job installed"

# ─── Start Docker stack ──────────────────────────────────────────────────────
info "Starting Docker Compose stack..."
cd "$INSTALL_DIR"
$COMPOSE_CMD up -d

ok "Docker stack is running"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Remnawave Monitoring installed successfully!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  Prometheus:  http://127.0.0.1:9090"
echo "  Grafana:     http://127.0.0.1:3100"
echo "    User:      ${GRAFANA_ADMIN_USER}"
if [ "$INSTALL_WHITEBOX" = true ]; then
    echo "  Whitebox:    http://127.0.0.1:9116"
fi
if [ "$INSTALL_XRAY_CHECKER" = true ]; then
    echo "  xray-checker: http://127.0.0.1:2112"
fi
echo ""
echo "  Install dir: ${INSTALL_DIR}"
echo "  Logs:        ${LOG_DIR}/sync-nodes.log"
echo ""
echo "  Services are bound to 127.0.0.1 only."
echo "  Use a reverse proxy for external access."
echo ""
echo "  To uninstall: bash ${INSTALL_DIR}/uninstall.sh"
echo ""
