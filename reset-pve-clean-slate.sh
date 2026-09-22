#!/usr/bin/env bash
set -Eeuo pipefail

# Полная очистка одиночного тестового PVE перед новым запуском bootstrap.
# Единственный сохраняемый гостевой объект — QEMU VM 100.
# По умолчанию только показывает план. Реальные изменения только с --apply.
#
# Не изменяются сеть, storage.cfg, APT и установленные системные пакеты.

KEEP_VMID=100
APPLY=0
CHANGES=0

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


die() {
    printf '\n%s%sОШИБКА:%s %s\n' "$C_BOLD" "$C_RED" "$C_RESET" "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Использование:
  reset-pve-clean-slate.sh
  reset-pve-clean-slate.sh --apply

Без --apply:
  только показывает план полной очистки.

--apply:
  сохраняет только QEMU VM 100 и удаляет:
  - все остальные VM/LXC;
  - явные ACL и API tokens;
  - дополнительные PVE users/groups;
  - известные проектные роли;
  - pool managed, если после очистки он пуст;
  - старого pvedeploy и проектные файлы;
  - старые project backups;
  - Debian 13 LXC template/cache, чтобы bootstrap скачал его заново.

Не изменяются:
  - VM 100;
  - сеть PVE;
  - local/local-lvm и storage.cfg;
  - APT repositories;
  - установленные системные пакеты.
USAGE
}

parse_args() {
    while (($#)); do
        case "$1" in
            --apply) APPLY=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "Неизвестный параметр: $1" ;;
        esac
        shift
    done
}

require_pve_root() {
    local cmd node_count name
    [[ $EUID -eq 0 ]] || die "Запустите скрипт от root на PVE"

    for cmd in pveversion pvesh pveum pct qm pveam jq getent; do
        command -v "$cmd" >/dev/null 2>&1 || die "Не найдена обязательная команда: $cmd"
    done

    pveversion >/dev/null 2>&1 || die "Proxmox VE не обнаружен"

    node_count="$(pvesh get /nodes --output-format json | jq 'length')"
    [[ "$node_count" == "1" ]]         || die "Полная очистка разрешена только на одиночном PVE. Обнаружено узлов: $node_count"

    pct config "$KEEP_VMID" >/dev/null 2>&1         && die "VMID $KEEP_VMID занят LXC; ожидалась сохраняемая QEMU VM"

    qm config "$KEEP_VMID" >/dev/null 2>&1         || die "Сохраняемая QEMU VM $KEEP_VMID отсутствует. Очистка остановлена."

    name="$(qm config "$KEEP_VMID" | awk -F ': ' '$1 == "name" {print $2; exit}')"
    ok "VM $KEEP_VMID будет сохранена${name:+ ($name)}"
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

guest_rows() {
    pvesh get /cluster/resources --type vm --output-format json         | jq -r --argjson keep "$KEEP_VMID" '
            .[]
            | select((.vmid | tonumber) != $keep)
            | [(.vmid | tostring), .type, (.name // ""), (.status // "")]
            | @tsv
        '         | sort -n
}

remove_qemu() {
    local vmid=$1 name=$2
    local config status lock protection

    config="$(qm config "$vmid")"
    status="$(qm status "$vmid" | awk '{print $2}')"
    lock="$(awk -F ': ' '$1 == "lock" {print $2; exit}' <<<"$config")"
    protection="$(awk -F ': ' '$1 == "protection" {print $2; exit}' <<<"$config")"

    [[ -z "$lock" ]] || run "снять lock=$lock с VM $vmid${name:+ ($name)}" qm unlock "$vmid"
    [[ "$protection" != "1" ]] || run "снять protection с VM $vmid${name:+ ($name)}" qm set "$vmid" --protection 0
    [[ "$status" != "running" ]] || run "остановить VM $vmid${name:+ ($name)}" qm stop "$vmid"

    run "удалить VM $vmid${name:+ ($name)}"         qm destroy "$vmid" --purge 1 --destroy-unreferenced-disks 1
}

remove_lxc() {
    local vmid=$1 name=$2
    local config status lock protection

    config="$(pct config "$vmid")"
    status="$(pct status "$vmid" | awk '{print $2}')"
    lock="$(awk -F ': ' '$1 == "lock" {print $2; exit}' <<<"$config")"
    protection="$(awk -F ': ' '$1 == "protection" {print $2; exit}' <<<"$config")"

    [[ -z "$lock" ]] || run "снять lock=$lock с LXC $vmid${name:+ ($name)}" pct unlock "$vmid"
    [[ "$protection" != "1" ]] || run "снять protection с LXC $vmid${name:+ ($name)}" pct set "$vmid" --protection 0
    [[ "$status" != "running" ]] || run "остановить LXC $vmid${name:+ ($name)}" pct stop "$vmid"

    run "удалить LXC $vmid${name:+ ($name)}"         pct destroy "$vmid" --purge 1 --destroy-unreferenced-disks 1
}

remove_other_guests() {
    local vmid type name status

    log "Удаление всех VM/LXC кроме VM $KEEP_VMID"

    while IFS=$'\t' read -r vmid type name status; do
        [[ -n "$vmid" ]] || continue
        info "Найден $type $vmid${name:+ ($name)}, status=$status"

        case "$type" in
            qemu) remove_qemu "$vmid" "$name" ;;
            lxc) remove_lxc "$vmid" "$name" ;;
            *) die "Неизвестный тип guest '$type' для VMID $vmid" ;;
        esac
    done < <(guest_rows)
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
        group) option="--groups" ;;
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
    local type principal path role option userid token groupid

    log "Очистка ACL, API tokens, дополнительных PVE users/groups"

    while IFS=$'\t' read -r type principal path role; do
        [[ -n "$type" && -n "$principal" && -n "$path" && -n "$role" ]] || continue

        case "$type" in
            user) option="--users" ;;
            token) option="--tokens" ;;
            group) option="--groups" ;;
            *)
                warn "Неизвестный тип ACL '$type' для $principal — пропущен"
                continue
                ;;
        esac

        run "удалить ACL type=$type principal=$principal path=$path role=$role"             pveum acl delete "$path" "$option" "$principal" --roles "$role"
    done < <(
        pveum acl list --output-format json             | jq -r '.[] | [.type, .ugid, .path, .roleid] | @tsv'
    )

    while IFS= read -r userid; do
        [[ -n "$userid" ]] || continue

        while IFS= read -r token; do
            [[ -n "$token" ]] || continue
            run "удалить PVE API token $userid!$token"                 pveum user token remove "$userid" "$token"
        done < <(
            pveum user token list "$userid" --output-format json 2>/dev/null                 | jq -r '.[].tokenid'
        )

        [[ "$userid" == "root@pam" ]]             || run "удалить дополнительного PVE user $userid" pveum user delete "$userid"
    done < <(
        pveum user list --output-format json | jq -r '.[].userid'
    )

    while IFS= read -r groupid; do
        [[ -n "$groupid" ]] || continue
        run "удалить PVE group $groupid" pveum group delete "$groupid"
    done < <(
        pveum group list --output-format json | jq -r '.[].groupid'
    )

    local custom_role
    for custom_role in         InfraManagedGuest         AICloneSource         AIManagedGuest         AINetworkUse         AIStorage         AIManagedPool
    do
        remove_project_role "$custom_role"
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
    local path

    log "Удаление файлов и резервных копий проекта с PVE"

    for path in         /etc/proxmox-deployer         /var/lib/proxmox-deployer         /var/lib/pvedeploy         /var/log/proxmox-deployer         /etc/infra-deployer         /var/lib/infra-deployer         /opt/infra-deployer         /run/proxmox-bootstrap         /var/backups/proxmox-bootstrap         /var/backups/proxmox-configuration         /var/backups/proxmox-secrets
    do
        remove_path "$path" "удалить проектный каталог"
    done

    for path in         /usr/local/sbin/pve-configuration-status         /usr/local/sbin/deploy-guest         /usr/local/sbin/sync-management-keys         /root/.ssh/github_proxmox_repo_ed25519         /root/.ssh/github_proxmox_repo_ed25519.pub         /root/.ssh/github_known_hosts         /root/.ssh/github_config         /var/lib/vz/snippets/debian13-template-builder-9000.yaml         /run/lock/proxmox-bootstrap.lock         /run/lock/proxmox-orchestration.lock
    do
        remove_path "$path" "удалить проектный файл"
    done
}

remove_debian13_cache() {
    local volume

    log "Удаление Debian 13 cache, чтобы bootstrap получил template заново"

    while IFS= read -r volume; do
        [[ -n "$volume" ]] || continue
        run "удалить LXC template $volume" pveam remove "$volume"
    done < <(
        pveam list local 2>/dev/null             | awk 'NR > 1 && $1 ~ /^local:vztmpl\/debian-13-standard_/ {print $1}'
    )

    remove_path /var/lib/vz/template/cache/debian13 "удалить старый Debian cloud-image cache"
}

verify_final_state() {
    local extra_guests extra_users extra_groups

    (( APPLY )) || return

    log "Итоговая проверка"

    qm config "$KEEP_VMID" >/dev/null 2>&1         || die "После очистки VM $KEEP_VMID исчезла"

    extra_guests="$(
        pvesh get /cluster/resources --type vm --output-format json             | jq -r --argjson keep "$KEEP_VMID"                 '[.[] | select((.vmid | tonumber) != $keep)] | length'
    )"
    [[ "$extra_guests" == "0" ]]         || die "После очистки остались другие VM/LXC: $extra_guests"

    extra_users="$(
        pveum user list --output-format json             | jq -r '[.[] | select(.userid != "root@pam")] | length'
    )"
    [[ "$extra_users" == "0" ]]         || warn "После очистки остались дополнительные PVE users: $extra_users"

    extra_groups="$(pveum group list --output-format json | jq -r 'length')"
    [[ "$extra_groups" == "0" ]]         || warn "После очистки остались PVE groups: $extra_groups"

    ok "Сохранена только QEMU VM $KEEP_VMID"
}

show_preserved_state() {
    log "Что сохраняется"

    cat <<EOF_KEEP
- QEMU VM $KEEP_VMID со всеми её дисками и настройками;
- vmbr0 и другая сеть PVE;
- local/local-lvm и storage.cfg;
- APT repositories;
- установленные системные пакеты;
- сам Proxmox VE.
EOF_KEEP
}

main() {
    parse_args "$@"
    require_pve_root

    if (( APPLY )); then
        warn "ЖЁСТКАЯ ОЧИСТКА: все VM/LXC кроме VM $KEEP_VMID будут безвозвратно удалены."
    else
        info "Режим просмотра. Изменений не будет. Для очистки используйте --apply."
    fi

    remove_other_guests
    remove_project_access
    remove_managed_pool
    remove_linux_deployer
    remove_project_files
    remove_debian13_cache
    show_preserved_state
    verify_final_state

    printf '\n'
    if (( APPLY )); then
        ok "PVE очищен для нового запуска bootstrap. Сохранена только VM $KEEP_VMID."
    else
        ok "План полной очистки построен: действий=$CHANGES. Ничего не изменено."
    fi
}

main "$@"
