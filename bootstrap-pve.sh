#!/usr/bin/env bash
set -Eeuo pipefail

# Единый bootstrap для Proxmox VE.
# Выполняется только на PVE. Отдельные этапы оформлены функциями,
# а main() задаёт понятную последовательность подготовки LXC 910.

PUBLIC_BOOTSTRAP_VERSION="3.2.0-dev1"

CTID=910
CT_HOSTNAME="infra-deployer"
CT_CORES=2
CT_MEMORY_MB=2048
CT_SWAP_MB=512
CT_DISK_GB=32
CT_STORAGE="local-lvm"
CT_BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"

PROJECT_BRANCH="infra-iac-redesign"

PRIVATE_REPO="git@github.com:zsergeyru/proxmox.git"
PRIVATE_SETUP_PATH="scripts/infra-deployer/setup.sh"
PRIVATE_HOST_ACCESS_PATH="scripts/infra-deployer/pve-bootstrap-access.sh"

HOST_BOOTSTRAP_DIR="/root/.config/proxmox-bootstrap"
HOST_GITHUB_KEY="${HOST_BOOTSTRAP_DIR}/github_proxmox_repo_ed25519"
HOST_GITHUB_PUB="${HOST_GITHUB_KEY}.pub"

CT_BOOTSTRAP_DIR="/root/.infra-deployer-bootstrap"
CT_SECRET_FILE="${CT_BOOTSTRAP_DIR}/pve-api.env"
CT_PROJECT_DIR="/var/lib/infra-deployer/bootstrap-repo"
CT_GITHUB_KEY="/root/.ssh/github_proxmox_repo_ed25519"
CT_GITHUB_PUB="${CT_GITHUB_KEY}.pub"
CT_GITHUB_KNOWN_HOSTS="/root/.ssh/github_known_hosts"
CT_GITHUB_SSH_CONFIG="/root/.ssh/github_config"
CT_LOG_FILE="/var/log/infra-deployer/bootstrap.log"

LOCK_FILE="/run/lock/proxmox-bootstrap.lock"

MODE="apply"
CT_IP="dhcp"
CT_GATEWAY=""

C_RESET=""
C_BOLD=""
C_GREEN=""
C_BLUE=""
C_YELLOW=""
C_RED=""
C_CYAN=""

if [[ -t 1 && "$(printenv NO_COLOR 2>/dev/null || true)" == "" && "$(printenv TERM 2>/dev/null || true)" != "dumb" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_GREEN=$'\033[32m'
    C_BLUE=$'\033[34m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_CYAN=$'\033[36m'
fi

BOOTSTRAP_COLOR=0
[[ -z "$C_RESET" ]] || BOOTSTRAP_COLOR=1

log()  { printf '\n%s%s==> %s%s\n' "$C_BOLD" "$C_BLUE" "$*" "$C_RESET"; }
ok()   { printf '%s%s[ОК]%s %s\n' "$C_BOLD" "$C_GREEN" "$C_RESET" "$*"; }
info() { printf '%s%s[ИНФО]%s %s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$*"; }
warn() { printf '%s%s[ПРЕДУПРЕЖДЕНИЕ]%s %s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '\n%s%sОШИБКА:%s %s\n' "$C_BOLD" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# --- Параметры запуска -----------------------------------------------------

usage() {
    cat <<'USAGE'
Использование:
  bootstrap-pve.sh [параметры]

Режимы:
  без параметра режима     создать или подготовить 910 infra-deployer
  --check                  только проверить готовность существующего 910
  --recover                восстановить/ротировать bootstrap credentials

Сеть 910:
  по умолчанию             DHCP
  --ip CIDR                статический IPv4, например 192.168.1.90/24
  --gateway IPv4           шлюз для статического IPv4

Проект:
  --project-branch NAME    ветка закрытого проекта
                           по умолчанию infra-iac-redesign

Прочее:
  -h, --help               показать справку
USAGE
}

validate_ipv4() {
    local ip=$1 a b c d extra octet
    IFS=. read -r a b c d extra <<<"$ip"
    [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" && -z "$extra" ]] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

validate_ipv4_cidr() {
    local value=$1 ip prefix
    [[ "$value" =~ ^[^/]+/[0-9]{1,2}$ ]] || return 1
    ip=$(printf '%s' "$value" | cut -d/ -f1)
    prefix=$(printf '%s' "$value" | cut -d/ -f2)
    validate_ipv4 "$ip" || return 1
    [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
    ((10#$prefix <= 32))
}

parse_args() {
    while (($#)); do
        case "$1" in
            --check)
                [[ "$MODE" == "apply" ]] || die "Можно выбрать только один режим"
                MODE="check"
                ;;
            --recover)
                [[ "$MODE" == "apply" ]] || die "Можно выбрать только один режим"
                MODE="recover"
                ;;
            --ip)
                shift
                (($#)) || die "После --ip требуется CIDR"
                CT_IP=$1
                ;;
            --gateway)
                shift
                (($#)) || die "После --gateway требуется IPv4"
                CT_GATEWAY=$1
                ;;
            --project-branch)
                shift
                (($#)) || die "После --project-branch требуется имя ветки"
                PROJECT_BRANCH=$1
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

    if [[ "$CT_IP" == "dhcp" ]]; then
        [[ -z "$CT_GATEWAY" ]] || die "--gateway используется только вместе с --ip"
    else
        [[ -n "$CT_GATEWAY" ]] || die "Для статического --ip обязательно укажите --gateway"
        validate_ipv4_cidr "$CT_IP" || die "Некорректный IPv4 CIDR: $CT_IP"
        validate_ipv4 "$CT_GATEWAY" || die "Некорректный IPv4 gateway: $CT_GATEWAY"
    fi

    [[ "$PROJECT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]]         || die "Некорректное имя ветки проекта: $PROJECT_BRANCH"
}

# --- PVE ------------------------------------------------------------------

require_root_and_pve() {
    local cmd
    [[ $EUID -eq 0 ]] || die "Запустите скрипт от root на PVE"

    for cmd in pveversion pvesh pct qm pveam pvesm bash ssh-keygen; do
        command -v "$cmd" >/dev/null 2>&1 || die "Не найдена обязательная штатная команда: $cmd"
    done

    pveversion >/dev/null || die "Не удалось получить версию Proxmox VE"
    ok "Proxmox VE обнаружен"
}

cleanup_host_runtime() {
    rm -f -- "$LOCK_FILE"
}

acquire_lock() {
    command -v flock >/dev/null 2>&1 || die "Не найдена команда flock"
    install -d -m 0755 /run/lock
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Другой bootstrap уже выполняется"
    trap cleanup_host_runtime EXIT
    ok "Получена блокировка bootstrap"
}

storage_exists() {
    pvesm status --storage "$1" >/dev/null 2>&1
}

storage_has_content() {
    local storage=$1 content=$2
    local config="/etc/pve/storage.cfg"

    [[ -r "$config" ]] || return 1

    awk -v storage="$storage" -v wanted="$content" '
        /^[^[:space:]][^:]*:[[:space:]]+/ {
            in_storage = ($2 == storage)
            next
        }

        in_storage && /^[[:space:]]+content[[:space:]]+/ {
            value = $0
            sub(/^[[:space:]]+content[[:space:]]+/, "", value)
            count = split(value, parts, ",")
            for (i = 1; i <= count; i++) {
                if (parts[i] == wanted) {
                    found = 1
                    exit
                }
            }
        }

        END {
            exit(found ? 0 : 1)
        }
    ' "$config"
}

host_preflight() {
    log "Проверка минимальной основы PVE"

    ip link show "$CT_BRIDGE" >/dev/null 2>&1 || die "Не найден сетевой мост $CT_BRIDGE"
    storage_exists "$TEMPLATE_STORAGE" || die "Не найдено хранилище $TEMPLATE_STORAGE"
    storage_exists "$CT_STORAGE" || die "Не найдено хранилище $CT_STORAGE"
    storage_has_content "$TEMPLATE_STORAGE" "vztmpl"         || die "Хранилище $TEMPLATE_STORAGE не разрешает LXC templates"
    storage_has_content "$CT_STORAGE" "rootdir"         || die "Хранилище $CT_STORAGE не разрешает LXC rootdir"

    ok "Минимальная основа PVE готова"
}

find_local_debian13_template() {
    pveam list "$TEMPLATE_STORAGE" 2>/dev/null         | awk '$1 ~ /vztmpl\/debian-13-standard_/ {print $1}'         | sort -V         | tail -n1
}

latest_debian13_template_name() {
    pveam available --section system 2>/dev/null         | awk '$2 ~ /^debian-13-standard_.*_amd64\.tar\.(zst|gz)$/ {print $2}'         | sort -V         | tail -n1
}

ensure_debian13_template() {
    local local_ref template_name
    local_ref=$(find_local_debian13_template)

    if [[ -n "$local_ref" ]]; then
        printf '%s\n' "$local_ref"
        return
    fi

    [[ "$MODE" != "check" ]] || die "Debian 13 LXC template отсутствует в $TEMPLATE_STORAGE"

    log "Получение Debian 13 LXC template" >&2
    pveam update >/dev/null
    template_name=$(latest_debian13_template_name)
    [[ -n "$template_name" ]] || die "В каталоге PVE не найден Debian 13 standard LXC template"

    pveam download "$TEMPLATE_STORAGE" "$template_name" >&2
    local_ref=$(find_local_debian13_template)
    [[ -n "$local_ref" ]] || die "Debian 13 template скачан, но не найден локально"

    ok "Debian 13 LXC template готов: $local_ref" >&2
    printf '%s\n' "$local_ref"
}

# --- LXC 910 --------------------------------------------------------------

ct_exists() {
    pct config "$CTID" >/dev/null 2>&1
}

vm_exists() {
    qm config "$CTID" >/dev/null 2>&1
}

ct_config_value() {
    local key=$1
    pct config "$CTID" 2>/dev/null         | sed -n "s/^$key:[[:space:]]*//p"         | head -n1
}

has_tag() {
    local tags=$1 needle=$2
    tr ';' '\n' <<<"$tags" | grep -qx "$needle"
}

assert_owned_ct() {
    local hostname tags

    vm_exists && die "VMID $CTID занят виртуальной машиной. Автоматическая замена запрещена."
    ct_exists || return 1

    hostname=$(ct_config_value hostname)
    [[ "$hostname" == "$CT_HOSTNAME" ]]         || die "CTID $CTID занят LXC '$hostname', а ожидается '$CT_HOSTNAME'"

    tags=$(ct_config_value tags)
    has_tag "$tags" "infra-deployer" || die "LXC $CTID не имеет tag infra-deployer"
    has_tag "$tags" "proxmox-bootstrap" || die "LXC $CTID не имеет tag proxmox-bootstrap"
}

build_net0() {
    if [[ "$CT_IP" == "dhcp" ]]; then
        printf 'name=eth0,bridge=%s,ip=dhcp,type=veth\n' "$CT_BRIDGE"
    else
        printf 'name=eth0,bridge=%s,ip=%s,gw=%s,type=veth\n'             "$CT_BRIDGE" "$CT_IP" "$CT_GATEWAY"
    fi
}

create_infra_deployer() {
    local template_ref=$1 net0
    net0=$(build_net0)

    log "Создание LXC $CTID $CT_HOSTNAME"

    pct create "$CTID" "$template_ref"         --hostname "$CT_HOSTNAME"         --ostype debian         --unprivileged 1         --cores "$CT_CORES"         --memory "$CT_MEMORY_MB"         --swap "$CT_SWAP_MB"         --rootfs "$CT_STORAGE:$CT_DISK_GB"         --net0 "$net0"         --features "nesting=1,keyctl=1"         --onboot 1         --protection 1         --tags "infra-deployer;proxmox-bootstrap"         --description "managed-by=proxmox-bootstrap role=infra-deployer"

    assert_owned_ct || die "Созданный LXC $CTID не прошёл ownership-проверку"
    ok "LXC $CTID создан"
}

ensure_ct_running() {
    local status
    status=$(pct status "$CTID" | awk '{print $2}')

    if [[ "$status" == "running" ]]; then
        ok "LXC $CTID уже запущен"
        return
    fi

    [[ "$MODE" != "check" ]] || die "LXC $CTID не запущен"
    pct start "$CTID"
    ok "LXC $CTID запущен"
}

ct_exec() {
    pct exec "$CTID" -- "$@"
}

wait_ct_network() {
    log "Ожидание сети внутри LXC $CTID"

    for _ in $(seq 1 60); do
        if ct_exec sh -c 'ip -4 route show default | grep -q "^default " && getent ahostsv4 github.com >/dev/null 2>&1'; then
            ok "Сеть и DNS внутри LXC $CTID работают"
            return
        fi
        sleep 2
    done

    die "LXC $CTID запущен, но сеть или DNS не готовы"
}

init_ct_log() {
    ct_exec install -d -o root -g root -m 0755 "$(dirname "$CT_LOG_FILE")"
    ct_exec touch "$CT_LOG_FILE"
    ct_exec chmod 0640 "$CT_LOG_FILE"
    ct_exec sh -c "printf '\n===== public bootstrap %s =====\n' \"\$(date '+%Y-%m-%d %H:%M:%S')\" >> '$CT_LOG_FILE'"
}

ct_run_logged() {
    local rc=0

    ct_exec sh -c '
        log=$1
        shift
        "$@" >>"$log" 2>&1
    ' sh "$CT_LOG_FILE" "$@" || rc=$?

    if ((rc != 0)); then
        printf '%s%sОШИБКА:%s команда внутри 910 завершилась с кодом %s\n' \
            "$C_BOLD" "$C_RED" "$C_RESET" "$rc" >&2
        printf 'Последние строки технического лога:\n' >&2
        ct_exec tail -n 25 "$CT_LOG_FILE" >&2 || true
        printf 'Полный лог внутри 910: %s\n' "$CT_LOG_FILE" >&2
        return "$rc"
    fi
}

# --- GitHub и закрытый проект ---------------------------------------------

ensure_host_github_key() {
    install -d -o root -g root -m 0700 "$HOST_BOOTSTRAP_DIR"

    if [[ -s "$HOST_GITHUB_KEY" ]]; then
        ssh-keygen -y -f "$HOST_GITHUB_KEY" >/dev/null 2>&1 \
            || die "Повреждён постоянный GitHub Deploy Key: $HOST_GITHUB_KEY"

        if [[ ! -s "$HOST_GITHUB_PUB" ]]; then
            ssh-keygen -y -f "$HOST_GITHUB_KEY" >"$HOST_GITHUB_PUB"
        fi

        chmod 0600 "$HOST_GITHUB_KEY"
        chmod 0644 "$HOST_GITHUB_PUB"
        ok "Постоянный GitHub Deploy Key на PVE готов"
        return
    fi

    rm -f "$HOST_GITHUB_KEY" "$HOST_GITHUB_PUB"
    ssh-keygen -q -t ed25519 -N '' \
        -C infra-deployer-readonly-zsergeyru-proxmox \
        -f "$HOST_GITHUB_KEY"
    chmod 0600 "$HOST_GITHUB_KEY"
    chmod 0644 "$HOST_GITHUB_PUB"

    ok "GitHub Deploy Key создан и сохранён на PVE"
}

prepare_infra_deployer_os() {
    log "Минимальная подготовка Debian внутри LXC $CTID"

    init_ct_log

    ct_exec sh -c "printf 'LANG=C.UTF-8\n' >/etc/default/locale"

    ct_run_logged apt-get update
    ct_run_logged env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends \
        ca-certificates curl git jq openssh-client

    ok "Минимальная Debian-основа внутри LXC готова"
}

push_github_key_to_ct() {
    ct_exec install -d -m 0700 /root/.ssh

    pct push "$CTID" "$HOST_GITHUB_KEY" "$CT_GITHUB_KEY" \
        --user 0 --group 0 --perms 0600
    pct push "$CTID" "$HOST_GITHUB_PUB" "$CT_GITHUB_PUB" \
        --user 0 --group 0 --perms 0644

    ct_exec sh -c \
        "curl -fsSL --connect-timeout 10 --max-time 20 https://api.github.com/meta | jq -r '.ssh_keys[] | \"github.com \" + .' > '$CT_GITHUB_KNOWN_HOSTS'"

    ct_exec sh -c "cat > '$CT_GITHUB_SSH_CONFIG' <<EOF_SSH
Host github.com
    HostName github.com
    User git
    IdentityFile $CT_GITHUB_KEY
    IdentitiesOnly yes
    UserKnownHostsFile $CT_GITHUB_KNOWN_HOSTS
    StrictHostKeyChecking yes
    BatchMode yes
    ConnectTimeout 10
EOF_SSH
chmod 0600 '$CT_GITHUB_KEY' '$CT_GITHUB_SSH_CONFIG'
chmod 0644 '$CT_GITHUB_PUB' '$CT_GITHUB_KNOWN_HOSTS'"

    ok "Постоянный GitHub Deploy Key передан в 910"
}

private_branch_accessible() {
    ct_exec env GIT_SSH_COMMAND="ssh -F $CT_GITHUB_SSH_CONFIG" \
        git ls-remote "$PRIVATE_REPO" "refs/heads/$PROJECT_BRANCH" 2>/dev/null \
        | grep -q .
}

ensure_private_repo_access() {
    if private_branch_accessible; then
        ok "910 имеет read-only доступ к закрытому проекту"
        return
    fi

    printf '\n%sДобавьте этот ключ в GitHub как read-only Deploy Key репозитория zsergeyru/proxmox:%s\n\n' \
        "$C_BOLD" "$C_RESET"
    cat "$HOST_GITHUB_PUB"
    printf '\nGitHub -> zsergeyru/proxmox -> Settings -> Deploy keys -> Add deploy key\n'
    printf 'Allow write access: ВЫКЛЮЧЕН\n\n'

    [[ -r /dev/tty ]] \
        || die "GitHub Deploy Key ещё не зарегистрирован. Добавьте показанный ключ и повторите bootstrap."

    printf 'Нажмите Enter после добавления Deploy Key в GitHub...' >/dev/tty
    IFS= read -r _ </dev/tty || die "Не удалось прочитать подтверждение"
    printf '\n' >/dev/tty

    private_branch_accessible \
        || die "Доступ к $PRIVATE_REPO/$PROJECT_BRANCH по-прежнему отсутствует"

    ok "Read-only доступ к закрытому проекту подтверждён"
}

checkout_private_project() {
    local origin

    log "Получение закрытого проекта внутри 910"

    if ct_exec test -d "$CT_PROJECT_DIR/.git"; then
        origin=$(ct_exec git -C "$CT_PROJECT_DIR" remote get-url origin)
        [[ "$origin" == "$PRIVATE_REPO" ]] \
            || die "Закрытый проект внутри 910 имеет неожиданный origin: $origin"

        ct_run_logged env GIT_SSH_COMMAND="ssh -F $CT_GITHUB_SSH_CONFIG" \
            git -C "$CT_PROJECT_DIR" fetch --depth 1 origin "$PROJECT_BRANCH"
        ct_run_logged git -C "$CT_PROJECT_DIR" reset --hard FETCH_HEAD
        ct_run_logged git -C "$CT_PROJECT_DIR" clean -ffdx
    else
        ct_exec rm -rf "$CT_PROJECT_DIR"
        ct_exec install -d -m 0755 "$(dirname "$CT_PROJECT_DIR")"
        ct_run_logged env GIT_SSH_COMMAND="ssh -F $CT_GITHUB_SSH_CONFIG" \
            git clone --depth 1 --branch "$PROJECT_BRANCH" \
            "$PRIVATE_REPO" "$CT_PROJECT_DIR"
    fi

    ok "Закрытый проект получен внутри 910"
}

# --- Передача управления закрытому проекту --------------------------------

configure_pve_access() {
    local source="$CT_PROJECT_DIR/$PRIVATE_HOST_ACCESS_PATH"

    ct_exec test -s "$source" \
        || die "В закрытом проекте отсутствует $PRIVATE_HOST_ACCESS_PATH"

    log "Одноразовая выдача 910 ограниченного доступа к PVE"

    ct_exec cat "$source" \
        | INFRA_DEPLOYER_CTID="$CTID" \
          INFRA_DEPLOYER_MODE="$MODE" \
          INFRA_DEPLOYER_SECRET_FILE="$CT_SECRET_FILE" \
          INFRA_DEPLOYER_COLOR="$BOOTSTRAP_COLOR" \
          bash

    ok "Ограниченный доступ 910 к PVE подготовлен"
}

configure_infra_deployer() {
    local setup="$CT_PROJECT_DIR/$PRIVATE_SETUP_PATH"
    local recover_flag=0

    ct_exec test -s "$setup" \
        || die "В закрытом проекте отсутствует $PRIVATE_SETUP_PATH"

    [[ "$MODE" == "recover" ]] && recover_flag=1

    log "Основная настройка infra-deployer внутри 910"

    ct_exec env \
        INFRA_DEPLOYER_BOOTSTRAP=1 \
        INFRA_DEPLOYER_RECOVER="$recover_flag" \
        INFRA_DEPLOYER_COLOR="$BOOTSTRAP_COLOR" \
        INFRA_DEPLOYER_LOG_FILE="$CT_LOG_FILE" \
        INFRA_PROJECT_BRANCH="$PROJECT_BRANCH" \
        PVE_API_SECRET_FILE="$CT_SECRET_FILE" \
        bash "$setup"

    ct_exec rm -f "$CT_SECRET_FILE"
    ok "Внутренняя настройка 910 завершена"
}

verify_infra_deployer() {
    local status

    assert_owned_ct || die "LXC $CTID отсутствует"
    status=$(pct status "$CTID" | awk '{print $2}')
    [[ "$status" == "running" ]] || die "LXC $CTID не запущен"

    ct_exec test -x /usr/local/sbin/infra-deployer-status \
        || die "В 910 отсутствует infra-deployer-status"

    ct_exec env INFRA_DEPLOYER_COLOR="$BOOTSTRAP_COLOR" \
        /usr/local/sbin/infra-deployer-status

    ok "910 infra-deployer готов"
}

ensure_infra_deployer_ct() {
    local template_ref=""

    if assert_owned_ct; then
        info "Найден принадлежащий bootstrap LXC $CTID"
        return
    fi

    [[ "$MODE" != "check" ]] || die "LXC $CTID отсутствует"

    template_ref=$(ensure_debian13_template)
    create_infra_deployer "$template_ref"
}

report_success() {
    printf '\n%s%sPUBLIC BOOTSTRAP УСПЕШНО ЗАВЕРШЁН%s\n' \
        "$C_BOLD" "$C_GREEN" "$C_RESET"
    printf 'GitHub Deploy Key хранится на PVE: %s\n' "$HOST_GITHUB_KEY"
}

main() {
    parse_args "$@"

    require_root_and_pve
    info "Public Bootstrap v$PUBLIC_BOOTSTRAP_VERSION, режим: $MODE"

    acquire_lock
    host_preflight
    ensure_infra_deployer_ct
    ensure_ct_running
    wait_ct_network

    if [[ "$MODE" == "check" ]]; then
        verify_infra_deployer
        return
    fi

    ensure_host_github_key
    prepare_infra_deployer_os
    push_github_key_to_ct
    ensure_private_repo_access
    checkout_private_project
    configure_pve_access
    configure_infra_deployer
    verify_infra_deployer

    report_success
}

main "$@"
