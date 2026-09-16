#!/usr/bin/env bash
set -Eeuo pipefail

# Compatibility entrypoint. Каноническая публичная команда теперь использует
# bootstrap-pve.sh. Этот файл сохраняется, чтобы старые сохранённые curl-команды
# продолжали работать во время миграции.

URL="https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/bootstrap-pve.sh"
TMP="$(mktemp /tmp/proxmox-bootstrap-pve.XXXXXX.sh)"
cleanup() { rm -f -- "$TMP"; }
trap cleanup EXIT

if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    printf '\033[1;33m[ПРЕДУПРЕЖДЕНИЕ]\033[0m init-pve.sh устарел; используйте bootstrap-pve.sh\n' >&2
else
    printf '[ПРЕДУПРЕЖДЕНИЕ] init-pve.sh устарел; используйте bootstrap-pve.sh\n' >&2
fi

command -v curl >/dev/null 2>&1 || {
    printf 'ОШИБКА: для compatibility loader требуется curl\n' >&2
    exit 1
}

curl -fsSL --connect-timeout 10 --max-time 60 "$URL" -o "$TMP"
chmod 0700 "$TMP"
bash "$TMP" "$@"
