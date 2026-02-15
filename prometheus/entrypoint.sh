#!/bin/sh
set -eu

SSH_TARGETS_RAW="${SSH_TARGETS:-${SSH_TARGET:-}}"
: "${SSH_TARGETS_RAW:?SSH_TARGETS (or SSH_TARGET) is required (example: Netbird Main=100.124.161.192:22,Backup=10.0.0.5:22)}"

SSH_STATIC_CONFIGS_FILE="/tmp/ssh_static_configs.yml"
: > "${SSH_STATIC_CONFIGS_FILE}"

yaml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

echo "${SSH_TARGETS_RAW}" | tr ',' '\n' | while IFS= read -r entry; do
  trimmed="$(echo "${entry}" | xargs)"
  [ -n "${trimmed}" ] || continue

  alias_name=""
  target="${trimmed}"
  case "${trimmed}" in
    *=*)
      alias_name="$(printf '%s' "${trimmed%%=*}" | xargs)"
      target="$(printf '%s' "${trimmed#*=}" | xargs)"
      ;;
  esac

  [ -n "${target}" ] || continue

  target_escaped="$(yaml_escape "${target}")"
  if [ -n "${alias_name}" ]; then
    alias_escaped="$(yaml_escape "${alias_name}")"
    printf '      - targets: ["%s"]\n' "${target_escaped}" >> "${SSH_STATIC_CONFIGS_FILE}"
    printf '        labels:\n' >> "${SSH_STATIC_CONFIGS_FILE}"
    printf '          instance: "%s"\n' "${alias_escaped}" >> "${SSH_STATIC_CONFIGS_FILE}"
  else
    printf '      - targets: ["%s"]\n' "${target_escaped}" >> "${SSH_STATIC_CONFIGS_FILE}"
  fi
done

if [ ! -s "${SSH_STATIC_CONFIGS_FILE}" ]; then
  echo "ERROR: no valid SSH targets found in SSH_TARGETS/SSH_TARGET"
  exit 1
fi

awk '
  /__SSH_STATIC_CONFIGS__/ {
    while ((getline line < cfg) > 0) print line
    close(cfg)
    next
  }
  { print }
' cfg="${SSH_STATIC_CONFIGS_FILE}" /etc/prometheus/prometheus.yml.tmpl > /tmp/prometheus.yml

cp /etc/prometheus/alert.rules.yml.tmpl /tmp/alert.rules.yml

exec /bin/prometheus \
  --config.file=/tmp/prometheus.yml \
  --storage.tsdb.path=/prometheus
