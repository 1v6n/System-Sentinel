#!/usr/bin/env bash
set -euo pipefail

# One-shot installer for Oracle ARM Ubuntu/Debian VM.
# - Installs Docker Engine + Compose plugin (official Docker repo)
# - Prepares .env (optionally from exported env vars)
# - Binds services to NetBird IP when available
# - Starts full stack and initializes exporter FIFO

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [ ! -f "docker-compose.yml" ]; then
  echo "ERROR: run this script from the SystemSentinel repository."
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "ERROR: this installer currently supports Ubuntu/Debian (apt-based systems)."
  exit 1
fi

SUDO=""
if [ "${EUID}" -ne 0 ]; then
  SUDO="sudo"
fi

log() {
  printf '\n==> %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1"
    exit 1
  fi
}

set_env_var() {
  local key="$1"
  local value="$2"
  local file="$3"

  if grep -qE "^${key}=" "${file}"; then
    sed -i "s#^${key}=.*#${key}=${value}#" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

get_env_var() {
  local key="$1"
  local file="$2"
  grep -E "^${key}=" "${file}" | tail -n1 | cut -d= -f2-
}

install_docker() {
  log "Installing Docker Engine + Buildx + Compose plugin"
  ${SUDO} apt-get update
  ${SUDO} apt-get install -y ca-certificates curl gnupg lsb-release

  ${SUDO} install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | ${SUDO} gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    ${SUDO} chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  . /etc/os-release
  ARCH="$(dpkg --print-architecture)"
  CODENAME="${VERSION_CODENAME:-$(lsb_release -cs)}"
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    | ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null

  ${SUDO} apt-get update
  ${SUDO} apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ${SUDO} systemctl enable --now docker
}

pick_docker_cmd() {
  if docker info >/dev/null 2>&1; then
    echo "docker"
    return
  fi
  if ${SUDO} docker info >/dev/null 2>&1; then
    echo "${SUDO} docker"
    return
  fi
  echo "ERROR"
}

prepare_env() {
  if [ ! -f .env ]; then
    cp .env.example .env
  fi

  # Allow caller to inject values when running script.
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && set_env_var "TELEGRAM_BOT_TOKEN" "${TELEGRAM_BOT_TOKEN}" .env
  [ -n "${TELEGRAM_CHAT_ID:-}" ] && set_env_var "TELEGRAM_CHAT_ID" "${TELEGRAM_CHAT_ID}" .env
  [ -n "${SSH_TARGETS:-}" ] && set_env_var "SSH_TARGETS" "${SSH_TARGETS}" .env
  [ -n "${NETWORK_INTERFACE:-}" ] && set_env_var "NETWORK_INTERFACE" "${NETWORK_INTERFACE}" .env

  # Auto-bind to NetBird interface if available and no explicit override was provided.
  if [ -z "${MONITOR_BIND_ADDR:-}" ]; then
    if ip -4 addr show wt0 >/dev/null 2>&1; then
      NB_IP="$(ip -4 -o addr show wt0 | awk '{print $4}' | cut -d/ -f1 | head -n1)"
      if [ -n "${NB_IP}" ]; then
        set_env_var "MONITOR_BIND_ADDR" "${NB_IP}" .env
      fi
    fi
  else
    set_env_var "MONITOR_BIND_ADDR" "${MONITOR_BIND_ADDR}" .env
  fi

  # Validate required runtime vars.
  local bot chat ssh
  bot="$(get_env_var TELEGRAM_BOT_TOKEN .env || true)"
  chat="$(get_env_var TELEGRAM_CHAT_ID .env || true)"
  ssh="$(get_env_var SSH_TARGETS .env || true)"

  if [ -z "${bot}" ] || [[ "${bot}" == replace_with_* ]]; then
    echo "ERROR: TELEGRAM_BOT_TOKEN is not configured in .env"
    exit 1
  fi
  if [ -z "${chat}" ] || [[ "${chat}" == replace_with_* ]]; then
    echo "ERROR: TELEGRAM_CHAT_ID is not configured in .env"
    exit 1
  fi
  if [ -z "${ssh}" ]; then
    echo "ERROR: SSH_TARGETS is not configured in .env"
    exit 1
  fi
}

log "Checking prerequisites"
require_cmd curl
require_cmd awk
require_cmd sed
require_cmd ip

log "Checking Prometheus client submodule"
if [ ! -d "lib/prometheus-client-c/prom" ] || [ ! -d "lib/prometheus-client-c/promhttp" ]; then
  if [ -d ".git" ] && command -v git >/dev/null 2>&1; then
    git submodule sync --recursive
    git submodule update --init --recursive
  fi
fi

if [ ! -d "lib/prometheus-client-c/prom" ] || [ ! -d "lib/prometheus-client-c/promhttp" ]; then
  echo "ERROR: lib/prometheus-client-c submodule is missing."
  echo "Run: git submodule update --init --recursive"
  exit 1
fi

install_docker

TARGET_USER="${SUDO_USER:-${USER}}"
if ! id -nG "${TARGET_USER}" | grep -qw docker; then
  log "Adding ${TARGET_USER} to docker group"
  ${SUDO} usermod -aG docker "${TARGET_USER}" || true
fi

prepare_env

DOCKER_CMD="$(pick_docker_cmd)"
if [ "${DOCKER_CMD}" = "ERROR" ]; then
  echo "ERROR: Docker daemon is not reachable. Check: systemctl status docker"
  exit 1
fi

log "Using Docker command: ${DOCKER_CMD}"

log "Starting SystemSentinel stack"
# shellcheck disable=SC2086
${DOCKER_CMD} compose up -d --build

log "Initializing exporter FIFO metrics"
METRICS="${SYSTEM_SENTINEL_METRICS:-cpu_usage_percentage,memory_usage_percentage,disk_usage_percentage,available_memory_mb,io_time_ms,rx_bytes_total,tx_bytes_total,rx_errors_total,tx_errors_total,dropped_packets_total}"
TRIES=30
until ${DOCKER_CMD} compose exec -T app sh -lc 'test -p /tmp/monitor_fifo' >/dev/null 2>&1; do
  TRIES=$((TRIES - 1))
  if [ "${TRIES}" -le 0 ]; then
    echo "ERROR: timed out waiting for /tmp/monitor_fifo"
    exit 1
  fi
  sleep 2
done
${DOCKER_CMD} compose exec -T app sh -lc "printf '%s' \"${METRICS}\" > /tmp/monitor_fifo"

BIND_ADDR="$(get_env_var MONITOR_BIND_ADDR .env || true)"
[ -z "${BIND_ADDR}" ] && BIND_ADDR="127.0.0.1"

log "Deployment complete"
echo "Prometheus:   http://${BIND_ADDR}:9090"
echo "Grafana:      http://${BIND_ADDR}:3000"
echo "Alertmanager: http://${BIND_ADDR}:9093"
echo "App metrics:  http://${BIND_ADDR}:8000/metrics"
echo ""
echo "If docker access fails without sudo in a new shell, run:"
echo "  newgrp docker"
