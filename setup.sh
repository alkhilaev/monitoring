#!/usr/bin/env bash
set -euo pipefail

# ─── Remnawave Monitoring — Скрипт установки ─────────────────────────────────
# Использование:
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

# ─── Цвета ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── Проверка root ───────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    error "Скрипт должен запускаться от root (используйте sudo)"
fi

# ─── Проверка зависимостей ───────────────────────────────────────────────────
info "Проверка зависимостей..."

command -v docker >/dev/null 2>&1 || error "Docker не установлен. Установите: https://docs.docker.com/engine/install/"

if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    error "Docker Compose не установлен."
fi

command -v python3 >/dev/null 2>&1 || error "Python 3 не установлен."

ok "Зависимости найдены (docker, ${COMPOSE_CMD}, python3)"

# ─── Обнаружение существующей установки ──────────────────────────────────────
UPGRADE=false
if [ -f "${INSTALL_DIR}/.env" ]; then
    warn "Обнаружена существующая установка в ${INSTALL_DIR}"
    read -rp "Обновить (сохранить текущий .env)? [Y/n]: " UPGRADE_CONFIRM
    UPGRADE_CONFIRM="${UPGRADE_CONFIRM:-Y}"
    if [[ "$UPGRADE_CONFIRM" =~ ^[Yy]$ ]]; then
        UPGRADE=true
        info "Режим обновления: файлы обновятся, .env сохранится"
    else
        warn "Чистая установка (текущий .env будет перезаписан)"
    fi
fi

# ─── Интерактивная настройка ─────────────────────────────────────────────────
echo ""
echo -e "${CYAN}═══ Remnawave Monitoring — Установка ═══${NC}"
echo ""

INSTALL_WHITEBOX=false
INSTALL_XRAY_CHECKER=false
COMPOSE_PROFILES=""

if [ "$UPGRADE" = false ]; then
    read -rp "URL панели Remnawave (например https://panel.example.com): " PANEL_URL
    while [ -z "$PANEL_URL" ]; do
        warn "URL не может быть пустым"
        read -rp "URL панели Remnawave: " PANEL_URL
    done
    PANEL_URL="${PANEL_URL%/}"
    REMNAWAVE_API_URL="${PANEL_URL}/api/nodes"

    while true; do
        read -rp "API токен Remnawave: " REMNAWAVE_API_TOKEN
        if [ -n "$REMNAWAVE_API_TOKEN" ]; then
            break
        fi
        warn "Токен не может быть пустым"
    done

    read -rp "Grafana логин [admin]: " INPUT_GRAFANA_USER
    GRAFANA_ADMIN_USER="${INPUT_GRAFANA_USER:-admin}"

    echo "Grafana пароль:"
    echo "  1) Ввести свой"
    echo "  2) Сгенерировать случайный"
    echo "  3) Оставить по умолчанию (admin)"
    read -rp "Выбор [1/2/3]: " PASS_CHOICE
    case "${PASS_CHOICE:-1}" in
        2)
            GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d '=/+' | head -c 16)
            echo -e "  Сгенерированный пароль: ${GREEN}${GRAFANA_ADMIN_PASSWORD}${NC}"
            echo "  (сохраните его!)"
            ;;
        3)
            GRAFANA_ADMIN_PASSWORD="admin"
            ;;
        *)
            read -rsp "  Введите пароль: " GRAFANA_ADMIN_PASSWORD
            echo ""
            GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
            ;;
    esac

    # ─── Дополнительные компоненты ───────────────────────────────────────────
    echo ""
    echo -e "${CYAN}── Дополнительные компоненты ──${NC}"
    echo ""

    COMPOSE_PROFILES_LIST=()

    read -rp "Установить Whitebox (проверка VPN-туннелей)? [y/N]: " INPUT_WHITEBOX
    if [[ "${INPUT_WHITEBOX:-N}" =~ ^[Yy]$ ]]; then
        INSTALL_WHITEBOX=true
        COMPOSE_PROFILES_LIST+=("whitebox")
    fi

    read -rp "Установить xray-checker (мониторинг прокси)? [y/N]: " INPUT_XRAY_CHECKER
    if [[ "${INPUT_XRAY_CHECKER:-N}" =~ ^[Yy]$ ]]; then
        INSTALL_XRAY_CHECKER=true
        COMPOSE_PROFILES_LIST+=("xray-checker")

        while true; do
            read -rp "  URL подписки: " XRAY_CHECKER_SUBSCRIPTION_URL
            if [ -n "$XRAY_CHECKER_SUBSCRIPTION_URL" ]; then
                break
            fi
            warn "URL подписки не может быть пустым"
        done

        XRAY_CHECKER_USER="admin"
        XRAY_CHECKER_PASSWORD=$(openssl rand -base64 16 | tr -d '=/+' | head -c 16)
        echo -e "  Метрики xray-checker (внутренний доступ Prometheus):"
        echo -e "    Логин:  admin"
        echo -e "    Пароль: ${GREEN}${XRAY_CHECKER_PASSWORD}${NC} (сгенерирован)"
    fi

    # Собрать COMPOSE_PROFILES
    if [ ${#COMPOSE_PROFILES_LIST[@]} -gt 0 ]; then
        COMPOSE_PROFILES=$(IFS=,; echo "${COMPOSE_PROFILES_LIST[*]}")
    fi

    # ─── Подтверждение ───────────────────────────────────────────────────────
    echo ""
    info "Настройки:"
    echo "  Панель:        ${PANEL_URL}"
    echo "  API URL:       ${REMNAWAVE_API_URL}"
    echo "  API токен:     ${REMNAWAVE_API_TOKEN:0:20}..."
    echo "  Grafana:       ${GRAFANA_ADMIN_USER} / ${GRAFANA_ADMIN_PASSWORD}"
    if [ "$INSTALL_WHITEBOX" = true ]; then
        echo "  Whitebox:      включён"
    fi
    if [ "$INSTALL_XRAY_CHECKER" = true ]; then
        echo "  xray-checker:  включён"
        echo "    Подписка:    ${XRAY_CHECKER_SUBSCRIPTION_URL}"
        echo "    Метрики:     ${XRAY_CHECKER_USER} / ${XRAY_CHECKER_PASSWORD}"
    fi
    echo ""
    read -rp "Продолжить с этими настройками? [Y/n]: " CONFIRM
    CONFIRM="${CONFIRM:-Y}"
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "Отменено"
        exit 0
    fi
fi

# ─── Установка файлов ────────────────────────────────────────────────────────
info "Установка в ${INSTALL_DIR}..."

mkdir -p "$INSTALL_DIR"
mkdir -p "$LOG_DIR"

download_files() {
    local base="https://raw.githubusercontent.com/alkhilaev/monitoring/${REPO_BRANCH}"
    local files="docker-compose.yml prometheus.yml sync-nodes.py whitebox-sd-config.yml whitebox.yml .env.example setup.sh uninstall.sh rw-monitoring"
    for f in $files; do
        curl -sSL "${base}/${f}" -o "${INSTALL_DIR}/${f}" || error "Не удалось скачать ${f}"
    done
}

if [ -d "${INSTALL_DIR}/.git" ]; then
    info "Найден git-репозиторий, обновление..."
    git -C "$INSTALL_DIR" pull origin "$REPO_BRANCH" || warn "git pull не удался, продолжаем с текущими файлами"
elif command -v git >/dev/null 2>&1; then
    info "Клонирование репозитория..."
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR" 2>/dev/null || {
        warn "git clone не удался, скачиваем файлы через curl..."
        download_files
    }
else
    info "git не найден, скачиваем файлы через curl..."
    download_files
fi

# ─── Установка CLI-команды ───────────────────────────────────────────────────
info "Установка команды rw-monitoring..."
cp "${INSTALL_DIR}/rw-monitoring" /usr/local/bin/rw-monitoring
chmod +x /usr/local/bin/rw-monitoring
ok "Команда rw-monitoring установлена"

# ─── Создание / миграция .env ────────────────────────────────────────────────
# Вспомогательная функция: прочитать значение из .env, снять кавычки
env_val() { grep -E "^${1}=" "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || echo "${2:-}"; }

if [ "$UPGRADE" = true ]; then
    info "Миграция .env (добавление кавычек для совместимости)..."

    # Прочитать все значения из старого .env
    REMNAWAVE_API_URL=$(env_val REMNAWAVE_API_URL)
    REMNAWAVE_API_TOKEN=$(env_val REMNAWAVE_API_TOKEN)
    GRAFANA_ADMIN_USER=$(env_val GRAFANA_ADMIN_USER admin)
    GRAFANA_ADMIN_PASSWORD=$(env_val GRAFANA_ADMIN_PASSWORD admin)
    COMPOSE_PROFILES=$(env_val COMPOSE_PROFILES)

    if [[ "$COMPOSE_PROFILES" == *"whitebox"* ]]; then INSTALL_WHITEBOX=true; fi
    if [[ "$COMPOSE_PROFILES" == *"xray-checker"* ]]; then
        INSTALL_XRAY_CHECKER=true
        XRAY_CHECKER_USER=$(env_val XRAY_CHECKER_USER admin)
        XRAY_CHECKER_PASSWORD=$(env_val XRAY_CHECKER_PASSWORD changeme)
        XRAY_CHECKER_SUBSCRIPTION_URL=$(env_val XRAY_CHECKER_SUBSCRIPTION_URL)
    fi

    # Перезаписать .env с кавычками
    cat > "${INSTALL_DIR}/.env" <<EOF
REMNAWAVE_API_URL='${REMNAWAVE_API_URL}'
REMNAWAVE_API_TOKEN='${REMNAWAVE_API_TOKEN}'
GRAFANA_ADMIN_USER='${GRAFANA_ADMIN_USER}'
GRAFANA_ADMIN_PASSWORD='${GRAFANA_ADMIN_PASSWORD}'
COMPOSE_PROFILES='${COMPOSE_PROFILES}'
EOF

    if [ "$INSTALL_XRAY_CHECKER" = true ]; then
        cat >> "${INSTALL_DIR}/.env" <<EOF
XRAY_CHECKER_SUBSCRIPTION_URL='${XRAY_CHECKER_SUBSCRIPTION_URL}'
XRAY_CHECKER_USER='${XRAY_CHECKER_USER}'
XRAY_CHECKER_PASSWORD='${XRAY_CHECKER_PASSWORD}'
EOF
    fi

    chmod 600 "${INSTALL_DIR}/.env"
    ok ".env обновлён (настройки сохранены)"
else
    info "Создание .env..."

    cat > "${INSTALL_DIR}/.env" <<EOF
REMNAWAVE_API_URL='${REMNAWAVE_API_URL}'
REMNAWAVE_API_TOKEN='${REMNAWAVE_API_TOKEN}'
GRAFANA_ADMIN_USER='${GRAFANA_ADMIN_USER}'
GRAFANA_ADMIN_PASSWORD='${GRAFANA_ADMIN_PASSWORD}'
COMPOSE_PROFILES='${COMPOSE_PROFILES}'
EOF

    if [ "$INSTALL_XRAY_CHECKER" = true ]; then
        cat >> "${INSTALL_DIR}/.env" <<EOF
XRAY_CHECKER_SUBSCRIPTION_URL='${XRAY_CHECKER_SUBSCRIPTION_URL}'
XRAY_CHECKER_USER='${XRAY_CHECKER_USER}'
XRAY_CHECKER_PASSWORD='${XRAY_CHECKER_PASSWORD}'
EOF
    fi

    chmod 600 "${INSTALL_DIR}/.env"
    ok ".env создан (права 600)"
fi

# ─── Настройка prometheus.yml ────────────────────────────────────────────────
info "Настройка scrape-джобов Prometheus..."

PROM_CFG="${INSTALL_DIR}/prometheus.yml"

if [ "$INSTALL_XRAY_CHECKER" = true ]; then
    sed -i.bak '/job_name.*xray-checker/,/targets.*xray-checker/ s/^#  /  /' "$PROM_CFG"
    sed -i.bak "s/__XRAY_CHECKER_USER__/${XRAY_CHECKER_USER}/" "$PROM_CFG"
    sed -i.bak "s/__XRAY_CHECKER_PASSWORD__/${XRAY_CHECKER_PASSWORD}/" "$PROM_CFG"
    ok "xray-checker включён в prometheus.yml"
fi

if [ "$INSTALL_WHITEBOX" = true ]; then
    sed -i.bak '/job_name.*whitebox/,/replacement.*whitebox/ s/^#  /  /' "$PROM_CFG"
    ok "whitebox включён в prometheus.yml"
fi

rm -f "${PROM_CFG}.bak"

# ─── Docker-сеть ─────────────────────────────────────────────────────────────
if ! docker network inspect remnawave-network >/dev/null 2>&1; then
    info "Создание Docker-сети 'remnawave-network'..."
    docker network create remnawave-network
    ok "Сеть создана"
else
    ok "Docker-сеть 'remnawave-network' уже существует"
fi

# ─── Создание vpn-nodes.json ─────────────────────────────────────────────────
if [ ! -f "${INSTALL_DIR}/vpn-nodes.json" ]; then
    echo "[]" > "${INSTALL_DIR}/vpn-nodes.json"
fi

# ─── Первая синхронизация ────────────────────────────────────────────────────
info "Первая синхронизация нод..."
cd "$INSTALL_DIR"

if python3 sync-nodes.py 2>&1 | tee -a "${LOG_DIR}/sync-nodes.log"; then
    ok "Синхронизация завершена"
else
    warn "Синхронизация не удалась (повторится через cron). Лог: ${LOG_DIR}/sync-nodes.log"
fi

# ─── Настройка cron ──────────────────────────────────────────────────────────
info "Настройка cron (каждые 10 минут)..."

CRON_LINE="*/10 * * * * cd ${INSTALL_DIR} && /usr/bin/python3 ${INSTALL_DIR}/sync-nodes.py >> ${LOG_DIR}/sync-nodes.log 2>&1 # ${CRON_COMMENT}"

(crontab -l 2>/dev/null | grep -v "$CRON_COMMENT" || true; echo "$CRON_LINE") | crontab -
ok "Cron-задача установлена"

# ─── Запуск Docker-стека ─────────────────────────────────────────────────────
info "Запуск Docker Compose..."
cd "$INSTALL_DIR"
$COMPOSE_CMD up -d

ok "Стек запущен"

# ─── Итого ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Remnawave Monitoring установлен!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  Prometheus:    http://127.0.0.1:9090"
echo "  Grafana:       http://127.0.0.1:3100"
if [ "$INSTALL_WHITEBOX" = true ]; then
    echo "  Whitebox:      http://127.0.0.1:9116"
fi
if [ "$INSTALL_XRAY_CHECKER" = true ]; then
    echo "  xray-checker:  http://127.0.0.1:2112"
fi
echo ""
echo "  Управление:   rw-monitoring <команда>"
echo "    status   — статус сервисов"
echo "    restart  — перезапуск"
echo "    update   — обновление"
echo "    logs     — логи синхронизации"
echo "    sync     — ручная синхронизация нод"
echo ""
echo "  Сервисы слушают только на 127.0.0.1."
echo "  Для внешнего доступа используйте reverse proxy."
echo ""
