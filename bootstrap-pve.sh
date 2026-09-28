#!/usr/bin/env bash
set -Eeuo pipefail

REF="${PROXMOX_BOOTSTRAP_REF:-feature/bootstrap-990}"
URL="https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/${REF}/bootstrap-pve.py"

command -v curl >/dev/null 2>&1 || { echo "ОШИБКА: не найден curl" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ОШИБКА: не найден python3" >&2; exit 1; }

SCRIPT="$(mktemp /run/proxmox-public-bootstrap.XXXXXX.py)"
trap 'rm -f "$SCRIPT"' EXIT

curl -fsSL "$URL" -o "$SCRIPT"
python3 "$SCRIPT" "$@"
