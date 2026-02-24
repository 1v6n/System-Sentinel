#!/usr/bin/env bash
set -euo pipefail

# One-shot installer for Oracle ARM Ubuntu/Debian VM.
# - Installs Docker Engine + Compose plugin (official Docker repo)
# - Prepares .env (optionally from exported env vars)
# - Binds services to NetBird IP when available
# - Starts full stack and initializes exporter FIFO
# - Runs post-install health validation

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"
ENV_FILE="${ROOT_DIR}/.env"
ENV_EXAMPLE_FILE="${ROOT_DIR}/.env.example"
cd "${ROOT_DIR}"

DRY_RUN=0
LOG_FILE="${INSTALL_LOG_FILE:-/tmp/systemsentinel-install.log}"
SUDO=""

usage() {
  cat <<USAGE
Usage: bash scripts/install-oracle-arm.sh [options]

Options:
  --dry-run           Print planned actions without executing changes.
  --log-file <path>   Write installer logs to custom file.
  -h, --help          Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --log-file)
      shift
      [ "$#" -gt 0 ] || {
        echo "ERROR: --log-file requires a path"
        exit 1
      }
      LOG_FILE="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

mkdir -p "$(dirname "${LOG_FILE}")"
: > "${LOG_FILE}"

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log_info() { printf '%s [INFO] %s\n' "$(timestamp)" "$*" | tee -a "${LOG_FILE}"; }
log_warn() { printf '%s [WARN] %s\n' "$(timestamp)" "$*" | tee -a "${LOG_FILE}"; }
log_error() { printf '%s [ERROR] %s\n' "$(timestamp)" "$*" | tee -a "${LOG_FILE}" >&2; }

run_cmd() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    log_info "[dry-run] $*"
    return 0
  fi
  log_info "run: $*"
  "$@"
}

run_sh() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    log_info "[dry-run] $*"
    return 0
  fi
  log_info "run(sh): $*"
  bash -lc "$*"
}

on_error() {
  local line="$1"
  log_error "Installer failed at line ${line}."
  log_info "Rollback hints:"
  log_info "  docker compose logs --tail=200"
  log_info "  docker compose down"
  log_info "Log file: ${LOG_FILE}"
}
trap 'on_error $LINENO' ERR

if [ ! -f "${COMPOSE_FILE}" ]; then
  log_error "run this script from the SystemSentinel repository."
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  log_error "this installer currently supports Ubuntu/Debian/Raspberry Pi OS (apt-based systems)."
  exit 1
fi

if [ "${EUID}" -ne 0 ]; then
  SUDO="sudo"
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "required command not found: $1"
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

wait_for_url() {
  local url="$1"
  local tries="${2:-30}"
  local sleep_secs="${3:-2}"
  local i=1

  while [ "${i}" -le "${tries}" ]; do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      log_info "health OK: ${url}"
      return 0
    fi
    log_info "waiting for ${url} (${i}/${tries})"
    sleep "${sleep_secs}"
    i=$((i + 1))
  done

  log_error "timeout waiting for ${url}"
  return 1
}

install_docker() {
  log_info "Installing Docker Engine + Buildx + Compose plugin"
  run_cmd ${SUDO} apt-get update
  run_cmd ${SUDO} apt-get install -y ca-certificates curl gnupg lsb-release

  . /etc/os-release
  local distro_id docker_repo_id arch codename docker_codename
  distro_id="${ID:-}"
  docker_repo_id="${distro_id}"
  arch="$(dpkg --print-architecture)"
  codename="${VERSION_CODENAME:-}"
  if [ -z "${codename}" ]; then
    codename="$(lsb_release -cs 2>/dev/null || true)"
  fi
  if [ -z "${codename}" ] && [ -n "${DEBIAN_CODENAME:-}" ]; then
    codename="${DEBIAN_CODENAME}"
  fi
  if [ -z "${codename}" ] && [ -n "${UBUNTU_CODENAME:-}" ]; then
    codename="${UBUNTU_CODENAME}"
  fi

  case "${distro_id}" in
    ubuntu|debian)
      ;;
    raspbian)
      docker_repo_id="raspbian"
      ;;
    *)
      log_error "unsupported distro '${distro_id}'. This installer supports Ubuntu/Debian/Raspberry Pi OS."
      exit 1
      ;;
  esac

  if [ -z "${codename}" ]; then
    log_error "could not detect distro codename from /etc/os-release"
    exit 1
  fi

  docker_codename=""
  if curl -fsSI "https://download.docker.com/linux/${docker_repo_id}/dists/${codename}/Release" >/dev/null 2>&1; then
    docker_codename="${codename}"
  else
    for candidate in \
      $(
        if [ "${distro_id}" = "ubuntu" ]; then
          printf '%s\n' noble jammy focal
        elif [ "${distro_id}" = "raspbian" ]; then
          printf '%s\n' bookworm bullseye buster
        else
          printf '%s\n' bookworm bullseye
        fi
      ); do
      if curl -fsSI "https://download.docker.com/linux/${docker_repo_id}/dists/${candidate}/Release" >/dev/null 2>&1; then
        docker_codename="${candidate}"
        break
      fi
    done
  fi

  if [ -z "${docker_codename}" ]; then
    log_error "no supported Docker APT repo found for distro='${distro_id}' codename='${codename}'"
    exit 1
  fi
  if [ "${docker_codename}" != "${codename}" ]; then
    log_warn "Docker repo does not support '${codename}' yet; using '${docker_codename}'"
  fi

  run_cmd ${SUDO} install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    run_sh "curl -fsSL https://download.docker.com/linux/${docker_repo_id}/gpg | ${SUDO} gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
    run_cmd ${SUDO} chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  run_sh "echo 'deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${docker_repo_id} ${docker_codename} stable' | ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null"

  run_cmd ${SUDO} apt-get update
  run_cmd ${SUDO} apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run_cmd ${SUDO} systemctl enable --now docker
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
  if [ ! -f "${ENV_FILE}" ]; then
    cp "${ENV_EXAMPLE_FILE}" "${ENV_FILE}"
  fi

  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && set_env_var "TELEGRAM_BOT_TOKEN" "${TELEGRAM_BOT_TOKEN}" "${ENV_FILE}"
  [ -n "${TELEGRAM_CHAT_ID:-}" ] && set_env_var "TELEGRAM_CHAT_ID" "${TELEGRAM_CHAT_ID}" "${ENV_FILE}"
  [ -n "${SSH_TARGETS:-}" ] && set_env_var "SSH_TARGETS" "${SSH_TARGETS}" "${ENV_FILE}"
  [ -n "${NETWORK_INTERFACE:-}" ] && set_env_var "NETWORK_INTERFACE" "${NETWORK_INTERFACE}" "${ENV_FILE}"

  if [ -z "${MONITOR_BIND_ADDR:-}" ]; then
    if ip -4 addr show wt0 >/dev/null 2>&1; then
      NB_IP="$(ip -4 -o addr show wt0 | awk '{print $4}' | cut -d/ -f1 | head -n1)"
      if [ -n "${NB_IP}" ]; then
        set_env_var "MONITOR_BIND_ADDR" "${NB_IP}" "${ENV_FILE}"
      fi
    fi
  else
    set_env_var "MONITOR_BIND_ADDR" "${MONITOR_BIND_ADDR}" "${ENV_FILE}"
  fi

  local bot chat ssh bind_addr
  bot="$(get_env_var TELEGRAM_BOT_TOKEN "${ENV_FILE}" || true)"
  chat="$(get_env_var TELEGRAM_CHAT_ID "${ENV_FILE}" || true)"
  ssh="$(get_env_var SSH_TARGETS "${ENV_FILE}" || true)"
  bind_addr="$(get_env_var MONITOR_BIND_ADDR "${ENV_FILE}" || true)"

  if [ -z "${bot}" ] || [[ "${bot}" == replace_with_* ]]; then
    log_error "TELEGRAM_BOT_TOKEN is not configured in .env"
    exit 1
  fi
  if [ -z "${chat}" ] || [[ "${chat}" == replace_with_* ]]; then
    log_error "TELEGRAM_CHAT_ID is not configured in .env"
    exit 1
  fi
  if [ -z "${ssh}" ]; then
    log_error "SSH_TARGETS is not configured in .env"
    exit 1
  fi
  if [ "${bind_addr}" = "0.0.0.0" ]; then
    log_warn "MONITOR_BIND_ADDR=0.0.0.0 exposes monitoring ports on all interfaces. Prefer NetBird IP or 127.0.0.1."
  fi
}

post_install_validate() {
  local bind_addr
  bind_addr="$(get_env_var MONITOR_BIND_ADDR "${ENV_FILE}" || true)"
  [ -z "${bind_addr}" ] && bind_addr="127.0.0.1"

  if [ "${DRY_RUN}" -eq 1 ]; then
    log_info "Skipping post-install validation in dry-run mode."
    return 0
  fi

  log_info "Running post-install validation"
  wait_for_url "http://${bind_addr}:8000/metrics"
  wait_for_url "http://${bind_addr}:9090/-/ready"
  wait_for_url "http://${bind_addr}:9093/-/healthy"
  wait_for_url "http://${bind_addr}:9115/-/healthy"

  curl -fsS "http://${bind_addr}:8000/metrics" | grep -q "cpu_usage_percentage"
  curl -fsS "http://${bind_addr}:9090/api/v1/targets" >/dev/null
  log_info "Validation completed successfully"
}

log_info "Checking prerequisites"
require_cmd curl
require_cmd awk
require_cmd sed
require_cmd ip

log_info "Checking Prometheus client submodule"
if [ ! -d "lib/prometheus-client-c/prom" ] || [ ! -d "lib/prometheus-client-c/promhttp" ]; then
  if [ -d ".git" ] && command -v git >/dev/null 2>&1; then
    run_cmd git submodule sync --recursive
    run_cmd git submodule update --init --recursive
  fi
fi

if [ ! -d "lib/prometheus-client-c/prom" ] || [ ! -d "lib/prometheus-client-c/promhttp" ]; then
  log_error "lib/prometheus-client-c submodule is missing."
  log_error "Run: git submodule update --init --recursive"
  exit 1
fi

install_docker

TARGET_USER="${SUDO_USER:-${USER}}"
if ! id -nG "${TARGET_USER}" | grep -qw docker; then
  log_info "Adding ${TARGET_USER} to docker group"
  run_cmd ${SUDO} usermod -aG docker "${TARGET_USER}"
fi

prepare_env

DOCKER_CMD="$(pick_docker_cmd)"
if [ "${DOCKER_CMD}" = "ERROR" ] && [ "${DRY_RUN}" -eq 0 ]; then
  log_error "Docker daemon is not reachable. Check: systemctl status docker"
  exit 1
fi
if [ "${DOCKER_CMD}" = "ERROR" ] && [ "${DRY_RUN}" -eq 1 ]; then
  DOCKER_CMD="docker"
fi

log_info "Using Docker command: ${DOCKER_CMD}"
log_info "Starting SystemSentinel stack"
# shellcheck disable=SC2086
run_sh "${DOCKER_CMD} compose -f \"${COMPOSE_FILE}\" --project-directory \"${ROOT_DIR}\" up -d --build"

log_info "Initializing exporter FIFO metrics"
METRICS="${SYSTEM_SENTINEL_METRICS:-cpu_usage_percentage,memory_usage_percentage,disk_usage_percentage,available_memory_mb,io_time_ms,rx_bytes_total,tx_bytes_total,rx_errors_total,tx_errors_total,dropped_packets_total}"
if [ "${DRY_RUN}" -eq 0 ]; then
  TRIES=30
  until ${DOCKER_CMD} compose -f "${COMPOSE_FILE}" --project-directory "${ROOT_DIR}" exec -T app sh -lc 'test -p /tmp/monitor_fifo' >/dev/null 2>&1; do
    TRIES=$((TRIES - 1))
    if [ "${TRIES}" -le 0 ]; then
      log_error "timed out waiting for /tmp/monitor_fifo"
      exit 1
    fi
    sleep 2
  done
  ${DOCKER_CMD} compose -f "${COMPOSE_FILE}" --project-directory "${ROOT_DIR}" exec -T app sh -lc "printf '%s' \"${METRICS}\" > /tmp/monitor_fifo"
else
  log_info "[dry-run] would initialize FIFO with metrics: ${METRICS}"
fi

post_install_validate

BIND_ADDR="$(get_env_var MONITOR_BIND_ADDR "${ENV_FILE}" || true)"
[ -z "${BIND_ADDR}" ] && BIND_ADDR="127.0.0.1"

log_info "Deployment complete"
printf 'Prometheus:   http://%s:9090\n' "${BIND_ADDR}" | tee -a "${LOG_FILE}"
printf 'Grafana:      http://%s:3000\n' "${BIND_ADDR}" | tee -a "${LOG_FILE}"
printf 'Alertmanager: http://%s:9093\n' "${BIND_ADDR}" | tee -a "${LOG_FILE}"
printf 'App metrics:  http://%s:8000/metrics\n' "${BIND_ADDR}" | tee -a "${LOG_FILE}"

log_info "If docker access fails without sudo in a new shell, run: newgrp docker"
log_info "Installer log saved to: ${LOG_FILE}"
