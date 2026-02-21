#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "Scanning repo for potential hardcoded Telegram secrets..."

if rg -n --hidden --glob '!.git' --glob '!.env' --glob '!.env.example' \
  '(bot_token:[[:space:]]*"[0-9]{6,}:[A-Za-z0-9_-]{20,}")|(chat_id:[[:space:]]*-?[0-9]{6,})' "${REPO_ROOT}"; then
  echo "ERROR: Potential hardcoded Telegram credentials found."
  exit 1
fi

echo "No hardcoded Telegram secrets found."
