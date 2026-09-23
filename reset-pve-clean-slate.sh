#!/usr/bin/env bash
set -Eeuo pipefail

# Полная очистка одиночного тестового PVE перед новым запуском bootstrap.
# Единственный сохраняемый гостевой объект — QEMU VM 100.
# По умолчанию только показывает план. Реальные изменения только с --apply.
#
# Не изменяются сеть и базовые PVE storage. Пакетный состав приводится
# максимально близко к исходной установке по журналу установщика.

KEEP_VMID=100
APPLY=0
CHANGES=0
INITIAL_STATUS_FILE=""

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
  - все пустые PVE pools;
  - старого pvedeploy и проектные файлы;
  - старые project backups;
  - Debian 13 LXC template/cache, чтобы bootstrap скачал его заново;
  - вручную установленные после исходной установки пакеты, если их удаление не ломает PVE;
  - изменения APT repositories, внесённые старой схемой;
  - добавленный старой схемой content type snippets в storage local.

Сохраняются:
  - VM 100;
  - сеть PVE;
  - сами storage local/local-lvm;
  - исходный пакетный состав установщика PVE, если его снимок сохранился;
  - при отсутствии снимка — штатное PVE плюс только то, что нельзя безопасно удалить;
  - сам Proxmox VE.
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

detect_initial_status() {
    if [[ -s /var/log/installer/status ]]; then
        INITIAL_STATUS_FILE="/var/log/installer/status"
        return
    fi

    if [[ -s /var/log/installer/initial-status.gz ]]; then
        INITIAL_STATUS_FILE="/var/log/installer/initial-status.gz"
        return
    fi

    INITIAL_STATUS_FILE=""
    warn "Исходный список пакетов установщика не найден. Пакетная очистка будет восстановлена по APT history: удаляем только пакеты из Install: наших транзакций."
}

initial_status_stream() {
    case "$INITIAL_STATUS_FILE" in
        *.gz) gzip -cd -- "$INITIAL_STATUS_FILE" ;;
        *) cat -- "$INITIAL_STATUS_FILE" ;;
    esac
}

initial_package_list() {
    [[ -n "$INITIAL_STATUS_FILE" ]] || return 0
    initial_status_stream | awk '$1 == "Package:" {print $2}' | sort -u
}


require_pve_root() {
    local cmd node_count name
    [[ $EUID -eq 0 ]] || die "Запустите скрипт от root на PVE"

    for cmd in pveversion pvesh pveum pct qm pveam jq getent apt-get apt-mark dpkg-query; do
        command -v "$cmd" >/dev/null 2>&1 || die "Не найдена обязательная команда до очистки: $cmd"
    done

    pveversion >/dev/null 2>&1 || die "Proxmox VE не обнаружен"

    detect_initial_status

    node_count="$(pvesh get /nodes --output-format json | jq 'length')"
    [[ "$node_count" == "1" ]] \
        || die "Полная очистка разрешена только на одиночном PVE. Обнаружено узлов: $node_count"

    pct config "$KEEP_VMID" >/dev/null 2>&1 \
        && die "VMID $KEEP_VMID занят LXC; ожидалась сохраняемая QEMU VM"

    qm config "$KEEP_VMID" >/dev/null 2>&1 \
        || die "Сохраняемая QEMU VM $KEEP_VMID отсутствует. Очистка остановлена."

    name="$(qm config "$KEEP_VMID" | awk -F ': ' '$1 == "name" {print $2; exit}')"
    ok "VM $KEEP_VMID будет сохранена${name:+ ($name)}"
    if [[ -n "$INITIAL_STATUS_FILE" ]]; then
        ok "Исходный пакетный состав найден: $INITIAL_STATUS_FILE"
    else
        warn "Точного снимка пакетов ISO нет; используем APT history и подтверждённые отличия первых запусков свежего PVE (git, jq, htop, mc, tmux)."
    fi
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

pve_role_exists() {
    local role=$1
    pveum role list --output-format json 2>/dev/null         | jq -e --arg role "$role" '.[] | select(.roleid == $role)' >/dev/null
}

remove_project_role() {
    local role=$1
    pve_role_exists "$role" || return 0
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

remove_empty_pools() {
    local poolid json members remaining_acls

    log "Удаление пустых PVE pools"

    while IFS= read -r poolid; do
        [[ -n "$poolid" ]] || continue

        json="$(pvesh get "/pools/$poolid" --output-format json)"
        members="$(jq -r '(.members // []) | length' <<<"$json")"

        if (( members > 0 )); then
            warn "Pool $poolid не пуст и сохранён:"
            jq -r '(.members // [])[] | "  - \(.type // "?") \(.vmid // "?") \(.name // "")"' <<<"$json" >&2
            continue
        fi

        remaining_acls="$(
            pveum acl list --output-format json                 | jq -r --arg path "/pool/$poolid"                     '[.[] | select(.path == $path)] | length'
        )"
        if (( remaining_acls > 0 && APPLY == 1 )); then
            warn "Pool $poolid имеет оставшиеся ACL после их удаления и сохранён."
            continue
        fi

        run "удалить пустой pool $poolid" pveum pool delete "$poolid"
    done < <(
        pvesh get /pools --output-format json | jq -r '.[].poolid'
    )
}

remove_linux_deployer() {
    local entry home shell

    getent passwd pvedeploy >/dev/null 2>&1 || return 0
    entry="$(getent passwd pvedeploy)"
    home="$(cut -d: -f6 <<<"$entry")"
    shell="$(cut -d: -f7 <<<"$entry")"

    if [[ "$home" != "/var/lib/pvedeploy" || "$shell" != "/bin/bash" ]]; then
        warn "Linux user pvedeploy имеет неожиданные параметры (home=$home shell=$shell) и оставлен."
        return
    fi

    run "удалить Linux user pvedeploy и его home" userdel -r pvedeploy

    if getent group pvedeploy >/dev/null 2>&1; then
        run "удалить оставшуюся группу pvedeploy" groupdel pvedeploy
    fi
}

remove_path() {
    local path=$1 description=$2
    [[ -e "$path" || -L "$path" ]] || return 0
    run "$description: $path" rm -rf -- "$path"
}

remove_project_files() {
    local path

    log "Удаление файлов и резервных копий проекта с PVE"

    for path in         /root/.config/proxmox-bootstrap         /etc/proxmox-deployer         /var/lib/proxmox-deployer         /var/lib/pvedeploy         /var/log/proxmox-deployer         /etc/infra-manager         /var/lib/infra-manager         /opt/infra-manager         /var/log/infra-manager         /etc/infra-deployer         /var/lib/infra-deployer         /opt/infra-deployer         /run/proxmox-bootstrap         /var/backups/proxmox-bootstrap         /var/backups/proxmox-configuration         /var/backups/proxmox-secrets
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

# BASH_REMATCH[1] ниже — элемент массива regex-match, а не позиционный параметр.
# shellcheck disable=SC2120
restore_project_apt_changes() {
    local active disabled ceph uri suite component release tmp

    log "Откат изменений APT repositories старой схемы"

    for active in \
        /etc/apt/sources.list.d/pve-enterprise.list \
        /etc/apt/sources.list.d/pve-enterprise.sources
    do
        disabled="${active}.disabled"
        [[ -f "$disabled" ]] || continue

        if [[ -e "$active" ]]; then
            warn "Не восстанавливаю $active: активный файл уже существует."
            continue
        fi

        run "восстановить исходный enterprise repository: $active" mv -- "$disabled" "$active"
    done

    # Старый PVE Configuration создавал этот no-subscription файл.
    # Удаляем его только если сохранённый enterprise-файл доказывает, что
    # старая схема действительно отключала enterprise repository.
    if [[ -f /etc/apt/sources.list.d/pve-enterprise.sources.disabled \
       || -f /etc/apt/sources.list.d/pve-enterprise.list.disabled \
       || -f /etc/apt/sources.list.d/pve-enterprise.sources \
          && -f /etc/apt/sources.list.d/proxmox.sources ]]
    then
        if [[ -f /etc/apt/sources.list.d/proxmox.sources ]] \
            && grep -Fxq 'URIs: http://download.proxmox.com/debian/pve' /etc/apt/sources.list.d/proxmox.sources \
            && grep -Fxq 'Suites: trixie' /etc/apt/sources.list.d/proxmox.sources \
            && grep -Fxq 'Components: pve-no-subscription' /etc/apt/sources.list.d/proxmox.sources
        then
            run "удалить созданный проектом PVE no-subscription repository" \
                rm -f /etc/apt/sources.list.d/proxmox.sources
        fi
    fi

    remove_path /etc/apt/sources.list.d/pve-no-subscription.sources \
        "удалить старый bootstrap no-subscription repository"

    # Ceph repository старая схема меняла на месте без отдельного backup.
    # Обратное преобразование выполняем только для точного шаблона PVE 9.
    ceph=/etc/apt/sources.list.d/ceph.sources
    if [[ -f "$ceph" ]]; then
        uri="$(sed -n 's/^URIs:[[:space:]]*//p' "$ceph" | head -n1)"
        suite="$(sed -n 's/^Suites:[[:space:]]*//p' "$ceph" | head -n1)"
        component="$(sed -n 's/^Components:[[:space:]]*//p' "$ceph" | head -n1)"

        if [[ "$uri" =~ ^https?://download\.proxmox\.com/debian/(ceph-[A-Za-z0-9._-]+)$ \
           && "$suite" == "trixie" \
           && "$component" == "no-subscription" ]]
        then
            release="${BASH_REMATCH[1]}"
            if (( APPLY )); then
                tmp="$(mktemp "${ceph}.reset.XXXXXX")"
                awk -v release="$release" '
                    /^URIs:[[:space:]]*https?:\/\/download\.proxmox\.com\/debian\/ceph-[A-Za-z0-9._-]+[[:space:]]*$/ {
                        print "URIs: https://enterprise.proxmox.com/debian/" release
                        next
                    }
                    /^Components:[[:space:]]*no-subscription[[:space:]]*$/ {
                        print "Components: enterprise"
                        next
                    }
                    { print }
                ' "$ceph" >"$tmp"

                grep -Fxq "URIs: https://enterprise.proxmox.com/debian/$release" "$tmp" \
                    || { rm -f "$tmp"; die "Не удалось восстановить URI enterprise Ceph repository"; }
                grep -Fxq "Components: enterprise" "$tmp" \
                    || { rm -f "$tmp"; die "Не удалось восстановить component enterprise Ceph repository"; }

                install -o root -g root -m 0644 "$tmp" "$ceph"
                rm -f "$tmp"
                printf '[УДАЛЕНИЕ] восстановить enterprise Ceph repository %s\n' "$release"
                CHANGES=$((CHANGES + 1))
            else
                CHANGES=$((CHANGES + 1))
                printf '[ПЛАН] восстановить enterprise Ceph repository %s\n' "$release"
            fi
        fi
    fi
}

cleanup_ceph_source_artifacts() {
    local path

    log "Удаление временных и резервных файлов Ceph repository"

    for path in \
        /etc/apt/sources.list.d/ceph.sources.reset.* \
        /etc/apt/sources.list.d/ceph.sources.tmp.* \
        /etc/apt/sources.list.d/ceph.sources.bak-* \
        /etc/apt/sources.list.d/ceph.sources.??????
    do
        [[ -e "$path" ]] || continue
        [[ "$path" != "/etc/apt/sources.list.d/ceph.sources" ]] || continue
        remove_path "$path" "удалить неактивный временный/резервный файл Ceph repository"
    done
}

restore_storage_defaults() {
    local content new_content

    log "Откат project content type storage local"

    content="$(pvesh get /storage/local --output-format json | jq -r '.content // ""')"
    if ! tr ',' '\n' <<<"$content" | grep -qx snippets; then
        return
    fi

    new_content="$(
        tr ',' '\n' <<<"$content" \
            | grep -vx snippets \
            | paste -sd, -
    )"
    [[ -n "$new_content" ]] || die "Нельзя оставить storage local без content types"

    run "убрать snippets из storage local (останется: $new_content)" \
        pvesm set local --content "$new_content"
}

apt_history_stream() {
    local file
    local -a files=()

    shopt -s nullglob
    files=(/var/log/apt/history.log /var/log/apt/history.log.*)
    shopt -u nullglob

    ((${#files[@]} > 0)) || return 0

    for file in "${files[@]}"; do
        case "$file" in
            *.gz) gzip -cd -- "$file" ;;
            *) cat -- "$file" ;;
        esac
        printf '\n'
    done
}

project_apt_installed_packages() {
    apt_history_stream | awk '
        function flush(    line, n, i, part, pkg) {
            if (!matched || installs == "") {
                commandline=""
                installs=""
                matched=0
                return
            }

            line=installs
            sub(/^Install:[[:space:]]*/, "", line)
            n=split(line, part, /,[[:space:]]*/)
            for (i=1; i<=n; i++) {
                pkg=part[i]
                sub(/[[:space:]].*$/, "", pkg)
                sub(/:[^:[:space:]]+$/, "", pkg)
                if (pkg != "") print pkg
            }

            commandline=""
            installs=""
            matched=0
        }

        /^Start-Date:/ {
            flush()
            next
        }

        /^Commandline:/ {
            commandline=$0

            if (commandline ~ /apt-get install/ &&
                commandline ~ /python3-jsonschema/ &&
                commandline ~ /smartmontools/ &&
                commandline ~ /lm-sensors/) {
                matched=1
            }

            if (commandline ~ /apt-get install/ &&
                commandline ~ /ca-certificates/ &&
                commandline ~ /curl/ &&
                commandline ~ /jq/ &&
                commandline ~ /util-linux/) {
                matched=1
            }

            if (commandline ~ /^Commandline:[[:space:]]+apt-get install -y --no-install-recommends jq[[:space:]]*$/) {
                matched=1
            }

            next
        }

        /^Install:/ {
            installs=$0
            next
        }

        /^End-Date:/ {
            flush()
            next
        }

        END {
            flush()
        }
    ' | sort -u
}

known_nonstock_packages() {
    cat <<'EOF_KNOWN'
git
jq
htop
mc
tmux
EOF_KNOWN
}

manual_extra_packages() {
    {
        if [[ -n "$INITIAL_STATUS_FILE" ]]; then
            comm -23 \
                <(apt-mark showmanual | sort -u) \
                <(initial_package_list)
        else
            project_apt_installed_packages
        fi

        # Подтверждено первыми запусками на свежем PVE 9.2.18:
        # git и jq устанавливались как NEW на Stage 0;
        # htop, mc и tmux — как NEW на следующем обязательном apt install.
        known_nonstock_packages
    } | sort -u
}

apt_simulation_removals() {
    apt-get -s "$@" 2>/dev/null \
        | awk '$1 == "Remv" {print $2}'
}

assert_no_protected_package_removal() {
    local action=$1
    shift
    local removals protected

    removals="$(apt_simulation_removals "$@")"

    protected="$(
        grep -E '^(proxmox-|pve-|libpve-|qemu-server$|openssh-server$|openssh-client$|apt$|dpkg$|systemd($|-)|ifupdown2$|lvm2$|thin-provisioning-tools$|grub-|initramfs-tools($|-)|bash$|coreutils$|libc6$|python3($|-)|util-linux$|curl$|ca-certificates$)' \
            <<<"$removals" || true
    )"

    if [[ -n "$protected" ]]; then
        warn "$action пропущено: APT собирается удалить базовые пакеты PVE/Debian:"
        sed 's/^/  - /' <<<"$protected" >&2
        return 1
    fi

    return 0
}

remove_non_initial_manual_packages() {
    local pkg
    local -a candidates=()
    local -a safe=()

    log "Очистка пакетов, добавленных после установки PVE"

    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] || continue
        dpkg-query -W -f='${db:Status-Status}\n' "$pkg" 2>/dev/null | grep -qx installed \
            || continue
        candidates+=("$pkg")
    done < <(manual_extra_packages)

    if (( ${#candidates[@]} == 0 )); then
        ok "Дополнительных вручную установленных пакетов нет"
    else
        if [[ -n "$INITIAL_STATUS_FILE" ]]; then
            info "Пакеты, которых не было в исходной установке: ${candidates[*]}"
        else
            info "Пакеты, определённые по APT history и подтверждённым первым запускам как добавленные проектом: ${candidates[*]}"
        fi

        for pkg in "${candidates[@]}"; do
            if assert_no_protected_package_removal "Удаление $pkg" purge -y "$pkg"; then
                safe+=("$pkg")
            else
                warn "Пакет $pkg оставлен как необходимый текущему PVE"
            fi
        done

        if (( ${#safe[@]} > 0 )); then
            if assert_no_protected_package_removal \
                "Общее удаление дополнительных пакетов" \
                purge -y "${safe[@]}"
            then
                if (( APPLY )); then
                    CHANGES=$((CHANGES + 1))
                    printf '[УДАЛЕНИЕ] apt purge: %s\n' "${safe[*]}"
                    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${safe[@]}"
                else
                    CHANGES=$((CHANGES + 1))
                    printf '[ПЛАН] apt purge: %s\n' "${safe[*]}"
                fi
            fi
        fi
    fi

    if assert_no_protected_package_removal "APT autoremove" autoremove --purge -y; then
        if (( APPLY )); then
            CHANGES=$((CHANGES + 1))
            printf '[УДАЛЕНИЕ] apt autoremove --purge\n'
            DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y
            apt-get clean
        else
            CHANGES=$((CHANGES + 1))
            printf '[ПЛАН] apt autoremove --purge\n'
            CHANGES=$((CHANGES + 1))
            printf '[ПЛАН] очистить APT package cache\n'
        fi
    fi
}

print_bootstrap_entrypoint() {
    local url="https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/infra-iac-redesign/bootstrap-pve.sh"

    log "Команда первого запуска bootstrap после очистки"

    command -v curl >/dev/null 2>&1 \
        || die "После очистки отсутствует штатный curl; состояние PVE не соответствует проверенному чистому PVE 9"

    printf 'curl -fsSL %s | bash\n' "$url"
}

verify_final_state() {
    local extra_guests extra_users extra_groups

    (( APPLY )) || return 0

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
- local/local-lvm как сами storage;
- только пакетный состав исходной установки PVE плюс пакеты, которые текущий PVE уже не может безопасно удалить;
- сам Proxmox VE.

Откатываются только подтверждённые изменения старого проекта:
- snippets удаляется из content types storage local;
- сохранённый enterprise repository восстанавливается из *.disabled;
- точный Ceph no-subscription шаблон возвращается к enterprise;
- при наличии снимка удаляются вручную добавленные после установки пакеты;
- без снимка используются записи Install: из /var/log/apt/history.log* и подтверждённые NEW-пакеты первых запусков свежего PVE: git, jq, htop, mc и tmux;
- любое удаление сначала проверяется APT-симуляцией на сохранность PVE.
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
    remove_empty_pools
    remove_linux_deployer
    remove_project_files
    remove_debian13_cache
    restore_storage_defaults
    restore_project_apt_changes
    cleanup_ceph_source_artifacts
    show_preserved_state
    verify_final_state
    remove_non_initial_manual_packages
    print_bootstrap_entrypoint

    printf '\n'
    if (( APPLY )); then
        ok "PVE очищен для нового запуска bootstrap. Сохранена только VM $KEEP_VMID."
    else
        ok "План полной очистки построен: действий=$CHANGES. Ничего не изменено."
    fi
}

main "$@"
