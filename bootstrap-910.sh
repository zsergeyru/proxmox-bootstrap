#!/usr/bin/env bash
set -Eeuo pipefail

# Публичный стартовый сценарий, который выполняется только внутри LXC 910.
# Его задача — подготовить Debian, получить закрытый проект и передать ему управление.

GUEST_BOOTSTRAP_VERSION="1.0.0"

PRIVATE_REPO="git@github.com:zsergeyru/proxmox.git"
PRIVATE_BRANCH="infra-iac-redesign"
PRIVATE_SETUP_PATH="scripts/infra-deployer/setup.sh"
PRIVATE_HOST_ACCESS_PATH="scripts/infra-deployer/pve-bootstrap-access.sh"

BOOTSTRAP_DIR="/root/.infra-deployer-bootstrap"
PVE_API_SECRET_FILE="${BOOTSTRAP_DIR}/pve-api.env"
HOST_HELPER_FILE="${BOOTSTRAP_DIR}/pve-host-helper.sh"

GITHUB_KEY="/root/.ssh/github_proxmox_repo_ed25519"
GITHUB_PUB="${GITHUB_KEY}.pub"
GITHUB_KNOWN_HOSTS="/root/.ssh/github_known_hosts"
GITHUB_SSH_CONFIG="/root/.ssh/github_config"

PROJECT_DIR="/var/lib/infra-deployer/bootstrap-repo"
STATUS_COMMAND="/usr/local/sbin/infra-deployer-status"

PHASE=""
RECOVER=0

log()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '[ОК] %s\n' "$*"; }
info() { printf '[ИНФО] %s\n' "$*"; }
die()  { printf '\nОШИБКА: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Использование:
  bootstrap-910.sh prepare [--project-branch NAME]
  bootstrap-910.sh finish  [--project-branch NAME] [--recover]
  bootstrap-910.sh check

Этапы:
  prepare   подготовить Debian, GitHub Deploy Key и закрытый проект внутри 910
  finish    выполнить основную настройку 910 из закрытого проекта
  check     проверить готовность 910
USAGE
}

parse_args() {
    (($#)) || { usage >&2; exit 2; }
    PHASE=$1
    shift

    case "$PHASE" in
        prepare|finish|check) ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Неизвестный этап: $PHASE"
            ;;
    esac

    while (($#)); do
        case "$1" in
            --project-branch)
                shift
                (($#)) || die "После --project-branch требуется имя ветки"
                PRIVATE_BRANCH=$1
                ;;
            --recover)
                RECOVER=1
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

    [[ "$PRIVATE_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]]         || die "Некорректное имя ветки проекта: $PRIVATE_BRANCH"

    [[ "$PHASE" == "finish" || "$RECOVER" == "0" ]]         || die "--recover допустим только для этапа finish"
}

require_guest_root() {
    [[ $EUID -eq 0 ]] || die "Сценарий должен выполняться от root внутри LXC 910"
    [[ -f /etc/debian_version ]] || die "Внутри 910 ожидается Debian"
}

ensure_base_packages() {
    local pkg missing=()

    for pkg in ca-certificates curl git jq openssh-client; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done

    if (("${#missing[@]}" == 0)); then
        ok "Минимальная Debian-основа уже готова"
        return
    fi

    log "Минимальная подготовка Debian внутри LXC 910"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    ok "Минимальная Debian-основа внутри LXC готова"
}

ensure_github_key() {
    install -d -m 0700 /root/.ssh

    if [[ -f "$GITHUB_KEY" ]]; then
        ok "GitHub Deploy Key внутри 910 уже существует"
    else
        [[ ! -e "$GITHUB_PUB" ]] || die "Есть public GitHub key без private key"
        ssh-keygen -q -t ed25519 -N ''             -C infra-deployer-readonly-zsergeyru-proxmox             -f "$GITHUB_KEY"
        ok "GitHub Deploy Key создан внутри 910"
    fi

    curl -fsSL --connect-timeout 10 --max-time 20 https://api.github.com/meta         | jq -r '.ssh_keys[] | "github.com " + .' >"$GITHUB_KNOWN_HOSTS"

    cat >"$GITHUB_SSH_CONFIG" <<EOF_SSH
Host github.com
    HostName github.com
    User git
    IdentityFile $GITHUB_KEY
    IdentitiesOnly yes
    UserKnownHostsFile $GITHUB_KNOWN_HOSTS
    StrictHostKeyChecking yes
    BatchMode yes
    ConnectTimeout 10
EOF_SSH

    chmod 0600 "$GITHUB_KEY" "$GITHUB_SSH_CONFIG"
    chmod 0644 "$GITHUB_PUB" "$GITHUB_KNOWN_HOSTS"
}

private_branch_accessible() {
    GIT_SSH_COMMAND="ssh -F $GITHUB_SSH_CONFIG"         git ls-remote "$PRIVATE_REPO" "refs/heads/$PRIVATE_BRANCH" 2>/dev/null         | grep -q .
}

require_private_repo_access() {
    if private_branch_accessible; then
        ok "910 имеет read-only доступ к закрытому проекту"
        return
    fi

    printf '\nДобавьте этот ключ в GitHub как read-only Deploy Key репозитория zsergeyru/proxmox:\n\n'
    cat "$GITHUB_PUB"
    printf '\nGitHub -> zsergeyru/proxmox -> Settings -> Deploy keys -> Add deploy key\n'
    printf 'Allow write access: ВЫКЛЮЧЕН\n\n'

    # Специальный код возврата понимает только bootstrap-pve.sh.
    exit 42
}

checkout_private_project() {
    local origin

    log "Получение закрытого проекта внутри 910"

    if [[ -d "$PROJECT_DIR/.git" ]]; then
        origin="$(git -C "$PROJECT_DIR" remote get-url origin)"
        [[ "$origin" == "$PRIVATE_REPO" ]]             || die "Закрытый проект имеет неожиданный origin: $origin"

        GIT_SSH_COMMAND="ssh -F $GITHUB_SSH_CONFIG"             git -C "$PROJECT_DIR" fetch --depth 1 origin "$PRIVATE_BRANCH"
        git -C "$PROJECT_DIR" reset --hard FETCH_HEAD
        git -C "$PROJECT_DIR" clean -ffdx
    else
        rm -rf "$PROJECT_DIR"
        install -d -m 0755 "$(dirname "$PROJECT_DIR")"
        GIT_SSH_COMMAND="ssh -F $GITHUB_SSH_CONFIG"             git clone --depth 1 --branch "$PRIVATE_BRANCH" "$PRIVATE_REPO" "$PROJECT_DIR"
    fi

    ok "Закрытый проект получен внутри 910"
}

stage_host_helper() {
    local source="$PROJECT_DIR/$PRIVATE_HOST_ACCESS_PATH"

    [[ -f "$source" ]] || die "В закрытом проекте отсутствует $PRIVATE_HOST_ACCESS_PATH"
    install -d -m 0700 "$BOOTSTRAP_DIR"
    install -m 0600 "$source" "$HOST_HELPER_FILE"
    ok "Одноразовый PVE helper подготовлен для запуска на хосте"
}

prepare() {
    ensure_base_packages
    ensure_github_key
    require_private_repo_access
    checkout_private_project
    stage_host_helper
}

finish() {
    local setup="$PROJECT_DIR/$PRIVATE_SETUP_PATH"

    [[ -f "$setup" ]] || die "В закрытом проекте отсутствует $PRIVATE_SETUP_PATH"

    log "Основная настройка infra-deployer внутри 910"
    INFRA_DEPLOYER_BOOTSTRAP=1     INFRA_DEPLOYER_RECOVER="$RECOVER"     INFRA_PROJECT_BRANCH="$PRIVATE_BRANCH"     PVE_API_SECRET_FILE="$PVE_API_SECRET_FILE"         bash "$setup"

    rm -f "$PVE_API_SECRET_FILE" "$HOST_HELPER_FILE"
    ok "Внутренняя настройка 910 завершена"
}

check_ready() {
    [[ -x "$STATUS_COMMAND" ]] || die "В 910 отсутствует infra-deployer-status"
    "$STATUS_COMMAND"
    ok "910 infra-deployer готов"
}

main() {
    parse_args "$@"
    require_guest_root
    info "Guest Bootstrap v$GUEST_BOOTSTRAP_VERSION, этап: $PHASE"

    case "$PHASE" in
        prepare) prepare ;;
        finish)  finish ;;
        check)   check_ready ;;
    esac
}

main "$@"
