#!/usr/bin/env bash
set -Eeuo pipefail

PUBLIC_BOOTSTRAP_VERSION="5.0.0-dev1"

CTID=990
CT_HOSTNAME="bootstrap-runner"
CT_CORES=2
CT_MEMORY_MB=2048
CT_SWAP_MB=512
CT_DISK_GB=16
CT_STORAGE="local-lvm"
CT_BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"

PROJECT_REPO="git@github.com:zsergeyru/proxmox.git"
PROJECT_BRANCH="${PROJECT_BRANCH:-feature/bootstrap-990}"
PROJECT_DIR="/var/lib/bootstrap-runner/project"
PRIVATE_ENTRYPOINT="$PROJECT_DIR/scripts/bootstrap-runner/bootstrap-host.sh"

HOST_BOOTSTRAP_DIR="/root/.config/proxmox-bootstrap"
HOST_GITHUB_KEY="$HOST_BOOTSTRAP_DIR/github_proxmox_repo_ed25519"
HOST_GITHUB_PUB="$HOST_GITHUB_KEY.pub"
HOST_TEMPLATE_MARKER="$HOST_BOOTSTRAP_DIR/debian13-template.ref"
HOST_LOG_FILE="/var/log/proxmox-bootstrap.log"
LOCK_FILE="/run/lock/proxmox-bootstrap.lock"

CT_GITHUB_KEY="/root/.ssh/github_proxmox_repo_ed25519"
CT_GITHUB_CONFIG="/root/.ssh/github_config"
CT_GITHUB_KNOWN_HOSTS="/root/.ssh/github_known_hosts"

C_RESET=""
C_BOLD=""
C_GREEN=""
C_BLUE=""
C_RED=""
C_CYAN=""

if [[ "${NO_COLOR:-}" == "" && "${TERM:-}" != "dumb" ]]; then
    printf -v C_RESET '\033[0m'
    printf -v C_BOLD '\033[1m'
    printf -v C_GREEN '\033[32m'
    printf -v C_BLUE '\033[34m'
    printf -v C_RED '\033[31m'
    printf -v C_CYAN '\033[36m'
fi

log()  { printf '\n%s%s==> %s%s\n' "$C_BOLD" "$C_BLUE" "$*" "$C_RESET"; }
ok()   { printf '%s%s[ОК]%s %s\n' "$C_BOLD" "$C_GREEN" "$C_RESET" "$*"; }
info() { printf '%s%s[ИНФО]%s %s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$*"; }
die()  { printf '\n%s%sОШИБКА:%s %s\n' "$C_BOLD" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Использование:
  bootstrap-pve.sh [--check|--recover|--remove|--purge] [--project-branch NAME]

Публичный сценарий только создаёт временный LXC 990, даёт ему read-only
доступ к закрытому репозиторию и запускает закрытый bootstrap.

Параметры --check, --recover, --remove и --purge передаются закрытому bootstrap.
USAGE
}

FORWARD_ARGS=()

parse_args() {
    while (($#)); do
        case "$1" in
            --project-branch)
                shift
                (($#)) || die "после --project-branch требуется значение"
                PROJECT_BRANCH=$1
                ;;
            --check|--recover|--remove|--purge)
                FORWARD_ARGS+=("$1")
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "неизвестный параметр: $1"
                ;;
        esac
        shift
    done

    [[ "$PROJECT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] \
        || die "некорректное имя ветки проекта: $PROJECT_BRANCH"
    (("${#FORWARD_ARGS[@]}" <= 1)) || die "можно выбрать только один режим"
}

require_pve() {
    [[ $EUID -eq 0 ]] || die "сценарий должен выполняться от root на PVE"
    for command in pct pveam pvesm ssh-keygen ssh-keyscan flock; do
        command -v "$command" >/dev/null 2>&1 || die "не найден $command"
    done
}

acquire_lock() {
    install -d -m 0755 /run/lock
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "другой bootstrap уже выполняется"
}

init_log() {
    install -d -m 0755 "$(dirname "$HOST_LOG_FILE")"
    touch "$HOST_LOG_FILE"
    chmod 0600 "$HOST_LOG_FILE"
    printf '\n===== Public Bootstrap %s, %s =====\n' \
        "$PUBLIC_BOOTSTRAP_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')" >>"$HOST_LOG_FILE"
}

show_log_tail() {
    printf 'Последние строки технического журнала:\n' >&2
    tail -n 30 "$HOST_LOG_FILE" >&2 || true
    printf 'Полный журнал: %s\n' "$HOST_LOG_FILE" >&2
}

run_quiet() {
    local rc=0
    "$@" >>"$HOST_LOG_FILE" 2>&1 || rc=$?
    if ((rc != 0)); then
        show_log_tail
        return "$rc"
    fi
}

ct_exists() { pct config "$CTID" >/dev/null 2>&1; }
ct_exec() { pct exec "$CTID" -- "$@"; }
ct_run_quiet() { run_quiet pct exec "$CTID" -- "$@"; }

assert_owned_ct() {
    local config
    ct_exists || return 1
    config="$(pct config "$CTID")"
    grep -Fxq "hostname: $CT_HOSTNAME" <<<"$config" || return 1
    grep -Eq '^tags: .*bootstrap-runner' <<<"$config" || return 1
    grep -Eq '^description: .*managed-by=proxmox-bootstrap' <<<"$config" || return 1
}

ct_config_value() {
    local key=$1
    pct config "$CTID" | sed -n "s/^${key}: //p" | head -n1
}

verify_ct_contract() {
    local rootfs net0
    assert_owned_ct || die "LXC $CTID отсутствует или не принадлежит bootstrap"
    [[ "$(ct_config_value unprivileged)" == "1" ]] || die "LXC $CTID должен быть непривилегированным"
    [[ "$(ct_config_value cores)" == "$CT_CORES" ]] || die "LXC $CTID: неверное число CPU"
    [[ "$(ct_config_value memory)" == "$CT_MEMORY_MB" ]] || die "LXC $CTID: неверный объём памяти"
    [[ "$(ct_config_value swap)" == "$CT_SWAP_MB" ]] || die "LXC $CTID: неверный swap"
    [[ "$(ct_config_value onboot)" == "0" ]] || die "LXC $CTID не должен автоматически запускаться"

    rootfs="$(ct_config_value rootfs)"
    [[ "$rootfs" == "$CT_STORAGE:"* ]] || die "LXC $CTID: rootfs должен находиться в $CT_STORAGE"
    grep -q "size=${CT_DISK_GB}G" <<<"$rootfs" || die "LXC $CTID: неверный размер rootfs"

    net0="$(ct_config_value net0)"
    grep -q "bridge=$CT_BRIDGE" <<<"$net0" || die "LXC $CTID: неверный bridge"
}

find_local_template() {
    pvesm list "$TEMPLATE_STORAGE" --content vztmpl 2>/dev/null \
        | awk 'NR > 1 {print $1}' \
        | grep -E "^$TEMPLATE_STORAGE:vztmpl/debian-13-standard_.*_amd64\\.tar\\.(zst|gz)$" \
        | sort -V \
        | tail -n1
}

ensure_template() {
    local template_ref available
    template_ref="$(find_local_template || true)"
    if [[ -n "$template_ref" ]]; then
        printf '%s\n' "$template_ref"
        return
    fi

    info "Скачивается Debian 13 LXC-шаблон"
    run_quiet pveam update
    available="$(pveam available --section system \
        | awk '{print $2}' \
        | grep -E '^debian-13-standard_.*_amd64\\.tar\\.(zst|gz)$' \
        | sort -V \
        | tail -n1)"
    [[ -n "$available" ]] || die "не найден Debian 13 LXC-шаблон"

    run_quiet pveam download "$TEMPLATE_STORAGE" "$available"
    install -d -m 0700 "$HOST_BOOTSTRAP_DIR"
    printf '%s:vztmpl/%s\n' "$TEMPLATE_STORAGE" "$available" >"$HOST_TEMPLATE_MARKER"
    chmod 0600 "$HOST_TEMPLATE_MARKER"
    printf '%s:vztmpl/%s\n' "$TEMPLATE_STORAGE" "$available"
}

create_ct() {
    local template_ref=$1
    log "Создание временного LXC $CTID"

    run_quiet pct create "$CTID" "$template_ref" \
        --hostname "$CT_HOSTNAME" \
        --ostype debian \
        --unprivileged 1 \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY_MB" \
        --swap "$CT_SWAP_MB" \
        --rootfs "$CT_STORAGE:$CT_DISK_GB" \
        --net0 "name=eth0,bridge=$CT_BRIDGE,ip=dhcp,type=veth" \
        --features "nesting=1,keyctl=1" \
        --onboot 0 \
        --protection 0 \
        --tags "bootstrap-runner;proxmox-bootstrap" \
        --description "managed-by=proxmox-bootstrap role=bootstrap-runner temporary=true"

    ok "LXC $CTID создан"
}

ensure_ct() {
    local template_ref

    if ct_exists; then
        assert_owned_ct || die "VMID $CTID занят чужим объектом"
    else
        template_ref="$(ensure_template)"
        create_ct "$template_ref"
    fi
    verify_ct_contract
}

ensure_running() {
    if [[ "$(pct status "$CTID" | awk '{print $2}')" != "running" ]]; then
        run_quiet pct start "$CTID"
    fi

    for _ in $(seq 1 60); do
        if ct_exec sh -c 'ip -4 route show default | grep -q "^default " && getent ahostsv4 github.com >/dev/null 2>&1'; then
            ok "Сеть LXC $CTID готова"
            return
        fi
        sleep 2
    done
    die "сеть LXC $CTID не готова"
}

ensure_host_github_key() {
    install -d -m 0700 "$HOST_BOOTSTRAP_DIR"

    if [[ ! -s "$HOST_GITHUB_KEY" ]]; then
        ssh-keygen -q -t ed25519 -N '' \
            -C infra-manager-readonly-zsergeyru-proxmox \
            -f "$HOST_GITHUB_KEY"
        info "Создан Deploy Key. Добавьте открытый ключ в GitHub:"
        cat "$HOST_GITHUB_PUB"
    fi

    ssh-keygen -y -f "$HOST_GITHUB_KEY" >/dev/null 2>&1 \
        || die "повреждён GitHub Deploy Key: $HOST_GITHUB_KEY"
}

prepare_git_access() {
    local known_hosts

    ensure_host_github_key
    ct_exec install -d -m 0700 /root/.ssh
    pct push "$CTID" "$HOST_GITHUB_KEY" "$CT_GITHUB_KEY" \
        --user 0 --group 0 --perms 0600

    known_hosts="$(mktemp /run/bootstrap-runner-known-hosts.XXXXXX)"
    ssh-keyscan -t ed25519 github.com >"$known_hosts" 2>/dev/null
    pct push "$CTID" "$known_hosts" "$CT_GITHUB_KNOWN_HOSTS" \
        --user 0 --group 0 --perms 0644
    rm -f "$known_hosts"

    ct_exec sh -c 'cat >"$1" <<EOF
Host github.com
    HostName github.com
    User git
    IdentityFile /root/.ssh/github_proxmox_repo_ed25519
    IdentitiesOnly yes
    UserKnownHostsFile /root/.ssh/github_known_hosts
    StrictHostKeyChecking yes
EOF
chmod 0600 "$1"
' sh "$CT_GITHUB_CONFIG"
}

prepare_git() {
    log "Подготовка доступа к закрытому проекту"

    ct_run_quiet env LANG=C.UTF-8 LC_ALL=C.UTF-8 apt-get update
    ct_run_quiet env LANG=C.UTF-8 LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends ca-certificates git openssh-client

    prepare_git_access
}

checkout_project() {
    local git_ssh="ssh -F $CT_GITHUB_CONFIG"

    if ct_exec test -d "$PROJECT_DIR/.git"; then
        ct_run_quiet env GIT_SSH_COMMAND="$git_ssh" \
            git -C "$PROJECT_DIR" fetch origin "$PROJECT_BRANCH"
        ct_run_quiet git -C "$PROJECT_DIR" checkout -B "$PROJECT_BRANCH" "origin/$PROJECT_BRANCH"
    else
        ct_exec install -d -m 0755 "$(dirname "$PROJECT_DIR")"
        ct_run_quiet env GIT_SSH_COMMAND="$git_ssh" \
            git clone --branch "$PROJECT_BRANCH" --single-branch \
            "$PROJECT_REPO" "$PROJECT_DIR"
    fi

    ct_exec test -s "$PRIVATE_ENTRYPOINT" \
        || die "в закрытом проекте отсутствует private entrypoint"

    ok "Закрытый проект получен внутри LXC $CTID"
}

run_private_bootstrap() {
    local helper
    helper="$(mktemp /run/proxmox-private-bootstrap.XXXXXX)"
    trap 'rm -f "$helper"' RETURN

    pct pull "$CTID" "$PRIVATE_ENTRYPOINT" "$helper"
    chmod 0700 "$helper"

    log "Передача управления закрытому bootstrap"

    env \
        PROJECT_BRANCH="$PROJECT_BRANCH" \
        PROJECT_DIR="$PROJECT_DIR" \
        BOOTSTRAP_RUNNER_CTID="$CTID" \
        HOST_BOOTSTRAP_DIR="$HOST_BOOTSTRAP_DIR" \
        HOST_GITHUB_KEY="$HOST_GITHUB_KEY" \
        HOST_TEMPLATE_MARKER="$HOST_TEMPLATE_MARKER" \
        HOST_LOG_FILE="$HOST_LOG_FILE" \
        bash "$helper" "${FORWARD_ARGS[@]}"
}

main() {
    parse_args "$@"
    require_pve
    acquire_lock
    init_log

    info "Public Bootstrap $PUBLIC_BOOTSTRAP_VERSION"

    ensure_ct
    ensure_running
    prepare_git
    checkout_project
    run_private_bootstrap
}

main "$@"
