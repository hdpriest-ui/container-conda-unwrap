#!/usr/bin/env bash

set -uo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <install_command_file>" >&2
  exit 1
fi

CMD_FILE="$1"

if [[ ! -f "$CMD_FILE" ]]; then
  echo "Command file '$CMD_FILE' not found." >&2
  exit 1
fi

LOG_DIR="logs"
mkdir -p "$LOG_DIR"
TS="$(date +'%Y%m%d-%H%M%S')"
LOG_FILE="${LOG_DIR}/run_install_${TS}.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "=================================================="
echo "run_install_file.sh starting at $(date)"
echo "Install file: $CMD_FILE"
echo "Log file   : $LOG_FILE"
echo "Working dir: $(pwd)"
echo "=================================================="
echo

LINE_NO=0

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  LINE_NO=$((LINE_NO + 1))

  # Skip empty lines
  if [[ -z "${LINE//[[:space:]]/}" ]]; then
    continue
  fi

  # Skip comments (lines starting with #, possibly after whitespace)
  if [[ "$LINE" =~ ^[[:space:]]*# ]]; then
    echo "Skipping comment on line $LINE_NO: $LINE"
    continue
  fi

  echo "--------------------------------------------------"
  echo "[$(date +'%F %T')] Executing line $LINE_NO:"
  echo "$LINE"
  echo "--------------------------------------------------"

  eval "$LINE"
  STATUS=$?

  if [[ $STATUS -ne 0 ]]; then
    echo
    echo "ERROR: Command on line $LINE_NO failed with exit code $STATUS."
    echo "Stopping further execution."
    echo
    exit $STATUS
  fi

  echo "Line $LINE_NO completed successfully."
  echo
done < "$CMD_FILE"

echo "=================================================="
echo "All commands completed successfully at $(date)."
echo "Full log in: $LOG_FILE"
echo "=================================================="
