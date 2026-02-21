#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

echo "Installing development tooling (pre-commit + clang-format)..."

if command -v pacman >/dev/null 2>&1; then
  sudo pacman -S --needed --noconfirm pre-commit clang
elif command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y pre-commit clang-format
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y pre-commit clang-tools-extra
else
  echo "Unsupported package manager. Install pre-commit and clang-format manually."
  exit 1
fi

echo "Installing git hooks..."
pre-commit install

echo "Running hooks on all tracked files..."
pre-commit run --all-files

echo "Bootstrap complete."
