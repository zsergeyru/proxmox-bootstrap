#!/usr/bin/env bash
set -Eeuo pipefail

# Минимальный публичный bootstrap для Proxmox VE.
# На PVE он только создаёт/запускает LXC 910, запускает гостевой bootstrap
# внутри 910 и один раз выполняет подготовленный закрытым проектом PVE helper.

PUBLIC_BOOTSTRAP_VERSION="3.1.0-dev1"

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

GUEST_BOOTSTRAP_REF="612ea53ef3a787a554b81530a0bfd1f30faea691"
GUEST_BOOTSTRAP_URL="https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/${GUEST_BOOTSTRAP_REF}/bootstrap-910.sh"
CT_BOOTSTRAP_DIR="/root/.infra-deployer-bootstrap"
CT_GUEST_BOOTSTRAP="${CT_BOOTSTRAP_DIR}/bootstrap-910.sh"
CT_HOST_HELPER="${CT_BOOTSTRAP_DIR}/pve-host-helper.sh"

LOCK_FILE="/run/lock/proxmox-bootstrap.lock"
HOST_TMP_FILE=""

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

require_root_and_pve() {
    local cmd
    [[ $EUID -eq 0 ]] || die "Запустите скрипт от root на PVE"

    for cmd in pveversion pvesh pct qm pveam pvesm curl bash; do
        command -v "$cmd" >/dev/null 2>&1 || die "Не найдена обязательная штатная команда: $cmd"
    done

    pveversion >/dev/null || die "Не удалось получить версию Proxmox VE"
    ok "Proxmox VE обнаружен"
}

cleanup_host_runtime() {
    [[ -z "$HOST_TMP_FILE" ]] || rm -f -- "$HOST_TMP_FILE"
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

install_guest_bootstrap() {
    [[ "$MODE" != "check" ]] || return 0

    log "Передача стартового сценария внутрь LXC $CTID"

    HOST_TMP_FILE=$(mktemp /run/proxmox-bootstrap-910.XXXXXX)
    curl -fsSL --connect-timeout 10 --max-time 30         "$GUEST_BOOTSTRAP_URL" -o "$HOST_TMP_FILE"

    ct_exec install -d -m 0700 "$CT_BOOTSTRAP_DIR"
    pct push "$CTID" "$HOST_TMP_FILE" "$CT_GUEST_BOOTSTRAP"         --user 0 --group 0 --perms 0700

    rm -f -- "$HOST_TMP_FILE"
    HOST_TMP_FILE=""

    ok "Стартовый сценарий передан в 910"
}

run_guest_prepare_once() {
    ct_exec env INFRA_DEPLOYER_COLOR="$BOOTSTRAP_COLOR" \
        "$CT_GUEST_BOOTSTRAP" prepare --project-branch "$PROJECT_BRANCH"
}

run_guest_prepare() {
    local rc

    set +e
    run_guest_prepare_once
    rc=$?
    set -e

    if ((rc == 0)); then
        return
    fi

    ((rc == 42)) || return "$rc"

    [[ -r /dev/tty ]]         || die "GitHub Deploy Key ещё не зарегистрирован. Добавьте показанный ключ и повторите bootstrap."

    printf 'Нажмите Enter после добавления Deploy Key в GitHub...' >/dev/tty
    IFS= read -r _ </dev/tty || die "Не удалось прочитать подтверждение"
    printf '\n' >/dev/tty

    run_guest_prepare_once
}

run_host_access() {
    ct_exec test -s "$CT_HOST_HELPER"         || die "910 не подготовил одноразовый PVE helper"

    log "Одноразовая выдача 910 ограниченного доступа к PVE"

    ct_exec cat "$CT_HOST_HELPER" \
        | INFRA_DEPLOYER_CTID="$CTID" \
          INFRA_DEPLOYER_MODE="$MODE" \
          INFRA_DEPLOYER_COLOR="$BOOTSTRAP_COLOR" \
          bash

    ok "Ограниченный доступ 910 к PVE подготовлен"
}

run_guest_finish() {
    local args=(finish --project-branch "$PROJECT_BRANCH")

    [[ "$MODE" == "recover" ]] && args+=(--recover)

    ct_exec env INFRA_DEPLOYER_COLOR="$BOOTSTRAP_COLOR" \
        "$CT_GUEST_BOOTSTRAP" "${args[@]}"
}

run_guest_check() {
    ct_exec test -x "$CT_GUEST_BOOTSTRAP"         || die "В 910 отсутствует гостевой bootstrap"
    ct_exec env INFRA_DEPLOYER_COLOR="$BOOTSTRAP_COLOR" \
        "$CT_GUEST_BOOTSTRAP" check
}

main() {
    local template_ref=""

    parse_args "$@"
    require_root_and_pve
    info "Public Bootstrap v$PUBLIC_BOOTSTRAP_VERSION, режим: $MODE"
    acquire_lock
    host_preflight

    if assert_owned_ct; then
        info "Найден принадлежащий bootstrap LXC $CTID"
    else
        [[ "$MODE" != "check" ]] || die "LXC $CTID отсутствует"
        template_ref=$(ensure_debian13_template)
        create_infra_deployer "$template_ref"
    fi

    ensure_ct_running
    wait_ct_network

    if [[ "$MODE" == "check" ]]; then
        run_guest_check
        exit 0
    fi

    install_guest_bootstrap
    run_guest_prepare
    run_host_access
    run_guest_finish
    run_guest_check

    printf '\n%s%sPUBLIC BOOTSTRAP УСПЕШНО ЗАВЕРШЁН%s\n'         "$C_BOLD" "$C_GREEN" "$C_RESET"
    printf 'Единственная ручная операция — добавление GitHub Deploy Key при первом запуске.\n'
}

main "$@"
