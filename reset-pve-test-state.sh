#!/usr/bin/env bash
set -Eeuo pipefail

# Очистка тестового PVE от известных следов проекта Proxmox.
# По умолчанию ничего не удаляет. Реальные изменения только с --apply.
#
# Скрипт намеренно НЕ:
# - меняет сеть, storage.cfg или APT repositories;
# - удаляет неизвестные VM/LXC;
# - удаляет системные пакеты;
# - удаляет Debian LXC templates из local:vztmpl;
# - удаляет Deploy Key из GitHub.

APPLY=0
PURGE_BACKUPS=0
BLOCKED=0
CHANGES=0

CT_INFRA=910
CT_TEST=9098
VM_TEMPLATE=9000
VM_SMOKE=9099

C_RESET=""
C_BOLD=""
C_GREEN=""
C_BLUE=""
C_YELLOW=""
C_RED=""

if [[ -t 1 && "${NO_COLOR:-}" == "" && "${TERM:-}" != "dumb" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_GREEN=$'\033[32m'
    C_BLUE=$'\033[34m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
fi

log()  { printf '\n%s%s==> %s%s\n' "$C_BOLD" "$C_BLUE" "$*" "$C_RESET"; }
ok()   { printf '%s%s[ОК]%s %s\n' "$C_BOLD" "$C_GREEN" "$C_RESET" "$*"; }
info() { printf '[ИНФО] %s\n' "$*"; }
warn() { printf '%s%s[ПРЕДУПРЕЖДЕНИЕ]%s %s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET" "$*" >&2; }
block() {
    BLOCKED=$((BLOCKED + 1))
    printf '%s%s[БЛОКИРОВКА]%s %s\n' "$C_BOLD" "$C_RED" "$C_RESET" "$*" >&2
}
die() {
    printf '\n%s%sОШИБКА:%s %s\n' "$C_BOLD" "$C_RED" "$C_RESET" "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Использование:
  reset-pve-test-state.sh
  reset-pve-test-state.sh --apply
  reset-pve-test-state.sh --apply --purge-backups

Без --apply:
  только показывает план очистки.

--apply:
  удаляет только точно известные объекты и файлы проекта.

--purge-backups:
  дополнительно удаляет каталоги резервных копий старых bootstrap/PVE Configuration.
  Используется только вместе с --apply.

Скрипт не удаляет неизвестные VM/LXC, не откатывает сеть/storage/APT и
не удаляет системные пакеты или Debian LXC templates.
USAGE
}

parse_args() {
    while (($#)); do
        case "$1" in
            --apply)
                APPLY=1
                ;;
            --purge-backups)
                PURGE_BACKUPS=1
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

    (( PURGE_BACKUPS == 0 || APPLY == 1 ))         || die "--purge-backups используется только вместе с --apply"
}

require_pve_root() {
    local cmd
    [[ $EUID -eq 0 ]] || die "Запустите скрипт от root на PVE"

    for cmd in pveversion pvesh pveum pct qm jq; do
        command -v "$cmd" >/dev/null 2>&1 || die "Не найдена обязательная команда: $cmd"
    done

    pveversion >/dev/null 2>&1 || die "Proxmox VE не обнаружен"
}

run() {
    local description=$1
    shift

    CHANGES=$((CHANGES + 1))
    if (( APPLY )); then
        printf '[УДАЛЕНИЕ] %s\n' "$description"
        "$@"
    else
        printf '[ПЛАН] %s\n' "$description"
    fi
}

pct_exists() {
    pct config "$1" >/dev/null 2>&1
}

qm_exists() {
    qm config "$1" >/dev/null 2>&1
}

config_value() {
    local config=$1 key=$2
    awk -F ': ' -v key="$key" '$1 == key {print $2; exit}' <<<"$config"
}

tag_present() {
    local tags=$1 expected=$2
    tr ';,' '\n' <<<"$tags" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -Fxq "$expected"
}

remove_known_ct() {
    local vmid=$1 expected_hostname=$2 require_bootstrap_tags=$3
    local config hostname tags status lock protection

    if qm_exists "$vmid"; then
        block "VMID $vmid занят VM. Скрипт ожидал известный LXC и не будет его трогать."
        return
    fi
    pct_exists "$vmid" || return

    config="$(pct config "$vmid")"
    hostname="$(config_value "$config" hostname)"
    tags="$(config_value "$config" tags)"
    lock="$(config_value "$config" lock)"

    if [[ "$hostname" != "$expected_hostname" ]]; then
        block "LXC $vmid имеет hostname '$hostname', ожидался '$expected_hostname'. Объект оставлен."
        return
    fi

    if (( require_bootstrap_tags )); then
        if ! tag_present "$tags" "infra-manager" || ! tag_present "$tags" "proxmox-bootstrap"; then
            block "LXC $vmid похож на infra-manager, но не имеет обеих bootstrap-меток. Объект оставлен."
            return
        fi
    fi

    if [[ -n "$lock" ]]; then
        block "LXC $vmid заблокирован PVE (lock=$lock). Автоматическое снятие lock запрещено."
        return
    fi

    status="$(pct status "$vmid" | awk '{print $2}')"
    protection="$(config_value "$config" protection)"

    if [[ "$status" == "running" ]]; then
        run "остановить LXC $vmid ($expected_hostname)" pct stop "$vmid"
    fi
    if [[ "$protection" == "1" ]]; then
        run "снять protection с LXC $vmid" pct set "$vmid" --protection 0
    fi
    run "удалить LXC $vmid ($expected_hostname)" pct destroy "$vmid" --purge 1
}

remove_known_vm() {
    local vmid=$1
    shift
    local config name status lock protection expected matched=0

    if pct_exists "$vmid"; then
        block "VMID $vmid занят LXC. Скрипт ожидал известную VM и не будет её трогать."
        return
    fi
    qm_exists "$vmid" || return

    config="$(qm config "$vmid")"
    name="$(config_value "$config" name)"
    lock="$(config_value "$config" lock)"

    for expected in "$@"; do
        if [[ "$name" == "$expected" ]]; then
            matched=1
            break
        fi
    done

    if (( matched == 0 )); then
        block "VM $vmid имеет имя '$name' и не распознана как объект проекта. Она оставлена."
        return
    fi

    if [[ -n "$lock" ]]; then
        block "VM $vmid заблокирована PVE (lock=$lock). Автоматическое снятие lock запрещено."
        return
    fi

    status="$(qm status "$vmid" | awk '{print $2}')"
    protection="$(config_value "$config" protection)"

    if [[ "$status" == "running" ]]; then
        run "остановить VM $vmid ($name)" qm stop "$vmid"
    fi
    if [[ "$protection" == "1" ]]; then
        run "снять protection с VM $vmid" qm set "$vmid" --protection 0
    fi
    run "удалить VM $vmid ($name)" qm destroy "$vmid" --purge 1
}

pve_user_exists() {
    local userid=$1
    pveum user list --output-format json 2>/dev/null         | jq -e --arg userid "$userid" '.[] | select(.userid == $userid)' >/dev/null
}

pve_token_exists() {
    local userid=$1 token=$2
    pveum user token list "$userid" --output-format json 2>/dev/null         | jq -e --arg token "$token" '.[] | select(.tokenid == $token)' >/dev/null
}

remove_principal_acls() {
    local kind=$1 principal=$2 option path role
    local acl_json

    acl_json="$(pveum acl list --output-format json)"

    case "$kind" in
        user) option="--users" ;;
        token) option="--tokens" ;;
        *) die "Неизвестный тип ACL principal: $kind" ;;
    esac

    while IFS=$'\t' read -r path role; do
        [[ -n "$path" && -n "$role" ]] || continue
        run "удалить ACL $kind=$principal path=$path role=$role"             pveum acl delete "$path" "$option" "$principal" --roles "$role"
    done < <(
        jq -r --arg kind "$kind" --arg principal "$principal" '
            .[]
            | select(.type == $kind and .ugid == $principal)
            | [.path, .roleid]
            | @tsv
        ' <<<"$acl_json"
    )
}

remove_token() {
    local userid=$1 token=$2 full
    full="${userid}!${token}"

    remove_principal_acls token "$full"
    pve_token_exists "$userid" "$token" || return

    run "удалить PVE API token $full" pveum user token remove "$userid" "$token"
}

remove_project_user() {
    local userid=$1 token=$2

    remove_token "$userid" "$token"
    remove_principal_acls user "$userid"
    pve_user_exists "$userid" || return

    run "удалить PVE user $userid" pveum user delete "$userid"
}

pve_role_exists() {
    local role=$1
    pveum role list --output-format json 2>/dev/null         | jq -e --arg role "$role" '.[] | select(.roleid == $role)' >/dev/null
}

remove_project_role() {
    local role=$1
    pve_role_exists "$role" || return
    run "удалить PVE role $role" pveum role delete "$role"
}

remove_project_access() {
    log "PVE users, tokens, ACL и роли"

    # Текущая чистая схема: удаляется только token, root@pam не трогаем.
    remove_token "root@pam" "infra-manager"

    # Следы прежних вариантов проекта.
    remove_project_user "infra-deployer@pve" "automation"
    remove_project_user "deployer@pve" "host-deploy"
    remove_project_user "ai-agent@pve" "infra"

    local role
    for role in         InfraManagedGuest         AICloneSource         AIManagedGuest         AINetworkUse         AIStorage         AIManagedPool
    do
        remove_project_role "$role"
    done
}

pool_exists() {
    pvesh get /pools/managed --output-format json >/dev/null 2>&1
}

remove_managed_pool() {
    local json members remaining_acls

    pool_exists || return
    json="$(pvesh get /pools/managed --output-format json)"
    members="$(jq -r '(.members // []) | length' <<<"$json")"

    if (( members > 0 )); then
        warn "Pool managed не пуст. Неизвестные/оставшиеся объекты автоматически не удаляются:"
        jq -r '(.members // [])[] | "  - \(.type // "?") \(.vmid // "?") \(.name // "")"' <<<"$json" >&2
        block "Pool managed оставлен, потому что в нём есть участники."
        return
    fi

    remaining_acls="$(
        pveum acl list --output-format json             | jq -r '[.[] | select(.path == "/pool/managed")] | length'
    )"
    if (( remaining_acls > 0 )); then
        warn "На /pool/managed остались ACL неизвестных principal:"
        pveum acl list --output-format json             | jq -r '.[] | select(.path == "/pool/managed") | "  - \(.type) \(.ugid) role=\(.roleid)"' >&2
        block "Pool managed оставлен из-за неизвестных ACL."
        return
    fi

    run "удалить пустой pool managed" pveum pool delete managed
}

remove_linux_deployer() {
    local entry home shell

    getent passwd pvedeploy >/dev/null 2>&1 || return
    entry="$(getent passwd pvedeploy)"
    home="$(cut -d: -f6 <<<"$entry")"
    shell="$(cut -d: -f7 <<<"$entry")"

    if [[ "$home" != "/var/lib/pvedeploy" || "$shell" != "/bin/bash" ]]; then
        block "Linux user pvedeploy не соответствует старому контракту проекта (home=$home shell=$shell). Пользователь оставлен."
        return
    fi

    run "удалить Linux user pvedeploy и его home" userdel -r pvedeploy

    if getent group pvedeploy >/dev/null 2>&1; then
        run "удалить оставшуюся группу pvedeploy" groupdel pvedeploy
    fi
}

remove_path() {
    local path=$1 description=$2
    [[ -e "$path" || -L "$path" ]] || return
    run "$description: $path" rm -rf -- "$path"
}

remove_project_files() {
    log "Файлы старых и текущих вариантов проекта на PVE"

    remove_path /etc/proxmox-deployer "удалить старую конфигурацию"
    remove_path /var/lib/proxmox-deployer "удалить старое рабочее состояние"
    remove_path /var/lib/pvedeploy "удалить старый home/runtime"
    remove_path /var/log/proxmox-deployer "удалить старые журналы"

    remove_path /usr/local/sbin/pve-configuration-status "удалить старую служебную команду"
    remove_path /usr/local/sbin/deploy-guest "удалить старую служебную команду"
    remove_path /usr/local/sbin/sync-management-keys "удалить старую служебную команду"

    remove_path /var/lib/vz/snippets/debian13-template-builder-9000.yaml "удалить старый snippet VM template"

    remove_path /run/proxmox-bootstrap "удалить временный каталог bootstrap"
    remove_path /run/lock/proxmox-bootstrap.lock "удалить lock-файл bootstrap"
    remove_path /run/lock/proxmox-orchestration.lock "удалить старый orchestration lock"

    if (( PURGE_BACKUPS )); then
        remove_path /var/backups/proxmox-bootstrap "удалить резервные копии старого public bootstrap"
        remove_path /var/backups/proxmox-configuration "удалить резервные копии старого PVE Configuration"
        remove_path /var/backups/proxmox-secrets "удалить резервные копии старых секретов"
    else
        for path in             /var/backups/proxmox-bootstrap             /var/backups/proxmox-configuration             /var/backups/proxmox-secrets
        do
            [[ -e "$path" ]] && warn "Резервные копии сохранены: $path (для удаления: --apply --purge-backups)"
        done
    fi
}

remove_project_objects() {
    log "Виртуальные объекты проекта"

    remove_known_ct "$CT_INFRA" "infra-manager" 1
    remove_known_ct "$CT_TEST" "infra-access-test" 0

    remove_known_vm "$VM_SMOKE" "smoke-template-9000"
    remove_known_vm "$VM_TEMPLATE" "tpl-debian13" "builder-9000"
}

show_preserved_state() {
    log "Что намеренно не меняется"

    cat <<'EOF_KEEP'
- vmbr0 и другая сеть PVE;
- local/local-lvm и storage.cfg;
- APT repositories;
- установленные системные пакеты;
- Debian LXC templates в local:vztmpl;
- любые неизвестные VM/LXC;
- Deploy Key в GitHub.
EOF_KEEP
}

main() {
    parse_args "$@"
    require_pve_root

    if (( APPLY )); then
        warn "РЕЖИМ УДАЛЕНИЯ: будут удалены только распознанные объекты проекта."
    else
        info "Режим просмотра. Изменений не будет. Для удаления используйте --apply."
    fi

    remove_project_objects
    remove_project_access
    remove_managed_pool
    remove_linux_deployer
    remove_project_files
    show_preserved_state

    printf '\n'
    if (( BLOCKED > 0 )); then
        warn "Очистка завершена не полностью: блокировок=$BLOCKED."
        warn "Неизвестные объекты намеренно оставлены."
        exit 2
    fi

    if (( APPLY )); then
        ok "Известные следы проекта на PVE удалены."
        if (( PURGE_BACKUPS == 0 )); then
            info "Резервные копии, если они были, сохранены."
        fi
    else
        ok "План очистки построен: действий=$CHANGES. Ничего не изменено."
    fi
}

main "$@"
