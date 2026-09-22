#!/usr/bin/env bash
set -Eeuo pipefail

# Минимальный public bootstrap для Proxmox VE.
# Его задача: создать/запустить 910, выдать ему ограниченный PVE API token,
# дать read-only доступ к закрытому Git и передать управление setup.sh.
# Docker, Semaphore, OpenTofu, Ansible и Packer настраиваются уже внутри 910.

PUBLIC_BOOTSTRAP_VERSION="3.0.0-dev1"

CTID=910
CT_HOSTNAME="infra-deployer"
CT_CORES=2
CT_MEMORY_MB=2048
CT_SWAP_MB=512
CT_DISK_GB=32
CT_STORAGE="local-lvm"
CT_BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"

API_USER="root@pam"
API_TOKEN_NAME="infra-deployer"
API_TOKEN_ID="$API_USER!$API_TOKEN_NAME"

MANAGED_POOL="managed"
TEMPLATE_VMID=9000

PRIVATE_REPO="git@github.com:zsergeyru/proxmox.git"
PRIVATE_BRANCH="infra-iac-redesign"
PRIVATE_SETUP_PATH="scripts/infra-deployer/setup.sh"

LOCK_FILE="/run/lock/proxmox-bootstrap.lock"
HOST_TMP_DIR="/run/proxmox-bootstrap"

CT_BOOTSTRAP_DIR="/root/.infra-deployer-bootstrap"
CT_SECRET_FILE="$CT_BOOTSTRAP_DIR/pve-api.env"
CT_PERSISTENT_SECRET="/etc/infra-deployer/secrets/pve-api.env"
CT_GITHUB_KEY="/root/.ssh/github_proxmox_repo_ed25519"
CT_GITHUB_PUB="$CT_GITHUB_KEY.pub"
CT_GITHUB_KNOWN_HOSTS="/root/.ssh/github_known_hosts"
CT_GITHUB_SSH_CONFIG="/root/.ssh/github_config"
CT_PROJECT_DIR="/var/lib/infra-deployer/bootstrap-repo"
CT_COMPLETE_MARKER="/var/lib/infra-deployer/bootstrap-complete"

LEGACY_API_USER="infra-deployer@pve"
LEGACY_API_TOKEN_NAME="automation"
LEGACY_API_TOKEN_ID="$LEGACY_API_USER!$LEGACY_API_TOKEN_NAME"
LEGACY_ROLE="InfraManagedGuest"

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
    if dpkg -s jq >/dev/null 2>&1; then
        return
    fi

    [[ "$MODE" != "check" ]] || die "Для проверки не хватает пакета jq"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends jq
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
    log "Проверка минимальной основы PVE"

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

    ok "Минимальная основа PVE готова"
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

managed_pool_exists() {
    pvesh get "/pools/$MANAGED_POOL" --output-format json >/dev/null 2>&1
}

ensure_managed_pool() {
    if managed_pool_exists; then
        return
    fi

    [[ "$MODE" != "check" ]] || die "Pool $MANAGED_POOL отсутствует"
    pveum pool add "$MANAGED_POOL" --comment "Guests managed from 910 infra-deployer"
    ok "Создан pool $MANAGED_POOL"
}

api_token_exists() {
    pveum user token list "$API_USER" --output-format json 2>/dev/null \
        | jq -e --arg token "$API_TOKEN_NAME" \
            '.[] | select(.tokenid == $token)' >/dev/null
}

assert_api_token_privsep() {
    local value
    value="$(pveum user token list "$API_USER" --output-format json 2>/dev/null \
        | jq -r --arg token "$API_TOKEN_NAME" \
            '.[] | select(.tokenid == $token) | .privsep // empty')"
    [[ "$value" == "1" ]] || die "PVE API token $API_TOKEN_ID должен иметь privsep=1"
}

token_acl_exists() {
    local path=$1 role=$2

    pveum acl list --output-format json \
        | jq -e \
            --arg path "$path" \
            --arg token "$API_TOKEN_ID" \
            --arg role "$role" \
            '.[] | select(
                .path == $path
                and .type == "token"
                and .ugid == $token
                and .roleid == $role
                and ((.propagate // 1) == 1)
            )' >/dev/null
}

ensure_token_acl() {
    local path=$1 role=$2

    token_acl_exists "$path" "$role" && return
    [[ "$MODE" != "check" ]] \
        || die "Отсутствует ACL token=$API_TOKEN_ID path=$path role=$role"

    pveum acl modify "$path" \
        --tokens "$API_TOKEN_ID" \
        --roles "$role" \
        --propagate 1
}

persistent_token_available() {
    ct_exec test -s "$CT_PERSISTENT_SECRET" || return 1
    ct_exec grep -Fxq "PVE_API_TOKEN_ID=$API_TOKEN_ID" "$CT_PERSISTENT_SECRET"
}

stage_api_secret() {
    local secret=$1 node tmp

    node=$(hostname -s)
    install -d -o root -g root -m 0700 "$HOST_TMP_DIR"
    tmp=$(mktemp "$HOST_TMP_DIR/pve-api.XXXXXX")
    chmod 0600 "$tmp"

    cat >"$tmp" <<EOF_TOKEN
PVE_API_URL=https://$node:8006
PVE_API_TOKEN_ID=$API_TOKEN_ID
PVE_API_TOKEN_SECRET=$secret
EOF_TOKEN

    ct_exec install -d -m 0700 "$CT_BOOTSTRAP_DIR"
    pct push "$CTID" "$tmp" "$CT_SECRET_FILE" --user 0 --group 0 --perms 0600
    rm -f "$tmp"
}

create_api_token() {
    local json secret

    json="$(pveum user token add "$API_USER" "$API_TOKEN_NAME" \
        --privsep 1 --output-format json)"
    secret="$(jq -r '.value // empty' <<<"$json")"
    [[ -n "$secret" && "$secret" != "null" ]] \
        || die "PVE создал token, но secret не удалось получить"

    stage_api_secret "$secret"
    ok "Создан и передан в 910 PVE API token $API_TOKEN_ID"
}

ensure_pve_access() {
    ensure_managed_pool

    if [[ "$MODE" == "recover" ]] && api_token_exists; then
        log "Смена PVE API token при восстановлении"
        pveum user token remove "$API_USER" "$API_TOKEN_NAME"
    fi

    if ! api_token_exists; then
        create_api_token
    elif ct_exec test -s "$CT_SECRET_FILE"; then
        ok "PVE API secret уже подготовлен для незавершённой настройки"
    elif persistent_token_available; then
        ok "Используется существующий PVE API token"
    else
        die "Token $API_TOKEN_ID существует, но его secret недоступен в 910. Используйте --recover."
    fi

    assert_api_token_privsep

    # Только штатные роли Proxmox. Изменение гостей ограничено pool managed.
    ensure_token_acl "/" "PVEAuditor"
    ensure_token_acl "/pool/$MANAGED_POOL" "PVEVMAdmin"
    ensure_token_acl "/storage/$CT_STORAGE" "PVEDatastoreUser"
    ensure_token_acl "/sdn/zones/localnetwork/$CT_BRIDGE" "PVESDNUser"
    ensure_token_acl "/vms/$TEMPLATE_VMID" "PVETemplateUser"

    ok "Ограниченный PVE API-доступ для 910 готов"
}

legacy_api_user_exists() {
    pveum user list --output-format json 2>/dev/null \
        | jq -e --arg user "$LEGACY_API_USER" \
            '.[] | select(.userid == $user)' >/dev/null
}

legacy_api_token_exists() {
    pveum user token list "$LEGACY_API_USER" --output-format json 2>/dev/null \
        | jq -e --arg token "$LEGACY_API_TOKEN_NAME" \
            '.[] | select(.tokenid == $token)' >/dev/null
}

cleanup_legacy_access() {
    legacy_api_user_exists || return 0

    warn "Удаляется прежняя PVE-идентичность $LEGACY_API_TOKEN_ID"

    pveum acl delete "/" --users "$LEGACY_API_USER" --roles PVEAuditor >/dev/null 2>&1 || true
    pveum acl delete "/pool/$MANAGED_POOL" --users "$LEGACY_API_USER" --roles "$LEGACY_ROLE" >/dev/null 2>&1 || true
    pveum acl delete "/vms/$TEMPLATE_VMID" --users "$LEGACY_API_USER" --roles PVETemplateUser >/dev/null 2>&1 || true
    pveum acl delete "/storage/$CT_STORAGE" --users "$LEGACY_API_USER" --roles PVEDatastoreUser >/dev/null 2>&1 || true
    pveum acl delete "/sdn/zones/localnetwork/$CT_BRIDGE" --users "$LEGACY_API_USER" --roles PVESDNUser >/dev/null 2>&1 || true

    if legacy_api_token_exists; then
        pveum acl delete "/" --tokens "$LEGACY_API_TOKEN_ID" --roles PVEAuditor >/dev/null 2>&1 || true
        pveum acl delete "/pool/$MANAGED_POOL" --tokens "$LEGACY_API_TOKEN_ID" --roles "$LEGACY_ROLE" >/dev/null 2>&1 || true
        pveum acl delete "/vms/$TEMPLATE_VMID" --tokens "$LEGACY_API_TOKEN_ID" --roles PVETemplateUser >/dev/null 2>&1 || true
        pveum acl delete "/storage/$CT_STORAGE" --tokens "$LEGACY_API_TOKEN_ID" --roles PVEDatastoreUser >/dev/null 2>&1 || true
        pveum acl delete "/sdn/zones/localnetwork/$CT_BRIDGE" --tokens "$LEGACY_API_TOKEN_ID" --roles PVESDNUser >/dev/null 2>&1 || true
        pveum user token remove "$LEGACY_API_USER" "$LEGACY_API_TOKEN_NAME" >/dev/null
    fi

    pveum user delete "$LEGACY_API_USER" >/dev/null
    pveum role delete "$LEGACY_ROLE" >/dev/null 2>&1 || true
    ok "Прежняя PVE-идентичность удалена"
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
    local status

    assert_owned_ct || die "LXC $CTID отсутствует"

    status=$(pct status "$CTID" | awk '{print $2}')
    [[ "$status" == "running" ]] || die "LXC $CTID не запущен"

    managed_pool_exists || die "Pool $MANAGED_POOL отсутствует"
    api_token_exists || die "PVE API token $API_TOKEN_ID отсутствует"
    assert_api_token_privsep

    ct_exec test -f "$CT_COMPLETE_MARKER" \
        || die "Первоначальная настройка 910 ещё не завершена"
    ct_exec test -x /usr/local/sbin/infra-deployer-status \
        || die "В 910 отсутствует infra-deployer-status"
    ct_exec /usr/local/sbin/infra-deployer-status >/dev/null \
        || die "Внутренняя проверка 910 завершилась ошибкой"

    ok "910 infra-deployer готов"
}

main() {
    local template_ref=""

    parse_args "$@"
    require_root_and_pve
    info "Public Bootstrap v$PUBLIC_BOOTSTRAP_VERSION, режим: $MODE"
    acquire_lock
    ensure_host_packages
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
        check_ready_state
        exit 0
    fi

    bootstrap_ct_os
    install_pve_ca
    ensure_pve_access
    ensure_github_key
    ensure_private_repo_access
    checkout_private_project
    run_private_setup
    check_ready_state
    cleanup_legacy_access

    printf '\n%s%sPUBLIC BOOTSTRAP УСПЕШНО ЗАВЕРШЁН%s\n' \
        "$C_BOLD" "$C_GREEN" "$C_RESET"
    printf 'Единственная ручная операция — добавление GitHub Deploy Key при первом запуске.\n'
}

main "$@"
