#!/usr/bin/env bash
set -euo pipefail

DEFAULT_METRICS="cpu_usage_percentage,memory_usage_percentage,disk_usage_percentage,available_memory_mb,io_time_ms,rx_bytes_total,tx_bytes_total,rx_errors_total,tx_errors_total,dropped_packets_total"
METRICS="${SYSTEM_SENTINEL_METRICS:-$DEFAULT_METRICS}"
MAX_TRIES="${SYSTEM_SENTINEL_INIT_TRIES:-30}"
SLEEP_SECONDS="${SYSTEM_SENTINEL_INIT_SLEEP:-2}"

require_tool() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd"
    exit 1
  fi
}

require_buildx() {
  if ! docker buildx version >/dev/null 2>&1; then
    echo "ERROR: Docker buildx plugin is required."
    echo "Install hint:"
    echo "  Arch/CachyOS: sudo pacman -S docker-buildx"
    echo "  Ubuntu/Debian: sudo apt-get install docker-buildx-plugin"
    echo "  Fedora: sudo dnf install docker-buildx-plugin"
    exit 1
  fi
}

require_tool docker
require_buildx

if [ ! -d "lib/prometheus-client-c/prom" ] || [ ! -d "lib/prometheus-client-c/promhttp" ]; then
  echo "ERROR: missing submodule lib/prometheus-client-c."
  echo "Run: git submodule update --init --recursive"
  exit 1
fi

echo "Starting SystemSentinel stack..."
docker compose up -d --build

echo "Waiting for app container to accept FIFO initialization..."
i=1
until docker compose exec -T app sh -lc "test -p /tmp/monitor_fifo" >/dev/null 2>&1; do
  if [ "$i" -ge "$MAX_TRIES" ]; then
    echo "ERROR: timed out waiting for /tmp/monitor_fifo"
    exit 1
  fi
  sleep "$SLEEP_SECONDS"
  i=$((i + 1))
done

echo "Initializing exporter metrics set:"
echo "  $METRICS"
docker compose exec -T app sh -lc "printf '%s' \"$METRICS\" > /tmp/monitor_fifo"

echo "Done. Useful endpoints:"
echo "  http://localhost:8000/metrics"
echo "  http://localhost:9090/targets"
echo "  http://localhost:3000"
