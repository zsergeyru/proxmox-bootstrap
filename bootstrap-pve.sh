#!/usr/bin/env bash
set -Eeuo pipefail

# Public Bootstrap для Proxmox VE.
# Его область: минимальная проверка PVE и специальный LXC 910 infra-deployer.
# Остальная инфраструктура управляется уже из 910.

PUBLIC_BOOTSTRAP_VERSION="2.0.0-dev1"

CTID=910
CT_HOSTNAME="infra-deployer"
CT_CORES=2
CT_MEMORY_MB=2048
CT_SWAP_MB=512
CT_DISK_GB=32
CT_STORAGE="local-lvm"
CT_BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"

API_USER="infra-deployer@pve"
API_TOKEN_NAME="automation"
API_TOKEN_ID="infra-deployer@pve!automation"

MANAGED_POOL="managed"
TEMPLATE_VMID=9000

ROLE_MANAGED_GUEST="InfraManagedGuest"
ROLE_MANAGED_GUEST_PRIVS="Pool.Audit VM.Allocate VM.Audit VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.GuestAgent.Audit VM.PowerMgmt"
ROLE_AUDITOR="PVEAuditor"
ROLE_TEMPLATE="PVETemplateUser"
ROLE_STORAGE="PVEDatastoreUser"
ROLE_NETWORK="PVESDNUser"

FORBIDDEN_VM_PRIVS="VM.Allocate VM.Backup VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Console VM.GuestAgent.FileRead VM.GuestAgent.FileWrite VM.GuestAgent.FileSystemMgmt VM.GuestAgent.Unrestricted VM.Migrate VM.PowerMgmt VM.Replicate VM.Snapshot VM.Snapshot.Rollback"
FORBIDDEN_ROOT_PRIVS="Permissions.Modify Sys.Modify Sys.PowerMgmt User.Modify Group.Allocate Realm.Allocate Realm.AllocateUser Pool.Allocate Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate SDN.Allocate SDN.Use Mapping.Modify"

PRIVATE_REPO="git@github.com:zsergeyru/proxmox.git"
PRIVATE_BRANCH="infra-iac-redesign"
PRIVATE_SETUP_PATH="scripts/infra-deployer/setup.sh"

LOCK_FILE="/run/lock/proxmox-bootstrap.lock"
BACKUP_ROOT="/var/backups/proxmox-bootstrap"
HOST_TMP_DIR="/run/proxmox-bootstrap"

CT_BOOTSTRAP_DIR="/root/.infra-deployer-bootstrap"
CT_SECRET_FILE="/root/.infra-deployer-bootstrap/pve-api.env"
CT_GITHUB_KEY="/root/.ssh/github_proxmox_repo_ed25519"
CT_GITHUB_PUB="/root/.ssh/github_proxmox_repo_ed25519.pub"
CT_GITHUB_KNOWN_HOSTS="/root/.ssh/github_known_hosts"
CT_GITHUB_SSH_CONFIG="/root/.ssh/github_config"
CT_PROJECT_DIR="/var/lib/infra-deployer/bootstrap-repo"
CT_COMPLETE_MARKER="/var/lib/infra-deployer/bootstrap-complete"

MODE="apply"
CT_IP="dhcp"
CT_GATEWAY=""
HOST_BACKUP_DONE=0

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
  без параметра режима     создать или проверить 910 infra-deployer
  --check                  только проверить, ничего не менять
  --recover                явное восстановление/ротация bootstrap credentials

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
                PRIVATE_BRANCH=$1
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

    [[ "$PRIVATE_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] \
        || die "Некорректное имя ветки проекта: $PRIVATE_BRANCH"
}

require_root_and_pve() {
    local cmd
    [[ $EUID -eq 0 ]] || die "Запустите скрипт от root на PVE"

    for cmd in pveversion pvesh pct qm pveam pvesm pveum; do
        command -v "$cmd" >/dev/null 2>&1 || die "Не найдена обязательная команда PVE: $cmd"
    done

    pveversion >/dev/null || die "Не удалось получить версию Proxmox VE"
    ok "Proxmox VE обнаружен"
}

acquire_lock() {
    command -v flock >/dev/null 2>&1 || die "Не найдена команда flock"
    install -d -m 0755 /run/lock
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Другой bootstrap уже выполняется"
    ok "Получена блокировка bootstrap"
}

ensure_host_packages() {
    local missing="" pkg
    for pkg in ca-certificates curl jq util-linux; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
    done

    if [[ -z "$missing" ]]; then
        ok "Минимальные пакеты PVE уже установлены"
        return
    fi

    [[ "$MODE" != "check" ]] || die "Для проверки не хватает пакетов:$missing"

    backup_host_config
    log "Установка минимальных пакетов PVE"
    apt-get update
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $missing
    ok "Минимальные пакеты PVE установлены"
}

storage_exists() {
    pvesm status --storage "$1" >/dev/null 2>&1
}

storage_has_content() {
    local storage=$1 content=$2
    pvesh get "/storage/$storage" --output-format json 2>/dev/null \
        | jq -r '.content // ""' \
        | tr ',' '\n' \
        | grep -qx "$content"
}

host_preflight() {
    local node
    log "Проверка PVE-хоста"

    [[ -e /dev/kvm ]] || die "Не найден /dev/kvm"
    ip link show "$CT_BRIDGE" >/dev/null 2>&1 || die "Не найден сетевой мост $CT_BRIDGE"
    storage_exists "$TEMPLATE_STORAGE" || die "Не найдено хранилище $TEMPLATE_STORAGE"
    storage_exists "$CT_STORAGE" || die "Не найдено хранилище $CT_STORAGE"
    storage_has_content "$TEMPLATE_STORAGE" "vztmpl" \
        || die "Хранилище $TEMPLATE_STORAGE не разрешает LXC templates"
    storage_has_content "$CT_STORAGE" "rootdir" \
        || die "Хранилище $CT_STORAGE не разрешает LXC rootdir"

    node=$(hostname -s)
    [[ -n "$node" ]] || die "Не удалось определить имя PVE-узла"
    getent ahostsv4 "$node" >/dev/null 2>&1 \
        || die "Имя PVE-узла '$node' не разрешается в IPv4"

    if [[ "$MODE" != "check" ]]; then
        curl -fsSI --connect-timeout 10 --max-time 20 -o /dev/null https://github.com/ \
            || die "GitHub недоступен по HTTPS с PVE"
        curl -fsS --connect-timeout 10 --max-time 20 -o /dev/null https://api.github.com/meta \
            || die "GitHub API недоступен по HTTPS с PVE"
    fi

    ok "Сеть и базовые хранилища PVE готовы"
}

backup_host_config() {
    local ts dir path

    if ((HOST_BACKUP_DONE == 1)); then
        return
    fi

    ts=$(date +%Y%m%d-%H%M%S)
    dir="$BACKUP_ROOT/$ts"
    install -d -o root -g root -m 0700 "$dir"

    for path in \
        /etc/network/interfaces \
        /etc/hosts \
        /etc/hostname \
        /etc/pve/storage.cfg \
        /etc/pve/user.cfg \
        /etc/pve/datacenter.cfg \
        /etc/apt/sources.list \
        /etc/apt/sources.list.d
    do
        [[ -e "$path" ]] || continue
        cp -a --parents "$path" "$dir/"
    done

    HOST_BACKUP_DONE=1
    ok "Сохранена резервная копия конфигурации PVE: $dir"
}

find_local_debian13_template() {
    pveam list "$TEMPLATE_STORAGE" 2>/dev/null \
        | awk '$1 ~ /vztmpl\/debian-13-standard_/ {print $1}' \
        | sort -V \
        | tail -n1
}

latest_debian13_template_name() {
    pveam available --section system 2>/dev/null \
        | awk '$2 ~ /^debian-13-standard_.*_amd64\.tar\.(zst|gz)$/ {print $2}' \
        | sort -V \
        | tail -n1
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

    pveam download "$TEMPLATE_STORAGE" "$template_name"
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
    pct config "$CTID" 2>/dev/null \
        | sed -n "s/^$key:[[:space:]]*//p" \
        | head -n1
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
    [[ "$hostname" == "$CT_HOSTNAME" ]] \
        || die "CTID $CTID занят LXC '$hostname', а ожидается '$CT_HOSTNAME'"

    tags=$(ct_config_value tags)
    has_tag "$tags" "infra-deployer" || die "LXC $CTID не имеет tag infra-deployer"
    has_tag "$tags" "proxmox-bootstrap" || die "LXC $CTID не имеет tag proxmox-bootstrap"
}

warn_ct_drift() {
    local actual

    actual=$(ct_config_value cores)
    [[ "$actual" == "$CT_CORES" ]] || warn "LXC $CTID: cores=$actual, ожидается $CT_CORES"

    actual=$(ct_config_value memory)
    [[ "$actual" == "$CT_MEMORY_MB" ]] || warn "LXC $CTID: memory=$actual, ожидается $CT_MEMORY_MB"

    actual=$(ct_config_value swap)
    [[ "$actual" == "$CT_SWAP_MB" ]] || warn "LXC $CTID: swap=$actual, ожидается $CT_SWAP_MB"

    actual=$(ct_config_value unprivileged)
    [[ "$actual" == "1" ]] || die "LXC $CTID должен быть unprivileged=1"

    actual=$(ct_config_value protection)
    [[ "$actual" == "1" ]] || die "LXC $CTID: protection должен быть включён"

    actual=$(ct_config_value onboot)
    [[ "$actual" == "1" ]] || warn "LXC $CTID: onboot не включён"

    actual=$(ct_config_value features)
    [[ "$actual" == *"nesting=1"* && "$actual" == *"keyctl=1"* ]] \
        || warn "LXC $CTID: ожидаются features nesting=1,keyctl=1"

    actual=$(ct_config_value rootfs)
    [[ "$actual" == "$CT_STORAGE:"* ]] \
        || warn "LXC $CTID: rootfs находится не в ожидаемом storage $CT_STORAGE"

    actual=$(ct_config_value net0)
    [[ "$actual" == *"bridge=$CT_BRIDGE"* ]] \
        || warn "LXC $CTID: net0 использует не ожидаемый bridge $CT_BRIDGE"
}

build_net0() {
    if [[ "$CT_IP" == "dhcp" ]]; then
        printf 'name=eth0,bridge=%s,ip=dhcp,type=veth\n' "$CT_BRIDGE"
    else
        printf 'name=eth0,bridge=%s,ip=%s,gw=%s,type=veth\n' \
            "$CT_BRIDGE" "$CT_IP" "$CT_GATEWAY"
    fi
}

create_infra_deployer() {
    local template_ref=$1 net0
    net0=$(build_net0)

    log "Создание LXC $CTID $CT_HOSTNAME"

    pct create "$CTID" "$template_ref" \
        --hostname "$CT_HOSTNAME" \
        --ostype debian \
        --unprivileged 1 \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY_MB" \
        --swap "$CT_SWAP_MB" \
        --rootfs "$CT_STORAGE:$CT_DISK_GB" \
        --net0 "$net0" \
        --features "nesting=1,keyctl=1" \
        --onboot 1 \
        --protection 1 \
        --tags "infra-deployer;proxmox-bootstrap" \
        --description "managed-by=proxmox-bootstrap role=infra-deployer"

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

bootstrap_ct_os() {
    [[ "$MODE" != "check" ]] || return 0

    log "Минимальная подготовка Debian внутри LXC $CTID"
    ct_exec env DEBIAN_FRONTEND=noninteractive apt-get update
    ct_exec env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends \
        ca-certificates curl git jq openssh-client

    ok "Минимальная Debian-основа внутри LXC готова"
}

ensure_pve_name_resolution_in_ct() {
    local node host_ip resolved_ip

    node=$(hostname -s)
    [[ "$node" =~ ^[A-Za-z0-9-]+$ ]]         || die "Некорректное имя PVE-узла: $node"

    host_ip=$(getent ahostsv4 "$node" | awk 'NR == 1 {print $1}')
    validate_ipv4 "$host_ip"         || die "Не удалось определить IPv4 PVE-узла '$node'"

    resolved_ip="$(ct_exec getent ahostsv4 "$node" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
    if [[ "$resolved_ip" == "$host_ip" ]]; then
        ok "Имя PVE '$node' уже разрешается внутри LXC $CTID"
        return
    fi

    ct_exec sh -c "grep -vE '[[:space:]]$node([[:space:]]|$)' /etc/hosts > /etc/hosts.bootstrap || true; printf '%s %s\n' '$host_ip' '$node' >> /etc/hosts.bootstrap; cat /etc/hosts.bootstrap > /etc/hosts; rm -f /etc/hosts.bootstrap"

    resolved_ip="$(ct_exec getent ahostsv4 "$node" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
    [[ "$resolved_ip" == "$host_ip" ]]         || die "Не удалось настроить разрешение имени '$node' внутри LXC $CTID"

    ok "Добавлено разрешение $node -> $host_ip внутри LXC $CTID"
}

install_pve_ca() {
    local src=/etc/pve/pve-root-ca.pem tmp node
    [[ "$MODE" != "check" ]] || return 0
    [[ -s "$src" ]] || die "Не найден PVE CA: $src"

    install -d -o root -g root -m 0700 "$HOST_TMP_DIR"
    tmp="$HOST_TMP_DIR/pve-root-ca.crt"
    install -o root -g root -m 0644 "$src" "$tmp"

    ct_exec install -d -m 0755 /usr/local/share/ca-certificates
    pct push "$CTID" "$tmp" /usr/local/share/ca-certificates/pve-root-ca.crt \
        --user 0 --group 0 --perms 0644
    ct_exec update-ca-certificates >/dev/null
    rm -f "$tmp"

    ensure_pve_name_resolution_in_ct
    node=$(hostname -s)
    ct_exec curl -sS --connect-timeout 5 --max-time 15 \
        -o /dev/null \
        "https://$node:8006/api2/json/version" \
        || die "LXC $CTID не может проверить TLS PVE API по имени '$node'"

    ok "PVE CA установлен и TLS PVE API проверен"
}

api_user_exists() {
    pveum user list --output-format json \
        | jq -e --arg id "$API_USER" '.[] | select(.userid == $id)' >/dev/null
}

api_token_exists() {
    pveum user token list "$API_USER" --output-format json 2>/dev/null \
        | jq -e --arg id "$API_TOKEN_NAME" '.[] | select(.tokenid == $id)' >/dev/null
}

api_token_privsep() {
    pveum user token list "$API_USER" --output-format json 2>/dev/null \
        | jq -r --arg id "$API_TOKEN_NAME" '.[] | select(.tokenid == $id) | .privsep'
}

assert_api_token_privsep() {
    local privsep
    privsep=$(api_token_privsep)
    [[ "$privsep" == "1" ]] \
        || die "PVE API token $API_TOKEN_ID должен иметь privsep=1"
}

ensure_api_user() {
    local users_json enabled groups

    users_json="$(pveum user list --full 1 --output-format json)"

    if jq -e --arg id "$API_USER" '.[] | select(.userid == $id)' <<<"$users_json" >/dev/null; then
        enabled="$(jq -r --arg id "$API_USER" '.[] | select(.userid == $id) | (.enable // 1)' <<<"$users_json" | head -n1)"
        [[ "$enabled" != "0" ]] || die "PVE user $API_USER существует, но отключён"

        groups="$(jq -r --arg id "$API_USER" '.[] | select(.userid == $id) | (.groups // "")' <<<"$users_json" | head -n1)"
        [[ -z "$groups" || "$groups" == "null" ]]             || die "PVE user $API_USER не должен состоять в группах; обнаружено: $groups"
        return
    fi

    [[ "$MODE" != "check" ]] || die "PVE user $API_USER отсутствует"
    pveum user add "$API_USER" --comment "910 infra-deployer" --enable 1
    ok "Создан PVE user $API_USER"
}

priv_lines() {
    printf '%s\n' "$1" | tr ', ' '\n\n' | sed '/^$/d' | LC_ALL=C sort -u
}

managed_pool_exists() {
    pveum pool list --output-format json 2>/dev/null \
        | jq -e --arg id "$MANAGED_POOL" '.[] | select(.poolid == $id)' >/dev/null
}

assert_910_outside_managed_pool() {
    local pool_json

    pool_json="$(pvesh get "/pools/$MANAGED_POOL" --output-format json)" \
        || die "Не удалось прочитать pool $MANAGED_POOL"

    if jq -e --arg vmid "$CTID" \
        '.members[]? | select(((.vmid // "") | tostring) == $vmid)' \
        <<<"$pool_json" >/dev/null; then
        die "LXC $CTID infra-deployer не должен входить в pool $MANAGED_POOL"
    fi
}

ensure_managed_pool() {
    if managed_pool_exists; then
        assert_910_outside_managed_pool
        ok "Pool $MANAGED_POOL существует, 910 в него не входит"
        return
    fi

    [[ "$MODE" != "check" ]] || die "Pool $MANAGED_POOL отсутствует"

    pveum pool add "$MANAGED_POOL" \
        --comment "Обычные гости под управлением infra-deployer"
    ok "Создан pool $MANAGED_POOL"
}

role_exists() {
    local role=$1
    pveum role list --output-format json \
        | jq -e --arg role "$role" '.[] | select(.roleid == $role)' >/dev/null
}

role_privs() {
    local role=$1
    pveum role list --output-format json \
        | jq -r --arg role "$role" \
            '.[] | select(.roleid == $role) | (.privs // "")' \
        | head -n1
}

ensure_managed_guest_role() {
    local actual expected

    expected="$(priv_lines "$ROLE_MANAGED_GUEST_PRIVS")"

    if ! role_exists "$ROLE_MANAGED_GUEST"; then
        [[ "$MODE" != "check" ]] || die "Роль $ROLE_MANAGED_GUEST отсутствует"

        pveum role add "$ROLE_MANAGED_GUEST" \
            --privs "$ROLE_MANAGED_GUEST_PRIVS"
        ok "Создана роль $ROLE_MANAGED_GUEST"
        return
    fi

    actual="$(priv_lines "$(role_privs "$ROLE_MANAGED_GUEST")")"

    if [[ "$actual" == "$expected" ]]; then
        ok "Роль $ROLE_MANAGED_GUEST соответствует контракту"
        return
    fi

    [[ "$MODE" != "check" ]] \
        || die "Роль $ROLE_MANAGED_GUEST не соответствует минимальному контракту"

    # Роль принадлежит только bootstrap и имеет точный набор прав.
    pveum role modify "$ROLE_MANAGED_GUEST" \
        --privs "$ROLE_MANAGED_GUEST_PRIVS"

    actual="$(priv_lines "$(role_privs "$ROLE_MANAGED_GUEST")")"
    [[ "$actual" == "$expected" ]] \
        || die "Не удалось привести роль $ROLE_MANAGED_GUEST к контракту"

    ok "Роль $ROLE_MANAGED_GUEST приведена к точному набору privileges"
}

acl_entry_exists() {
    local path=$1 type=$2 principal=$3 role=$4

    pveum acl list --output-format json \
        | jq -e \
            --arg path "$path" \
            --arg type "$type" \
            --arg principal "$principal" \
            --arg role "$role" \
            '.[] | select(
                .path == $path
                and .type == $type
                and .ugid == $principal
                and .roleid == $role
                and ((.propagate // 1) == 1)
            )' >/dev/null
}

ensure_acl_entry() {
    local path=$1 type=$2 principal=$3 role=$4 option

    if acl_entry_exists "$path" "$type" "$principal" "$role"; then
        return
    fi

    [[ "$MODE" != "check" ]] \
        || die "Отсутствует ACL: $path, $type=$principal, role=$role"

    case "$type" in
        user) option="--users" ;;
        token) option="--tokens" ;;
        *) die "Неизвестный тип ACL principal: $type" ;;
    esac

    pveum acl modify "$path" \
        "$option" "$principal" \
        --roles "$role" \
        --propagate 1

    acl_entry_exists "$path" "$type" "$principal" "$role" \
        || die "Не удалось создать ACL: $path, $type=$principal, role=$role"
}

ensure_principal_acls() {
    local type=$1 principal=$2

    ensure_acl_entry "/" \
        "$type" "$principal" "$ROLE_AUDITOR"
    ensure_acl_entry "/pool/$MANAGED_POOL" \
        "$type" "$principal" "$ROLE_MANAGED_GUEST"
    ensure_acl_entry "/vms/$TEMPLATE_VMID" \
        "$type" "$principal" "$ROLE_TEMPLATE"
    ensure_acl_entry "/storage/$CT_STORAGE" \
        "$type" "$principal" "$ROLE_STORAGE"
    ensure_acl_entry "/sdn/zones/localnetwork/$CT_BRIDGE" \
        "$type" "$principal" "$ROLE_NETWORK"
}

verify_acl_boundaries() {
    local acl_json type principal rows path role propagate

    acl_json="$(pveum acl list --output-format json)" \
        || die "Не удалось получить ACL Proxmox"

    for type in user token; do
        if [[ "$type" == "user" ]]; then
            principal="$API_USER"
        else
            principal="$API_TOKEN_ID"
        fi

        rows="$(jq -r \
            --arg type "$type" \
            --arg principal "$principal" \
            '.[] |
             select(.type == $type and .ugid == $principal) |
             "\(.path)|\(.roleid)|\(.propagate // 1)"' \
            <<<"$acl_json")"

        while IFS='|' read -r path role propagate; do
            [[ -n "$path" ]] || continue
            [[ "$propagate" == "1" ]] \
                || die "ACL $type=$principal на $path имеет propagate=$propagate"

            case "$path|$role" in
                "/|$ROLE_AUDITOR"|\
                "/pool/$MANAGED_POOL|$ROLE_MANAGED_GUEST"|\
                "/vms/$TEMPLATE_VMID|$ROLE_TEMPLATE"|\
                "/storage/$CT_STORAGE|$ROLE_STORAGE"|\
                "/sdn/zones/localnetwork/$CT_BRIDGE|$ROLE_NETWORK")
                    ;;
                *)
                    die "Обнаружена лишняя ACL у $type=$principal: path=$path role=$role"
                    ;;
            esac
        done <<<"$rows"
    done
}

token_permissions_at() {
    local path=$1

    pveum user token permissions \
        "$API_USER" "$API_TOKEN_NAME" \
        --path "$path" \
        --output-format json
}

permission_present() {
    local json=$1 privilege=$2

    jq -e --arg privilege "$privilege" '
        any(.[]?;
            (type == "object")
            and (
                ((.[$privilege] // 0) == 1)
                or ((.[$privilege] // false) == true)
            )
        )
    ' <<<"$json" >/dev/null
}

require_permissions_at() {
    local path=$1 raw=$2 json privilege missing=""

    json="$(token_permissions_at "$path")" \
        || die "Не удалось получить effective permissions token на $path"

    while IFS= read -r privilege; do
        [[ -n "$privilege" ]] || continue
        permission_present "$json" "$privilege" \
            || missing="$missing $privilege"
    done < <(priv_lines "$raw")

    [[ -z "$missing" ]] \
        || die "Token не имеет обязательных privileges на $path:$missing"
}

forbid_permissions_at() {
    local path=$1 raw=$2 json privilege found=""

    json="$(token_permissions_at "$path")" \
        || die "Не удалось получить effective permissions token на $path"

    while IFS= read -r privilege; do
        [[ -n "$privilege" ]] || continue
        permission_present "$json" "$privilege" \
            && found="$found $privilege"
    done < <(priv_lines "$raw")

    [[ -z "$found" ]] \
        || die "Token имеет запрещённые privileges на $path:$found"
}

verify_infra_access_contract() {
    managed_pool_exists || die "Pool $MANAGED_POOL отсутствует"
    assert_910_outside_managed_pool
    ensure_managed_guest_role
    ensure_principal_acls user "$API_USER"
    ensure_principal_acls token "$API_TOKEN_ID"
    verify_acl_boundaries

    require_permissions_at \
        "/pool/$MANAGED_POOL" \
        "$ROLE_MANAGED_GUEST_PRIVS"
    require_permissions_at \
        "/vms/$TEMPLATE_VMID" \
        "VM.Audit VM.Clone"
    require_permissions_at \
        "/storage/$CT_STORAGE" \
        "Datastore.Audit Datastore.AllocateSpace"
    require_permissions_at \
        "/sdn/zones/localnetwork/$CT_BRIDGE" \
        "SDN.Audit SDN.Use"

    # Ключевая граница: разворачиватель видит 910, но не меняет его.
    forbid_permissions_at "/vms/$CTID" "$FORBIDDEN_VM_PRIVS"

    # На корне разрешены только audit-права; административные запрещены.
    forbid_permissions_at "/" "$FORBIDDEN_ROOT_PRIVS"

    ok "PVE access contract infra-deployer проверен"
}

ensure_infra_access_contract() {
    ensure_managed_pool
    ensure_managed_guest_role
    ensure_principal_acls user "$API_USER"

    if api_token_exists; then
        ensure_principal_acls token "$API_TOKEN_ID"
    fi
}

create_api_token_and_stage_secret() {
    local json secret tmp

    json=$(pveum user token add "$API_USER" "$API_TOKEN_NAME" --privsep 1 --output-format json)
    secret=$(jq -r '.value // empty' <<<"$json")
    [[ -n "$secret" && "$secret" != "null" ]] || die "PVE создал token, но secret не удалось получить"

    install -d -o root -g root -m 0700 "$HOST_TMP_DIR"
    tmp=$(mktemp "$HOST_TMP_DIR/pve-api.XXXXXX")
    chmod 0600 "$tmp"

    cat >"$tmp" <<EOF_TOKEN
PVE_API_URL=https://$(hostname -s):8006
PVE_API_TOKEN_ID=$API_TOKEN_ID
PVE_API_TOKEN_SECRET=$secret
EOF_TOKEN

    ct_exec install -d -m 0700 "$CT_BOOTSTRAP_DIR"
    if ! pct push "$CTID" "$tmp" "$CT_SECRET_FILE" --user 0 --group 0 --perms 0600; then
        rm -f "$tmp"
        pveum user token remove "$API_USER" "$API_TOKEN_NAME" >/dev/null 2>&1 || true
        die "Не удалось передать API token secret в 910; созданный token удалён"
    fi
    rm -f "$tmp"

    ok "Создан и передан в 910 API token $API_TOKEN_ID"
}

ensure_api_identity() {
    ensure_api_user

    if [[ "$MODE" == "check" ]]; then
        api_token_exists || die "PVE API token $API_TOKEN_ID отсутствует"
        assert_api_token_privsep
        verify_infra_access_contract
        ok "PVE API identity существует и соответствует контракту"
        return
    fi

    ensure_managed_pool
    ensure_managed_guest_role
    ensure_principal_acls user "$API_USER"

    if [[ "$MODE" == "recover" ]] && api_token_exists; then
        log "Явная смена PVE API token в режиме recovery"
        pveum user token remove "$API_USER" "$API_TOKEN_NAME"
    fi

    if ! api_token_exists; then
        create_api_token_and_stage_secret
    elif ct_exec test -f "$CT_COMPLETE_MARKER"; then
        assert_api_token_privsep
        ok "Используется существующий PVE API token"
    elif ct_exec test -s "$CT_SECRET_FILE"; then
        assert_api_token_privsep
        ok "API token уже подготовлен для незавершённой настройки"
    else
        die "Token $API_TOKEN_ID существует, но secret недоступен. Для явной ротации используйте --recover."
    fi

    ensure_principal_acls token "$API_TOKEN_ID"
    assert_api_token_privsep
    verify_infra_access_contract
}

ensure_github_key() {
    [[ "$MODE" != "check" ]] || return 0

    ct_exec install -d -m 0700 /root/.ssh

    if ct_exec test -f "$CT_GITHUB_KEY"; then
        ok "GitHub Deploy Key внутри 910 уже существует"
    else
        ct_exec test ! -e "$CT_GITHUB_PUB" || die "В 910 есть public GitHub key без private key"
        ct_exec ssh-keygen -q -t ed25519 -N '' \
            -C infra-deployer-readonly-zsergeyru-proxmox \
            -f "$CT_GITHUB_KEY"
        ok "GitHub Deploy Key создан внутри 910"
    fi

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
}

private_branch_accessible() {
    ct_exec env GIT_SSH_COMMAND="ssh -F $CT_GITHUB_SSH_CONFIG" \
        git ls-remote "$PRIVATE_REPO" "refs/heads/$PRIVATE_BRANCH" 2>/dev/null \
        | grep -q .
}

show_github_key() {
    printf '\n%sДобавьте этот ключ в GitHub как read-only Deploy Key репозитория zsergeyru/proxmox:%s\n\n' \
        "$C_BOLD" "$C_RESET"
    ct_exec cat "$CT_GITHUB_PUB"
    printf '\nGitHub -> zsergeyru/proxmox -> Settings -> Deploy keys -> Add deploy key\n'
    printf 'Allow write access: ВЫКЛЮЧЕН\n\n'
}

ensure_private_repo_access() {
    if private_branch_accessible; then
        ok "910 имеет read-only доступ к закрытому проекту"
        return
    fi

    show_github_key

    [[ -r /dev/tty ]] \
        || die "GitHub Deploy Key ещё не зарегистрирован. Добавьте показанный key и повторите bootstrap."

    printf 'Нажмите Enter после добавления Deploy Key в GitHub...' >/dev/tty
    IFS= read -r _ </dev/tty || die "Не удалось прочитать подтверждение"
    printf '\n' >/dev/tty

    private_branch_accessible || die "Доступ к $PRIVATE_REPO/$PRIVATE_BRANCH по-прежнему отсутствует"
    ok "Read-only доступ к закрытому проекту подтверждён"
}

checkout_private_project() {
    local origin
    [[ "$MODE" != "check" ]] || return 0

    log "Получение закрытого проекта внутри 910"

    if ct_exec test -d "$CT_PROJECT_DIR/.git"; then
        origin=$(ct_exec git -C "$CT_PROJECT_DIR" remote get-url origin)
        [[ "$origin" == "$PRIVATE_REPO" ]] \
            || die "Bootstrap checkout внутри 910 имеет неожиданный origin: $origin"

        ct_exec env GIT_SSH_COMMAND="ssh -F $CT_GITHUB_SSH_CONFIG" \
            git -C "$CT_PROJECT_DIR" fetch --depth 1 origin "$PRIVATE_BRANCH"
        ct_exec git -C "$CT_PROJECT_DIR" reset --hard FETCH_HEAD
        ct_exec git -C "$CT_PROJECT_DIR" clean -ffdx
    else
        ct_exec rm -rf "$CT_PROJECT_DIR"
        ct_exec install -d -m 0755 /var/lib/infra-deployer
        ct_exec env GIT_SSH_COMMAND="ssh -F $CT_GITHUB_SSH_CONFIG" \
            git clone --depth 1 --branch "$PRIVATE_BRANCH" "$PRIVATE_REPO" "$CT_PROJECT_DIR"
    fi

    ok "Закрытый проект получен внутри 910"
}

run_private_setup() {
    local setup revision installed_revision=""
    [[ "$MODE" != "check" ]] || return 0

    setup="$CT_PROJECT_DIR/$PRIVATE_SETUP_PATH"
    ct_exec test -f "$setup" \
        || die "В ветке $PRIVATE_BRANCH закрытого проекта отсутствует $PRIVATE_SETUP_PATH"

    revision=$(ct_exec git -C "$CT_PROJECT_DIR" rev-parse HEAD)

    if ct_exec test -f "$CT_COMPLETE_MARKER" && [[ "$MODE" != "recover" ]]; then
        installed_revision="$(ct_exec sed -n 's/^project_revision=//p' "$CT_COMPLETE_MARKER" | head -n1)"
        if [[ "$installed_revision" == "$revision" ]]; then
            ok "910 уже использует текущую ревизию проекта: $revision"
            return
        fi
        log "Обновление infra-deployer до ревизии $revision"
    else
        log "Передача управления настройке infra-deployer"
    fi

    local recover_flag=0
    [[ "$MODE" == "recover" ]] && recover_flag=1

    ct_exec env \
        INFRA_DEPLOYER_BOOTSTRAP=1 \
        INFRA_DEPLOYER_RECOVER="$recover_flag" \
        INFRA_PROJECT_BRANCH="$PRIVATE_BRANCH" \
        PVE_API_SECRET_FILE="$CT_SECRET_FILE" \
        bash "$setup"

    ct_exec rm -f "$CT_SECRET_FILE"
    ct_exec install -d -m 0755 /var/lib/infra-deployer

    ct_exec sh -c "cat > '$CT_COMPLETE_MARKER' <<EOF_MARKER
bootstrap=complete
public_bootstrap_version=$PUBLIC_BOOTSTRAP_VERSION
project_branch=$PRIVATE_BRANCH
project_revision=$revision
EOF_MARKER
chmod 0600 '$CT_COMPLETE_MARKER'"

    if [[ -n "$installed_revision" ]]; then
        ok "infra-deployer обновлён до ревизии $revision"
    else
        ok "Первоначальная настройка 910 завершена"
    fi
}

check_ready_state() {
    local status node
    log "Проверка состояния"

    assert_owned_ct || die "LXC $CTID отсутствует"
    warn_ct_drift

    status=$(pct status "$CTID" | awk '{print $2}')
    [[ "$status" == "running" ]] || die "LXC $CTID не запущен"

    api_user_exists || die "PVE user $API_USER отсутствует"
    api_token_exists || die "PVE API token $API_TOKEN_ID отсутствует"
    assert_api_token_privsep
    verify_infra_access_contract
    ct_exec test -f "$CT_COMPLETE_MARKER" \
        || die "LXC $CTID существует, но первоначальная настройка ещё не завершена"
    ct_exec test -x /usr/local/sbin/infra-deployer-status \
        || die "В 910 отсутствует команда infra-deployer-status"
    ct_exec /usr/local/sbin/infra-deployer-status >/dev/null \
        || die "Внутренняя проверка infra-deployer завершилась ошибкой"
    ct_exec ip -4 route show default | grep -q '^default ' \
        || die "В 910 нет IPv4 default route"

    node=$(hostname -s)
    # Здесь проверяется именно TLS и доступность HTTPS. Ответ 401 допустим:
    # авторизацию PVE API уже проверяет infra-deployer-status выше.
    ct_exec curl -sS --connect-timeout 5 --max-time 15 \
        -o /dev/null \
        "https://$node:8006/api2/json/version" \
        || die "910 не может проверить TLS соединение с PVE API"

    ok "910 infra-deployer соответствует bootstrap-контракту"
}

main() {
    local template_ref=""
    local ct_was_created=0

    parse_args "$@"
    require_root_and_pve
    info "Public Bootstrap v$PUBLIC_BOOTSTRAP_VERSION, режим: $MODE"
    acquire_lock
    ensure_host_packages
    host_preflight

    if [[ "$MODE" == "check" ]]; then
        ensure_debian13_template >/dev/null
        check_ready_state
        exit 0
    fi

    if assert_owned_ct; then
        info "Найден принадлежащий bootstrap LXC $CTID"
        warn_ct_drift
    else
        backup_host_config
        template_ref=$(ensure_debian13_template)
        create_infra_deployer "$template_ref"
        ct_was_created=1
    fi

    ensure_ct_running
    wait_ct_network

    if ct_exec test -f "$CT_COMPLETE_MARKER" && [[ "$MODE" == "apply" ]]; then
        ensure_api_identity
        ensure_github_key
        ensure_private_repo_access
        checkout_private_project
        run_private_setup
        check_ready_state

        printf '\n%s%sPUBLIC BOOTSTRAP УСПЕШНО ЗАВЕРШЁН%s\n' \
            "$C_BOLD" "$C_GREEN" "$C_RESET"
        printf 'Дальнейшее управление инфраструктурой выполняется из LXC %s %s.\n' \
            "$CTID" "$CT_HOSTNAME"
        exit 0
    fi

    if ((ct_was_created == 0)); then
        backup_host_config
    fi

    bootstrap_ct_os
    install_pve_ca
    ensure_api_identity
    ensure_github_key
    ensure_private_repo_access
    checkout_private_project
    run_private_setup
    check_ready_state

    printf '\n%s%sPUBLIC BOOTSTRAP УСПЕШНО ЗАВЕРШЁН%s\n' \
        "$C_BOLD" "$C_GREEN" "$C_RESET"
    printf 'Дальнейшее управление инфраструктурой выполняется из LXC %s %s.\n' \
        "$CTID" "$CT_HOSTNAME"
}

main "$@"
