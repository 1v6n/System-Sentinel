#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODE="${1:-all}"

cd "${REPO_ROOT}"

case "$MODE" in
  all)
    echo "Running pre-commit on all files..."
    pre-commit run --all-files
    ;;
  staged)
    echo "Running pre-commit on staged files..."
    pre-commit run
    ;;
  *)
    echo "Usage: $0 [all|staged]"
    exit 1
    ;;
esac
