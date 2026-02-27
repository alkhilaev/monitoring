# Remnawave Monitoring

Стек мониторинга **Prometheus + Grafana** для VPN-нод Remnawave с автоматическим обнаружением нод.

## Возможности

- **Prometheus** — сбор метрик node-exporter с VPN-нод (CPU, RAM, диск, сеть)
- **Grafana** — визуализация и дашборды
- **Автообнаружение нод** — Python-скрипт синхронизирует список нод из API Remnawave каждые 10 минут
- **Whitebox** (опционально) — проверка связности VPN-туннелей (VLESS/прокси)
- **xray-checker** (опционально) — мониторинг прокси по подписке

## Быстрая установка

```bash
bash <(curl -sSL https://raw.githubusercontent.com/alkhilaev/monitoring/main/setup.sh)
```

Скрипт интерактивно запросит:
1. URL и токен API Remnawave
2. Логин/пароль Grafana
3. Опционально — установку Whitebox и xray-checker

## Требования

- Docker + Docker Compose
- Python 3
- Внешняя Docker-сеть `remnawave-network`

## Архитектура

```
┌─────────────┐     ┌────────────┐     ┌──────────────────┐
│   Grafana    │────>│ Prometheus │────>│  VPN-ноды        │
│  :3100       │     │  :9090     │     │  (node-exporter) │
└─────────────┘     └────────────┘     └──────────────────┘
                         │
                    ┌────┴────┐
                    │         │
              ┌─────┴──┐  ┌──┴──────────┐
              │Whitebox│  │xray-checker │
              │ :9116  │  │   :2112     │
              └────────┘  └─────────────┘
              (опц.)       (опц.)
```

- **sync-nodes.py** — раз в 10 минут запрашивает API, генерирует `vpn-nodes.json` для Prometheus
- **Whitebox** и **xray-checker** включаются через Docker Compose profiles

## Конфигурация

Все настройки в файле `.env` (создаётся при установке). Шаблон: `.env.example`.

| Переменная | Описание | По умолчанию |
|---|---|---|
| `REMNAWAVE_API_URL` | URL API Remnawave | — |
| `REMNAWAVE_API_TOKEN` | Токен доступа к API | — |
| `GRAFANA_ADMIN_USER` | Логин Grafana | `admin` |
| `GRAFANA_ADMIN_PASSWORD` | Пароль Grafana | — |
| `COMPOSE_PROFILES` | Активные профили (`whitebox`, `xray-checker`) | — |
| `XRAY_CHECKER_SUBSCRIPTION_URL` | URL подписки для xray-checker | — |
| `XRAY_CHECKER_USER` | Логин метрик xray-checker | `admin` |
| `XRAY_CHECKER_PASSWORD` | Пароль метрик xray-checker | `changeme` |

## Команды

```bash
# Запуск / остановка
docker compose up -d
docker compose down

# Перезапуск после изменения конфигов
docker compose restart prometheus

# Ручная синхронизация нод
python3 sync-nodes.py

# Логи синхронизации
cat /opt/remnawave/logs/sync-nodes.log

# Обновление (сохраняет .env)
bash setup.sh
```

## Порты

Все сервисы слушают только на `127.0.0.1`:

| Сервис | Порт |
|---|---|
| Prometheus | `127.0.0.1:9090` |
| Grafana | `127.0.0.1:3100` |
| Whitebox | `127.0.0.1:9116` |
| xray-checker | `127.0.0.1:2112` |

Для внешнего доступа используйте reverse proxy (nginx, caddy).

## Удаление

```bash
bash /opt/remnawave/monitoring/uninstall.sh
```

Скрипт остановит контейнеры, удалит cron-задачу и спросит об удалении данных и файлов.

## Структура файлов

```
monitoring/
├── docker-compose.yml      # Docker Compose с профилями
├── prometheus.yml           # Конфиг Prometheus (scrape jobs)
├── sync-nodes.py            # Скрипт синхронизации нод
├── whitebox.yml             # Конфиг Whitebox exporter
├── whitebox-sd-config.yml   # Таргеты для Whitebox (VLESS URI)
├── setup.sh                 # Скрипт установки
├── uninstall.sh             # Скрипт удаления
├── .env.example             # Шаблон переменных окружения
└── vpn-nodes.json           # Автогенерируемый файл таргетов
```
