# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Обзор

Стек мониторинга Prometheus + Grafana для **VPN-нод Remnawave**. Работает через Docker Compose в внешней сети `remnawave-network`. Автоматически обнаруживает ноды через Python-скрипт синхронизации.

## Архитектура

**Docker-сервисы** (`docker-compose.yml`):
- **Prometheus** (порт 9090) — собирает метрики node-exporter с VPN-нод; хранение 90 дней; конфиг в `prometheus.yml`
- **Grafana** (порт 3100 -> контейнер 3000) — дашборды; креды задаются через переменные окружения в compose-файле
- **Whitebox** (порт 9116) — проверка связности VLESS/прокси; опциональный, включается через Docker Compose profile `whitebox`; конфиг в `whitebox.yml`
- **xray-checker** (порт 2112) — мониторинг прокси по подписке; опциональный, включается через Docker Compose profile `xray-checker`; образ `kutovoys/xray-checker:latest`

**Docker Compose Profiles:**
- Whitebox и xray-checker запускаются только при наличии соответствующего профиля
- Переменная `COMPOSE_PROFILES` в `.env` управляет активными профилями (например `whitebox,xray-checker`)
- Prometheus и Grafana запускаются всегда (без профилей)

**Динамическое обнаружение нод** (`sync-nodes.py`):
- Python 3 скрипт (без внешних зависимостей), вызывает API Remnawave для получения активных нод
- Генерирует `vpn-nodes.json` в формате Prometheus `file_sd_configs` (таргеты + лейблы: страна, провайдер, флаг-эмодзи)
- Запускается по крону каждые 10 минут; путь деплоя: `/opt/remnawave/monitoring/`
- Настраивается через env-переменные: `REMNAWAVE_API_URL`, `REMNAWAVE_API_TOKEN`, `OUTPUT_FILE`

**Scrape-джобы Prometheus** (`prometheus.yml`):
- `vpn-nodes` — активный; скрейпит node-exporter (порт 9100) по таргетам из `vpn-nodes.json` каждые 30с
- `whitebox` — закомментирован по умолчанию; раскомментируется через `setup.sh` при установке Whitebox
- `xray-checker` — закомментирован по умолчанию; раскомментируется через `setup.sh` при установке xray-checker; использует плейсхолдеры `__XRAY_CHECKER_USER__` и `__XRAY_CHECKER_PASSWORD__` которые подставляются через sed

**Конфигурационные файлы**:
- `whitebox.yml` — конфигурация Whitebox exporter (дефолтный scope с timeout 5s)
- `whitebox-sd-config.yml` — таргеты для Whitebox service discovery (шаблон с плейсхолдерами VLESS URI)
- `vpn-nodes.json` — автогенерируется `sync-nodes.py` (atomic write через tmpfile + os.replace), монтируется в контейнер Prometheus

## Установка

Автоматическая установка одной командой:
```bash
bash <(curl -sSL https://raw.githubusercontent.com/alkhilaev/monitoring/main/setup.sh)
```

Скрипт `setup.sh`:
1. Проверяет наличие Docker, Docker Compose, Python 3
2. Интерактивно запрашивает API URL, токен, креды Grafana
3. Спрашивает об установке Whitebox и xray-checker (опционально)
4. Клонирует репозиторий в `/opt/remnawave/monitoring/` (или скачивает файлы через curl)
5. Создаёт `.env` файл из введённых данных (включая `COMPOSE_PROFILES`)
6. Раскомментирует нужные scrape-джобы в `prometheus.yml` через sed
7. Создаёт Docker-сеть `remnawave-network`
8. Запускает первую синхронизацию нод
9. Устанавливает cron-задачу (каждые 10 минут)
10. Запускает `docker compose up -d`

## Удаление

```bash
bash /opt/remnawave/monitoring/uninstall.sh
```

Скрипт `uninstall.sh` останавливает контейнеры, удаляет cron-задачу, и спрашивает об удалении данных (volumes) и файлов.

## Конфигурация

Все настройки хранятся в `.env` файле (создаётся при установке). Шаблон — `.env.example`.

Переменные:
- `REMNAWAVE_API_URL` — URL API Remnawave
- `REMNAWAVE_API_TOKEN` — токен доступа к API
- `GRAFANA_ADMIN_USER` — логин Grafana
- `GRAFANA_ADMIN_PASSWORD` — пароль Grafana
- `COMPOSE_PROFILES` — активные Docker Compose profiles (например `whitebox,xray-checker`)
- `XRAY_CHECKER_SUBSCRIPTION_URL` — URL подписки для xray-checker
- `XRAY_CHECKER_USER` — логин для метрик xray-checker (default: admin)
- `XRAY_CHECKER_PASSWORD` — пароль для метрик xray-checker (default: changeme)

## Команды

```bash
# Запуск/остановка стека
docker compose up -d
docker compose down

# Перезапуск после изменения конфигов (prometheus.yml, whitebox-sd-config.yml)
docker compose restart prometheus

# Ручной запуск синхронизации нод
python3 sync-nodes.py

# Просмотр логов синхронизации (при деплое в /opt/remnawave)
cat /opt/remnawave/logs/sync-nodes.log
```

## Важные замечания

- Все сервисы слушают только на `127.0.0.1` (не доступны извне); для внешнего доступа нужен reverse proxy.
- Compose-стек подключается к **внешней** Docker-сети `remnawave-network` — она должна существовать до `docker compose up`.
- Конфигурация (API-токен, URL, креды Grafana) читается из `.env` файла. Захардкоженных секретов в коде нет.
- `vpn-nodes.json` пишется через atomic write (tmpfile + os.replace) для безопасного обновления во время чтения Prometheus.
- `sync-nodes.py` автоматически ротирует лог-файл при превышении 10 MB (оставляет последние 1000 строк).
- `setup.sh` поддерживает upgrade — при повторном запуске предлагает сохранить существующий `.env`.
- Whitebox и xray-checker используют Docker Compose profiles — запускаются только если `COMPOSE_PROFILES` содержит соответствующий профиль.
