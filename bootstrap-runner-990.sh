#!/usr/bin/env bash
set -Eeuo pipefail

PUBLIC_BOOTSTRAP_RUNNER_VERSION="0.1.0-dev1"
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

HOST_BOOTSTRAP_DIR="/root/.config/proxmox-bootstrap"
HOST_GITHUB_KEY="$HOST_BOOTSTRAP_DIR/github_proxmox_repo_ed25519"
HOST_GITHUB_PUB="$HOST_GITHUB_KEY.pub"

CT_GITHUB_KEY="/root/.ssh/github_proxmox_repo_ed25519"
CT_GITHUB_CONFIG="/root/.ssh/github_config"
CT_GITHUB_KNOWN_HOSTS="/root/.ssh/github_known_hosts"
MODE="apply"

die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
ok() { printf '[ОК] %s\n' "$*"; }
info() { printf '[ИНФО] %s\n' "$*"; }

usage() {
    cat <<'USAGE'
Использование:
  bootstrap-runner-990.sh [--check|--remove] [--project-branch NAME]

Режимы:
  без параметров           создать и подготовить временный LXC 990
  --check                  проверить готовность 990
  --remove                 удалить временный доступ и LXC 990

Проект:
  --project-branch NAME    ветка проекта; по умолчанию feature/bootstrap-990
USAGE
}

parse_args() {
    while (($#)); do
        case "$1" in
            --check) MODE="check" ;;
            --remove) MODE="remove" ;;
            --project-branch)
                shift
                (($#)) || die "после --project-branch требуется значение"
                PROJECT_BRANCH=$1
                ;;
            -h|--help) usage; exit 0 ;;
            *) die "неизвестный параметр: $1" ;;
        esac
        shift
    done
}

require_pve() {
    [[ $EUID -eq 0 ]] || die "сценарий должен выполняться от root на PVE"
    for command in pct pveam pvesm ssh-keygen ssh-keyscan git; do
        command -v "$command" >/dev/null 2>&1 || die "не найден $command"
    done
}

ct_exists() { pct config "$CTID" >/dev/null 2>&1; }
ct_exec() { pct exec "$CTID" -- "$@"; }

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
    ok "Контракт LXC $CTID подтверждён"
}

find_local_template() {
    pvesm list "$TEMPLATE_STORAGE" --content vztmpl 2>/dev/null         | awk 'NR > 1 {print $1}'         | grep -E "^$TEMPLATE_STORAGE:vztmpl/debian-13-standard_.*_amd64\\.tar\\.(zst|gz)$"         | sort -V         | tail -n1
}

ensure_template() {
    local template_ref available
    template_ref="$(find_local_template || true)"
    if [[ -n "$template_ref" ]]; then
        printf '%s\n' "$template_ref"
        return
    fi

    info "Локальный Debian 13 LXC-шаблон не найден, обновляется список" >&2
    pveam update >/dev/null
    available="$(pveam available --section system | awk '{print $2}'         | grep -E '^debian-13-standard_.*_amd64\\.tar\\.(zst|gz)$'         | sort -V | tail -n1)"
    [[ -n "$available" ]] || die "не найден Debian 13 LXC-шаблон"
    pveam download "$TEMPLATE_STORAGE" "$available" >/dev/null
    printf '%s:vztmpl/%s\n' "$TEMPLATE_STORAGE" "$available"
}

create_ct() {
    local template_ref=$1
    pct create "$CTID" "$template_ref"         --hostname "$CT_HOSTNAME"         --ostype debian         --unprivileged 1         --cores "$CT_CORES"         --memory "$CT_MEMORY_MB"         --swap "$CT_SWAP_MB"         --rootfs "$CT_STORAGE:$CT_DISK_GB"         --net0 "name=eth0,bridge=$CT_BRIDGE,ip=dhcp,type=veth"         --features "nesting=1,keyctl=1"         --onboot 0         --protection 0         --tags "bootstrap-runner;proxmox-bootstrap"         --description "managed-by=proxmox-bootstrap role=bootstrap-runner temporary=true"
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
        pct start "$CTID"
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
        ssh-keygen -q -t ed25519 -N ''             -C infra-manager-readonly-zsergeyru-proxmox             -f "$HOST_GITHUB_KEY"
        info "Создан Deploy Key. Добавьте открытый ключ в GitHub:"
        cat "$HOST_GITHUB_PUB"
    fi
    ssh-keygen -y -f "$HOST_GITHUB_KEY" >/dev/null 2>&1         || die "повреждён GitHub Deploy Key: $HOST_GITHUB_KEY"
}

prepare_project_access() {
    local known_hosts
    ensure_host_github_key
    ct_exec install -d -m 0700 /root/.ssh
    pct push "$CTID" "$HOST_GITHUB_KEY" "$CT_GITHUB_KEY" --user 0 --group 0 --perms 0600

    known_hosts="$(mktemp /run/bootstrap-runner-known-hosts.XXXXXX)"
    ssh-keyscan -t ed25519 github.com >"$known_hosts" 2>/dev/null
    pct push "$CTID" "$known_hosts" "$CT_GITHUB_KNOWN_HOSTS" --user 0 --group 0 --perms 0644
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

prepare_base_os() {
    ct_exec apt-get update
    ct_exec env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends         ca-certificates git openssh-client
}

checkout_project() {
    local git_ssh="ssh -F $CT_GITHUB_CONFIG"
    if ct_exec test -d "$PROJECT_DIR/.git"; then
        ct_exec env GIT_SSH_COMMAND="$git_ssh" git -C "$PROJECT_DIR" fetch origin "$PROJECT_BRANCH"
        ct_exec git -C "$PROJECT_DIR" checkout -B "$PROJECT_BRANCH" "origin/$PROJECT_BRANCH"
    else
        ct_exec install -d -m 0755 "$(dirname "$PROJECT_DIR")"
        ct_exec env GIT_SSH_COMMAND="$git_ssh"             git clone --branch "$PROJECT_BRANCH" --single-branch "$PROJECT_REPO" "$PROJECT_DIR"
    fi
    ok "Проект получен внутри 990"
}

run_private_host_access() {
    local helper
    helper="$(mktemp /run/bootstrap-runner-pve-access.XXXXXX)"
    pct pull "$CTID" "$PROJECT_DIR/scripts/bootstrap-runner/pve-access.sh" "$helper"
    chmod 0700 "$helper"
    BOOTSTRAP_RUNNER_MODE=apply BOOTSTRAP_RUNNER_CTID="$CTID" "$helper"
    rm -f "$helper"
}

prepare_runtime() {
    ct_exec bash "$PROJECT_DIR/scripts/bootstrap-runner/prepare-runtime.sh" "$PROJECT_DIR"
}

verify_runtime() {
    ct_exec bash "$PROJECT_DIR/scripts/bootstrap-runner/run-runtime.sh" tofu version >/dev/null
    ct_exec bash "$PROJECT_DIR/scripts/bootstrap-runner/run-runtime.sh" ansible --version >/dev/null
    ok "OpenTofu и Ansible внутри 990 готовы"
}

check_ready() {
    verify_ct_contract
    [[ "$(pct status "$CTID" | awk '{print $2}')" == "running" ]] || die "LXC $CTID не запущен"
    ct_exec test -d "$PROJECT_DIR/.git" || die "проект внутри 990 отсутствует"
    ct_exec test -s /etc/bootstrap-runner/secrets/pve-api.env || die "временный PVE credential отсутствует"
    ct_exec docker image inspect bootstrap-runtime:v1 >/dev/null || die "образ bootstrap-runtime:v1 отсутствует"
    verify_runtime
    ok "990 bootstrap-runner готов"
}

remove_private_access() {
    local helper
    if ! assert_owned_ct || ! ct_exec test -f "$PROJECT_DIR/scripts/bootstrap-runner/pve-access.sh"; then
        return
    fi
    helper="$(mktemp /run/bootstrap-runner-pve-access-remove.XXXXXX)"
    pct pull "$CTID" "$PROJECT_DIR/scripts/bootstrap-runner/pve-access.sh" "$helper"
    chmod 0700 "$helper"
    BOOTSTRAP_RUNNER_MODE=remove BOOTSTRAP_RUNNER_CTID="$CTID" "$helper"
    rm -f "$helper"
}

remove_ct() {
    if ! ct_exists; then
        ok "LXC $CTID уже отсутствует"
        return
    fi
    assert_owned_ct || die "VMID $CTID занят чужим объектом"
    remove_private_access || true
    if [[ "$(pct status "$CTID" | awk '{print $2}')" == "running" ]]; then
        pct stop "$CTID"
    fi
    pct destroy "$CTID" --purge 1
    ok "LXC $CTID удалён"
}

apply() {
    ensure_ct
    ensure_running
    prepare_base_os
    prepare_project_access
    checkout_project
    run_private_host_access
    prepare_runtime
    check_ready
}

main() {
    parse_args "$@"
    require_pve
    info "bootstrap-runner $PUBLIC_BOOTSTRAP_RUNNER_VERSION, режим: $MODE"
    case "$MODE" in
        apply) apply ;;
        check) check_ready ;;
        remove) remove_ct ;;
        *) die "неизвестный режим: $MODE" ;;
    esac
}

main "$@"
