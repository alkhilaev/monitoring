#!/usr/bin/env bash
set -euo pipefail

# ─── Remnawave Monitoring — Скрипт удаления ──────────────────────────────────

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
    error "Скрипт должен запускаться от root (используйте sudo)"
fi

echo -e "${YELLOW}═══ Remnawave Monitoring — Удаление ═══${NC}"
echo ""

# ─── Остановка контейнеров ───────────────────────────────────────────────────
if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
    info "Остановка контейнеров..."
    cd "$INSTALL_DIR"
    if docker compose version >/dev/null 2>&1; then
        docker compose down || true
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose down || true
    fi
    ok "Контейнеры остановлены"
else
    warn "docker-compose.yml не найден, пропускаем"
fi

# ─── Удаление cron-задачи ───────────────────────────────────────────────────
info "Удаление cron-задачи..."
(crontab -l 2>/dev/null | grep -v "$CRON_COMMENT" || true) | crontab -
ok "Cron-задача удалена"

# ─── Удаление CLI-команды ───────────────────────────────────────────────────
if [ -f /usr/local/bin/rw-monitoring ]; then
    rm -f /usr/local/bin/rw-monitoring
    ok "Команда rw-monitoring удалена"
fi

# ─── Данные (volumes) ───────────────────────────────────────────────────────
echo ""
read -rp "Удалить Docker volumes (данные Prometheus и Grafana)? [y/N]: " DELETE_VOLUMES
DELETE_VOLUMES="${DELETE_VOLUMES:-N}"

if [[ "$DELETE_VOLUMES" =~ ^[Yy]$ ]]; then
    info "Удаление Docker volumes..."
    PROJECT_NAME="$(basename "$INSTALL_DIR")"
    for vol in $(docker volume ls -q --filter "name=${PROJECT_NAME}_" 2>/dev/null); do
        docker volume rm "$vol" 2>/dev/null && ok "Удалён: $vol" || warn "Не удалось удалить: $vol"
    done
    ok "Volumes удалены"
else
    info "Volumes сохранены"
fi

# ─── Файлы установки ────────────────────────────────────────────────────────
read -rp "Удалить директорию установки (${INSTALL_DIR})? [y/N]: " DELETE_FILES
DELETE_FILES="${DELETE_FILES:-N}"

if [[ "$DELETE_FILES" =~ ^[Yy]$ ]]; then
    info "Удаление ${INSTALL_DIR}..."
    rm -rf "$INSTALL_DIR"
    ok "Директория удалена"

    if [ -d "$LOG_DIR" ]; then
        rmdir "$LOG_DIR" 2>/dev/null && ok "Директория логов удалена" || info "Директория логов не пуста, оставляем"
    fi

    rmdir /opt/remnawave 2>/dev/null || true
else
    info "Файлы сохранены"
fi

echo ""
echo -e "${GREEN}Remnawave Monitoring удалён.${NC}"
echo ""
