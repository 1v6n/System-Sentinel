#!/usr/bin/env bash
set -euo pipefail

DOXYFILE_PATH="${DOXYFILE_PATH:-Doxyfile}"
ERROR_FILE="${DOXYGEN_ERROR_FILE:-dox_errors.txt}"

if ! command -v doxygen >/dev/null 2>&1; then
  echo "ERROR: doxygen is not installed"
  exit 1
fi

if [ ! -f "${DOXYFILE_PATH}" ]; then
  echo "ERROR: Doxygen config not found: ${DOXYFILE_PATH}"
  exit 1
fi

rm -f "${ERROR_FILE}"

echo "Running doxygen check with ${DOXYFILE_PATH}..."
doxygen -s "${DOXYFILE_PATH}" 2> "${ERROR_FILE}"

if [ -s "${ERROR_FILE}" ]; then
  echo "ERROR: Doxygen reported warnings/errors. See ${ERROR_FILE}"
  cat "${ERROR_FILE}"
  exit 1
fi

echo "Doxygen check passed."
