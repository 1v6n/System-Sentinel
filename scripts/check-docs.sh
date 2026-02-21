#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DOXYFILE_PATH="${DOXYFILE_PATH:-${REPO_ROOT}/Doxyfile}"
ERROR_FILE="${DOXYGEN_ERROR_FILE:-${REPO_ROOT}/dox_errors.txt}"

if ! command -v doxygen >/dev/null 2>&1; then
  echo "ERROR: doxygen is not installed"
  exit 1
fi

if [ ! -f "${DOXYFILE_PATH}" ]; then
  echo "ERROR: Doxygen config not found: ${DOXYFILE_PATH}"
  exit 1
fi

rm -f "${ERROR_FILE}"

# Ensure OUTPUT_DIRECTORY exists before running doxygen.
OUTPUT_DIR="$(
  awk -F= '
    $1 ~ /^[[:space:]]*OUTPUT_DIRECTORY[[:space:]]*$/ {
      v=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      print v
      exit
    }
  ' "${DOXYFILE_PATH}"
)"

if [ -n "${OUTPUT_DIR}" ]; then
  case "${OUTPUT_DIR}" in
    /*) mkdir -p "${OUTPUT_DIR}" ;;
    *) mkdir -p "${REPO_ROOT}/${OUTPUT_DIR}" ;;
  esac
fi

echo "Running doxygen check with ${DOXYFILE_PATH}..."
doxygen -s "${DOXYFILE_PATH}" 2> "${ERROR_FILE}"

if [ -s "${ERROR_FILE}" ]; then
  echo "ERROR: Doxygen reported warnings/errors. See ${ERROR_FILE}"
  cat "${ERROR_FILE}"
  exit 1
fi

echo "Doxygen check passed."
