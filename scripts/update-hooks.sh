#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

echo "Updating pre-commit hook revisions..."
pre-commit autoupdate

echo "Running hooks after update..."
pre-commit run --all-files

echo "Done. Review changes in .pre-commit-config.yaml and commit if valid."
