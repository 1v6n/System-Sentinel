#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"

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

if [ ! -d "${REPO_ROOT}/lib/prometheus-client-c/prom" ] || [ ! -d "${REPO_ROOT}/lib/prometheus-client-c/promhttp" ]; then
  echo "ERROR: missing submodule lib/prometheus-client-c."
  echo "Run: git submodule update --init --recursive"
  exit 1
fi

DOCKER_COMPOSE=(docker compose -f "${COMPOSE_FILE}" --project-directory "${REPO_ROOT}")

compose_project_name() {
  local name
  name="$("${DOCKER_COMPOSE[@]}" config --format json 2>/dev/null | sed -n 's/^[[:space:]]*"name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  if [ -z "${name}" ]; then
    name="$(basename "${REPO_ROOT}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
    name="${name%-}"
  fi
  printf '%s' "${name}"
}

is_dns_resolution_error() {
  local logfile="$1"
  grep -qiE \
    'Temporary failure resolving|failed to fetch .* InRelease|lookup .*:53|no such host|could not resolve host' \
    "${logfile}"
}

start_stack_with_fallback() {
  local up_log project_name app_image
  up_log="$(mktemp /tmp/systemsentinel-up.XXXXXX.log)"

  if "${DOCKER_COMPOSE[@]}" up -d --build 2>&1 | tee "${up_log}"; then
    rm -f "${up_log}"
    return 0
  fi

  if ! is_dns_resolution_error "${up_log}"; then
    echo "ERROR: docker compose up failed. Showing last log lines:"
    tail -n 60 "${up_log}"
    rm -f "${up_log}"
    return 1
  fi

  echo "WARN: detected Docker build DNS resolution failure."
  echo "WARN: retrying app image build with host network (BuildKit disabled)."
  project_name="$(compose_project_name)"
  app_image="${project_name}-app"

  DOCKER_BUILDKIT=0 docker build --network=host -f "${REPO_ROOT}/Dockerfile" -t "${app_image}" "${REPO_ROOT}"
  "${DOCKER_COMPOSE[@]}" up -d --no-build
  rm -f "${up_log}"
}

echo "Starting SystemSentinel stack..."
start_stack_with_fallback

echo "Waiting for app container to accept FIFO initialization..."
i=1
until "${DOCKER_COMPOSE[@]}" exec -T app sh -lc "test -p /tmp/monitor_fifo" >/dev/null 2>&1; do
  if [ "$i" -ge "$MAX_TRIES" ]; then
    echo "ERROR: timed out waiting for /tmp/monitor_fifo"
    exit 1
  fi
  sleep "$SLEEP_SECONDS"
  i=$((i + 1))
done

echo "Initializing exporter metrics set:"
echo "  $METRICS"
"${DOCKER_COMPOSE[@]}" exec -T app sh -lc "printf '%s' \"$METRICS\" > /tmp/monitor_fifo"

echo "Done. Useful endpoints:"
echo "  http://localhost:8000/metrics"
echo "  http://localhost:9090/targets"
echo "  http://localhost:3000"
