#!/usr/bin/env python3
"""
sync-nodes.py — Fetches nodes from Remnawave API and generates Prometheus file_sd targets.
Place in /opt/remnawave/monitoring/sync-nodes.py

Cron (every 10 minutes):
  */10 * * * * /usr/bin/python3 /opt/remnawave/monitoring/sync-nodes.py >> /opt/remnawave/logs/sync-nodes.log 2>&1
"""

import json
import os
import sys
import tempfile
import urllib.request
import urllib.error
from datetime import datetime


def load_env_file():
    """Load variables from .env file (simple key=value parser, no external deps)."""
    env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    if not os.path.isfile(env_path):
        return
    with open(env_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip()
            # Strip surrounding quotes (single or double)
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                value = value[1:-1]
            # Don't override already-set environment variables
            if key and key not in os.environ:
                os.environ[key] = value


load_env_file()

# === CONFIGURATION ===
API_URL = os.environ.get("REMNAWAVE_API_URL", "")
API_TOKEN = os.environ.get("REMNAWAVE_API_TOKEN", "")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_FILE = os.environ.get("OUTPUT_FILE", os.path.join(SCRIPT_DIR, "vpn-nodes.json"))
NODE_EXPORTER_PORT = "9100"
MAX_LOG_SIZE = 10 * 1024 * 1024  # 10 MB
LOG_KEEP_LINES = 1000

# Country code → flag emoji
FLAGS = {
    "NL": "🇳🇱", "DE": "🇩🇪", "FI": "🇫🇮", "US": "🇺🇸", "GB": "🇬🇧",
    "JP": "🇯🇵", "RU": "🇷🇺", "FR": "🇫🇷", "SE": "🇸🇪", "CA": "🇨🇦",
    "AU": "🇦🇺", "SG": "🇸🇬", "KR": "🇰🇷", "TR": "🇹🇷", "PL": "🇵🇱",
    "CZ": "🇨🇿", "AT": "🇦🇹", "CH": "🇨🇭", "IT": "🇮🇹", "ES": "🇪🇸",
    "IE": "🇮🇪", "NO": "🇳🇴", "DK": "🇩🇰", "LT": "🇱🇹", "LV": "🇱🇻",
    "EE": "🇪🇪", "RO": "🇷🇴", "BG": "🇧🇬", "UA": "🇺🇦", "KZ": "🇰🇿",
    "IN": "🇮🇳", "BR": "🇧🇷", "HK": "🇭🇰", "TW": "🇹🇼", "IL": "🇮🇱",
    "MD": "🇲🇩", "GE": "🇬🇪", "AM": "🇦🇲", "AZ": "🇦🇿",
}

# Country code → location name
LOCATIONS = {
    "NL": "netherlands", "DE": "germany", "FI": "finland", "US": "usa", "GB": "uk",
    "JP": "japan", "RU": "russia", "FR": "france", "SE": "sweden", "CA": "canada",
    "AU": "australia", "SG": "singapore", "KR": "south-korea", "TR": "turkey", "PL": "poland",
    "CZ": "czech-republic", "AT": "austria", "CH": "switzerland", "IT": "italy", "ES": "spain",
    "IE": "ireland", "NO": "norway", "DK": "denmark", "LT": "lithuania", "LV": "latvia",
    "EE": "estonia", "RO": "romania", "BG": "bulgaria", "UA": "ukraine", "KZ": "kazakhstan",
    "IN": "india", "BR": "brazil", "HK": "hong-kong", "TW": "taiwan", "IL": "israel",
    "MD": "moldova", "GE": "georgia", "AM": "armenia", "AZ": "azerbaijan",
}


def rotate_log():
    """Rotate log file if it exceeds MAX_LOG_SIZE (keep last LOG_KEEP_LINES lines)."""
    log_file = os.environ.get("LOG_FILE", "")
    if not log_file:
        # Try to detect from cron redirect (fallback: check common path)
        log_file = os.path.join(os.path.dirname(SCRIPT_DIR), "logs", "sync-nodes.log")
    if not os.path.isfile(log_file):
        return
    try:
        if os.path.getsize(log_file) > MAX_LOG_SIZE:
            with open(log_file, "r", encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
            with open(log_file, "w", encoding="utf-8") as f:
                f.writelines(lines[-LOG_KEEP_LINES:])
    except OSError:
        pass


def log(msg):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def fetch_nodes():
    """Fetch nodes from Remnawave API."""
    req = urllib.request.Request(
        API_URL,
        headers={
            "Authorization": f"Bearer {API_TOKEN}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if isinstance(data, dict) and "response" in data:
                return data["response"]
            return data
    except urllib.error.URLError as e:
        log(f"ERROR: API request failed: {e}")
        sys.exit(1)


def build_targets(nodes):
    """Convert Remnawave nodes to Prometheus file_sd format."""
    targets = []

    for node in nodes:
        # Skip disabled nodes
        if node.get("isDisabled", False):
            continue

        address = node["address"]
        name = node.get("name", "unknown")
        country = node.get("countryCode", "XX")

        # Provider name
        provider_name = ""
        if node.get("provider") and node["provider"].get("name"):
            provider_name = node["provider"]["name"]

        flag = FLAGS.get(country, "🏳️")
        location = LOCATIONS.get(country, country.lower())

        targets.append({
            "targets": [f"{address}:{NODE_EXPORTER_PORT}"],
            "labels": {
                "node": f"{flag} {name}",
                "location": location,
                "provider": provider_name,
                "ip": address,
                "country_code": country,
            },
        })

    return targets


def main():
    rotate_log()

    if not API_URL or not API_TOKEN:
        log("ERROR: REMNAWAVE_API_URL and REMNAWAVE_API_TOKEN must be set (via .env file or environment variables)")
        sys.exit(1)

    nodes = fetch_nodes()
    log(f"Fetched {len(nodes)} nodes from API")

    targets = build_targets(nodes)
    log(f"Generated {len(targets)} active targets (skipped {len(nodes) - len(targets)} disabled)")

    # Atomic write: tmpfile in same dir + os.replace() to avoid Prometheus reading partial JSON
    output_dir = os.path.dirname(os.path.abspath(OUTPUT_FILE))
    fd, tmp_path = tempfile.mkstemp(dir=output_dir, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(targets, f, indent=2, ensure_ascii=False)
        os.replace(tmp_path, OUTPUT_FILE)
    except Exception:
        os.unlink(tmp_path)
        raise

    log(f"OK: Wrote {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
