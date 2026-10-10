#!/usr/bin/env bash
set -Eeuo pipefail

# Минимальная публичная оболочка: получить Python-загрузчик из GitHub и
# передать ему аргументы. Не создаёт гостей и не решает вопросы восстановления.
# Временный файл удаляется при завершении, включая неуспешный запуск.

REF="${PROXMOX_BOOTSTRAP_REF:-main}"
URL="https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/${REF}/bootstrap-pve.py"

if ! command -v curl >/dev/null 2>&1; then
    echo "ОШИБКА: не найден curl. Установите curl на PVE и повторите запуск." >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "ОШИБКА: не найден python3. Установите Python 3 на PVE и повторите запуск." >&2
    exit 1
fi

if ! SCRIPT="$(mktemp /run/proxmox-public-bootstrap.XXXXXX.py)"; then
    echo "ОШИБКА: не удалось создать временный файл в /run. Проверьте свободное место и права каталога." >&2
    exit 1
fi
trap 'rm -f "$SCRIPT"' EXIT

if ! curl -fsSL --connect-timeout 15 --max-time 90 "$URL" -o "$SCRIPT"; then
    echo "ОШИБКА: не удалось получить bootstrap-pve.py из GitHub (ветка: $REF)." >&2
    echo "Проверьте сеть, DNS, доступность GitHub и наличие указанной ветки; затем повторите запуск." >&2
    exit 1
fi
if [[ ! -s "$SCRIPT" ]]; then
    echo "ОШИБКА: GitHub вернул пустой bootstrap-pve.py. Проверьте адрес и ветку: $REF." >&2
    exit 1
fi

# Код возврата Python передаётся без подмены; подробные ошибки формирует Python.
python3 "$SCRIPT" "$@"
