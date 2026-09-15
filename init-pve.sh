#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# Публичная Stage 0 для нового Proxmox VE
# =============================================================================
#
# Этот скрипт намеренно ничего не знает о внутренней архитектуре PVE-проекта.
# Его единственная задача:
#   1) обеспечить наличие Git/SSH;
#   2) создать read-only GitHub Deploy Key;
#   3) получить доступ к приватному zsergeyru/proxmox;
#   4) временно клонировать private repo;
#   5) передать управление приватному bootstrap.
#
# Все роли, ACL, API-токены, pools, templates, deployer и прочая инфраструктура
# описываются и создаются только кодом из закрытого репозитория.

PRIVATE_REPO="git@github.com:zsergeyru/proxmox.git"
PRIVATE_BRANCH="main"

STAGE0_DIR="/var/lib/proxmox-bootstrap"
KEY_FILE="${STAGE0_DIR}/github_proxmox_repo_ed25519"
KEY_PUB_FILE="${KEY_FILE}.pub"
KNOWN_HOSTS="${STAGE0_DIR}/known_hosts"
SSH_CONFIG="${STAGE0_DIR}/ssh_config"
TEMP_REPO="${STAGE0_DIR}/private-repo"
COMPLETE_MARKER="${STAGE0_DIR}/stage0-complete"

FORWARD_ARGS=()

log() { printf '\n==> %s\n' "$*"; }
ok()  { printf '[ОК] %s\n' "$*"; }
warn() { printf '[ПРЕДУПРЕЖДЕНИЕ] %s\n' "$*" >&2; }
die() { printf '\nОШИБКА: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Использование:
  init-pve.sh [--update-system] [--help]

Публичная нулевая стадия инициализации Proxmox VE.
Она только подготавливает Git/SSH, создаёт read-only Deploy Key для приватного
zsergeyru/proxmox и после авторизации передаёт управление приватному bootstrap.

Параметры:
  --update-system  передать приватной стадии запрос полного обновления PVE
  -h, --help       показать эту справку
USAGE
}

while (($#)); do
    case "$1" in
        --update-system)
            FORWARD_ARGS+=("--update-system")
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Неизвестный параметр: $1"
            ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] || die "Запустите скрипт от root на хосте Proxmox"
command -v pveversion >/dev/null 2>&1 || die "Команда pveversion не найдена: этот скрипт нужно запускать на Proxmox VE"
pveversion >/dev/null
ok "Proxmox VE обнаружен"

mkdir -p "$STAGE0_DIR"
chmod 0700 "$STAGE0_DIR"

if [[ -f "$COMPLETE_MARKER" ]]; then
    printf '\nStage 0 уже была успешно завершена.\n'
    printf 'Дальнейшая инициализация и сопровождение выполняются из приватного zsergeyru/proxmox.\n'
    exit 0
fi

ensure_minimal_packages() {
    local packages=(git openssh-client curl jq ca-certificates)
    local missing=0 cmd

    for cmd in git ssh ssh-keygen curl jq; do
        command -v "$cmd" >/dev/null 2>&1 || missing=1
    done

    if (( ! missing )); then
        ok "Минимальный Git/SSH-набор уже установлен"
        return
    fi

    log "Установка минимального Git/SSH-набора"

    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"; then
        warn "Первая попытка установки пакетов не удалась; выполняется apt update без изменения конфигурации репозиториев"
        apt-get update || warn "apt update завершился с предупреждениями; выполняется повторная попытка установки"
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}" \
            || die "Не удалось установить минимальные пакеты. Исправьте доступность APT-репозиториев и повторите запуск."
    fi

    for cmd in git ssh ssh-keygen curl jq; do
        command -v "$cmd" >/dev/null 2>&1 || die "После установки не найдена обязательная команда: $cmd"
    done

    ok "Минимальный Git/SSH-набор установлен"
}

prepare_github_key() {
    log "Подготовка read-only Deploy Key для приватного GitHub-репозитория"

    if [[ ! -f "$KEY_FILE" ]]; then
        ssh-keygen -q -t ed25519 -N '' \
            -C 'pve-zero-day-readonly-zsergeyru-proxmox' \
            -f "$KEY_FILE"
        ok "Создан новый Deploy Key"
    else
        ok "Deploy Key уже существует"
    fi

    chmod 0600 "$KEY_FILE"
    chmod 0644 "$KEY_PUB_FILE"

    local tmp_hosts
    tmp_hosts="$(mktemp)"
    curl -fsSL https://api.github.com/meta \
        | jq -r '.ssh_keys[] | "github.com " + .' >"$tmp_hosts"

    [[ -s "$tmp_hosts" ]] || {
        rm -f "$tmp_hosts"
        die "Не удалось получить SSH host keys GitHub через api.github.com/meta"
    }

    install -m 0644 "$tmp_hosts" "$KNOWN_HOSTS"
    rm -f "$tmp_hosts"

    cat >"$SSH_CONFIG" <<EOF_SSH
Host github.com
    HostName github.com
    User git
    IdentityFile ${KEY_FILE}
    IdentitiesOnly yes
    UserKnownHostsFile ${KNOWN_HOSTS}
    StrictHostKeyChecking yes
EOF_SSH
    chmod 0600 "$SSH_CONFIG"
}

git_private() {
    env GIT_SSH_COMMAND="ssh -F ${SSH_CONFIG}" git "$@"
}

show_waiting() {
    printf '\nОЖИДАНИЕ АВТОРИЗАЦИИ GITHUB\n\n'
    printf 'Добавьте следующий публичный ключ в приватный репозиторий zsergeyru/proxmox:\n\n'
    cat "$KEY_PUB_FILE"
    printf '\nПуть: GitHub -> Settings -> Deploy keys -> Add deploy key\n'
    printf 'Allow write access: ВЫКЛЮЧЕН\n'
    printf '\nПосле добавления ключа снова запустите эту же команду.\n'
}

sync_private_repo() {
    log "Получение приватного bootstrap"

    if [[ ! -d "$TEMP_REPO/.git" ]]; then
        rm -rf "$TEMP_REPO"
        git_private clone --depth 1 --branch "$PRIVATE_BRANCH" "$PRIVATE_REPO" "$TEMP_REPO"
    else
        git_private -C "$TEMP_REPO" fetch --depth 1 origin "$PRIVATE_BRANCH"
        git_private -C "$TEMP_REPO" reset --hard FETCH_HEAD
        git_private -C "$TEMP_REPO" clean -ffd
    fi

    ok "Приватный репозиторий получен"
}

handoff_to_private_bootstrap() {
    local private_init="${TEMP_REPO}/scripts/pve/bootstrap/init-pve.sh"
    [[ -f "$private_init" ]] || die "В приватном репозитории не найден scripts/pve/bootstrap/init-pve.sh"

    log "Передача управления приватной инициализации PVE"

    PVE_STAGE0_DIR="$STAGE0_DIR" \
    PVE_STAGE0_KEY_FILE="$KEY_FILE" \
    PVE_STAGE0_KNOWN_HOSTS="$KNOWN_HOSTS" \
        bash "$private_init" "${FORWARD_ARGS[@]}"
}

cleanup_stage0() {
    local revision now
    revision="$(git -C "$TEMP_REPO" rev-parse HEAD 2>/dev/null || true)"
    now="$(date --iso-8601=seconds)"

    cat >"$COMPLETE_MARKER" <<EOF_MARKER
stage0=complete
timestamp=${now}
private_revision=${revision}
EOF_MARKER
    chmod 0600 "$COMPLETE_MARKER"

    # После успешного handoff приватная стадия уже сохранила Deploy Key и checkout
    # в своей канонической файловой структуре. Временные zero-day копии больше не нужны.
    rm -rf "$TEMP_REPO"
    rm -f "$KEY_FILE" "$KEY_PUB_FILE" "$KNOWN_HOSTS" "$SSH_CONFIG"

    ok "Stage 0 завершена; временные zero-day credentials и checkout удалены"
}

main() {
    ensure_minimal_packages
    prepare_github_key

    if ! git_private ls-remote "$PRIVATE_REPO" HEAD >/dev/null 2>&1; then
        show_waiting
        exit 0
    fi

    ok "Read-only доступ к приватному репозиторию подтверждён"
    sync_private_repo
    handoff_to_private_bootstrap
    cleanup_stage0

    printf '\nПУБЛИЧНАЯ STAGE 0 УСПЕШНО ЗАВЕРШЕНА\n'
    printf 'Дальнейший source of truth и вся логика PVE находятся в приватном zsergeyru/proxmox.\n'
}

main "$@"
