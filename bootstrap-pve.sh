#!/usr/bin/env bash
set -Eeuo pipefail

PUBLIC_BOOTSTRAP_VERSION="4.0.0-dev1"
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
HOST_TEMPLATE_MARKER="$HOST_BOOTSTRAP_DIR/debian13-template.ref"
LOCK_FILE="/run/lock/proxmox-bootstrap.lock"

CT_GITHUB_KEY="/root/.ssh/github_proxmox_repo_ed25519"
CT_GITHUB_CONFIG="/root/.ssh/github_config"
CT_GITHUB_KNOWN_HOSTS="/root/.ssh/github_known_hosts"

INFRA_CTID=910
INFRA_HOSTNAME="infra-manager"
INFRA_PROJECT_DIR="/var/lib/infra-manager/bootstrap-repo"
INFRA_GITHUB_KEY="/root/.ssh/github_proxmox_repo_ed25519"
INFRA_GITHUB_CONFIG="/root/.ssh/github_config"
INFRA_GITHUB_KNOWN_HOSTS="/root/.ssh/github_known_hosts"
INFRA_STAGING_SECRET="/root/.infra-manager-bootstrap/pve-api.env"

MODE="apply"

die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
ok() { printf '[ОК] %s\n' "$*"; }
info() { printf '[ИНФО] %s\n' "$*"; }

usage() {
    cat <<'USAGE'
Использование:
  bootstrap-pve.sh [--check|--recover|--remove|--purge] [--project-branch NAME]

Режимы:
  без параметров           создать 910 через временный 990 либо обновить существующий 910
  --check                  проверить готовность 910 и отсутствие временного контура
  --recover                восстановить постоянный PVE API credential и повторно применить provision.yaml
  --remove                 удалить 910 и временный контур, сохранив GitHub Deploy Key
  --purge                  то же самое и удалить постоянный GitHub Deploy Key

Проект:
  --project-branch NAME    ветка закрытого проекта; в текущей ветке по умолчанию feature/bootstrap-990
USAGE
}

parse_args() {
    while (($#)); do
        case "$1" in
            --check)
                [[ "$MODE" == "apply" ]] || die "можно выбрать только один режим"
                MODE="check"
                ;;
            --recover)
                [[ "$MODE" == "apply" ]] || die "можно выбрать только один режим"
                MODE="recover"
                ;;
            --remove)
                [[ "$MODE" == "apply" ]] || die "можно выбрать только один режим"
                MODE="remove"
                ;;
            --purge)
                [[ "$MODE" == "apply" ]] || die "можно выбрать только один режим"
                MODE="purge"
                ;;
            --project-branch)
                shift
                (($#)) || die "после --project-branch требуется значение"
                PROJECT_BRANCH=$1
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
    [[ "$PROJECT_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]]         || die "некорректное имя ветки проекта: $PROJECT_BRANCH"
}


require_pve() {
    [[ $EUID -eq 0 ]] || die "сценарий должен выполняться от root на PVE"
    for command in pct pveam pvesm pveum pvesh ssh-keygen ssh-keyscan git perl flock; do
        command -v "$command" >/dev/null 2>&1 || die "не найден $command"
    done
}

acquire_lock() {
    install -d -m 0755 /run/lock
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "другой bootstrap уже выполняется"
    ok "Получена блокировка bootstrap"
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
    install -d -m 0700 "$HOST_BOOTSTRAP_DIR"
    printf '%s:vztmpl/%s\n' "$TEMPLATE_STORAGE" "$available" >"$HOST_TEMPLATE_MARKER"
    chmod 0600 "$HOST_TEMPLATE_MARKER"
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

create_infra_manager_infrastructure() {
    ct_exec env INFRA_PROJECT_BRANCH="$PROJECT_BRANCH"         bash "$PROJECT_DIR/scripts/bootstrap-runner/deploy-910.sh"         infrastructure "$PROJECT_DIR"
    ok "LXC 910 создан через отдельное состояние 990"
}

prepare_infra_manager_base() {
    ct_exec env INFRA_PROJECT_BRANCH="$PROJECT_BRANCH"         bash "$PROJECT_DIR/scripts/bootstrap-runner/deploy-910.sh"         base "$PROJECT_DIR"
    ok "Базовые пакеты 910 установлены общим Ansible"
}

provision_infra_manager() {
    ct_exec env INFRA_PROJECT_BRANCH="$PROJECT_BRANCH"         bash "$PROJECT_DIR/scripts/bootstrap-runner/deploy-910.sh"         provision "$PROJECT_DIR"
    ok "provision.yaml 910 полностью применён через общий Ansible"
}

provision_existing_infra_manager() {
    ct_exec env INFRA_PROJECT_BRANCH="$PROJECT_BRANCH"         bash "$PROJECT_DIR/scripts/bootstrap-runner/deploy-910.sh"         existing "$PROJECT_DIR"
    ok "Существующий 910 обновлён общим Ansible без временного OpenTofu state"
}


infra_exec() {
    pct exec "$INFRA_CTID" -- "$@"
}

infra_manager_exists() {
    pct config "$INFRA_CTID" >/dev/null 2>&1
}

ensure_existing_infra_manager_running() {
    local config status
    infra_manager_exists || return 1
    config="$(pct config "$INFRA_CTID")"
    grep -Fxq "hostname: $INFRA_HOSTNAME" <<<"$config"         || die "VMID $INFRA_CTID занят чужим LXC"
    status="$(pct status "$INFRA_CTID" | awk '{print $2}')"
    if [[ "$status" != "running" ]]; then
        pct start "$INFRA_CTID"
    fi
}

verify_infra_manager_object() {
    local config status

    pct config "$INFRA_CTID" >/dev/null 2>&1         || die "LXC $INFRA_CTID отсутствует после deploy-guest"

    config="$(pct config "$INFRA_CTID")"
    grep -Fxq "hostname: $INFRA_HOSTNAME" <<<"$config"         || die "VMID $INFRA_CTID не является ожидаемым infra-manager"

    status="$(pct status "$INFRA_CTID" | awk '{print $2}')"
    [[ "$status" == "running" ]]         || die "LXC $INFRA_CTID должен быть запущен перед передачей управления"
}

prepare_infra_manager_pve_access() {
    local access_mode="${1:-apply}" helper

    verify_infra_manager_object

    helper="$(mktemp /run/infra-manager-pve-access.XXXXXX)"
    pct pull "$CTID" "$PROJECT_DIR/scripts/infra-manager/pve-bootstrap-access.sh" "$helper"
    chmod 0700 "$helper"

    INFRA_MANAGER_CTID="$INFRA_CTID"     INFRA_MANAGER_MODE="$access_mode"     INFRA_MANAGER_SECRET_FILE="$INFRA_STAGING_SECRET"         "$helper"

    rm -f "$helper"

    infra_exec test -s "$INFRA_STAGING_SECRET"         || die "Постоянный PVE API credential не передан в 910"

    ok "Постоянный PVE API-доступ 910 подготовлен"
}

prepare_infra_manager_project_access() {
    local known_hosts

    verify_infra_manager_object
    infra_exec install -d -m 0700 /root/.ssh

    pct push "$INFRA_CTID" "$HOST_GITHUB_KEY" "$INFRA_GITHUB_KEY"         --user 0 --group 0 --perms 0600

    known_hosts="$(mktemp /run/infra-manager-known-hosts.XXXXXX)"
    ssh-keyscan -t ed25519 github.com >"$known_hosts" 2>/dev/null
    pct push "$INFRA_CTID" "$known_hosts" "$INFRA_GITHUB_KNOWN_HOSTS"         --user 0 --group 0 --perms 0644
    rm -f "$known_hosts"

    infra_exec sh -c 'cat >"$1" <<EOF
Host github.com
    HostName github.com
    User git
    IdentityFile /root/.ssh/github_proxmox_repo_ed25519
    IdentitiesOnly yes
    UserKnownHostsFile /root/.ssh/github_known_hosts
    StrictHostKeyChecking yes
    BatchMode yes
    ConnectTimeout 10
EOF
chmod 0600 "$1"
' sh "$INFRA_GITHUB_CONFIG"

    ok "Read-only GitHub-доступ передан в 910"
}

checkout_infra_manager_project() {
    local git_ssh="ssh -F $INFRA_GITHUB_CONFIG"

    if infra_exec test -d "$INFRA_PROJECT_DIR/.git"; then
        infra_exec env GIT_SSH_COMMAND="$git_ssh"             git -C "$INFRA_PROJECT_DIR" fetch --depth 1 origin "$PROJECT_BRANCH"
        infra_exec git -C "$INFRA_PROJECT_DIR" reset --hard FETCH_HEAD
        infra_exec git -C "$INFRA_PROJECT_DIR" clean -ffdx
    else
        infra_exec rm -rf "$INFRA_PROJECT_DIR"
        infra_exec install -d -m 0755 "$(dirname "$INFRA_PROJECT_DIR")"
        infra_exec env GIT_SSH_COMMAND="$git_ssh"             git clone --depth 1 --branch "$PROJECT_BRANCH"             "$PROJECT_REPO" "$INFRA_PROJECT_DIR"
    fi

    ok "Проект передан в постоянный LXC 910"
}

verify_infra_manager_ready() {
    verify_infra_manager_object
    infra_exec test -x /usr/local/sbin/infra-manager-status         || die "В 910 отсутствует infra-manager-status после общего Ansible"
    infra_exec env INFRA_PROJECT_BRANCH="$PROJECT_BRANCH"         /usr/local/sbin/infra-manager-status --full
    ok "910 infra-manager готов по полному текущему контракту"
}

verify_infra_manager_handoff() {
    verify_infra_manager_object

    if ! infra_exec test -s "$INFRA_STAGING_SECRET"         && ! infra_exec test -s /etc/infra-manager/secrets/pve-api.env; then
        die "В 910 отсутствует временный и постоянный PVE API credential"
    fi
    infra_exec test -s /usr/local/share/ca-certificates/pve-root-ca.crt         || die "В 910 отсутствует PVE CA"
    infra_exec test -s "$INFRA_GITHUB_KEY"         || die "В 910 отсутствует GitHub Deploy Key"
    infra_exec test -d "$INFRA_PROJECT_DIR/.git"         || die "В 910 отсутствует рабочая копия проекта"
    infra_exec test -s "$INFRA_PROJECT_DIR/infrastructure/guests/910-infra-manager/provision.yaml"         || die "В 910 отсутствует provision.yaml"
    infra_exec test -s "$INFRA_PROJECT_DIR/automation/ansible/playbooks/configure-guest.yml"         || die "В 910 отсутствует общий Ansible playbook"

    ok "Данные для общего Ansible-развёртывания 910 переданы"
}

verify_existing_infra_manager_handoff() {
    verify_infra_manager_object
    infra_exec test -s /etc/infra-manager/secrets/pve-api.env         || die "В существующем 910 отсутствует постоянный PVE API credential"
    infra_exec test -s /usr/local/share/ca-certificates/pve-root-ca.crt         || die "В существующем 910 отсутствует PVE CA"
    infra_exec test -d "$INFRA_PROJECT_DIR/.git"         || die "В существующем 910 отсутствует рабочая копия проекта"
    ok "Существующий 910 готов к повторному общему Ansible-развёртыванию"
}

handoff_existing_infra_manager() {
    prepare_infra_manager_project_access
    checkout_infra_manager_project
    verify_existing_infra_manager_handoff
}

handoff_infra_manager() {
    local access_mode="${1:-apply}"
    prepare_infra_manager_pve_access "$access_mode"
    prepare_infra_manager_project_access
    checkout_infra_manager_project
    verify_infra_manager_handoff
}

temporary_token_exists() {
    pveum user token list root@pam --output-format json 2>/dev/null         | perl -MJSON::PP -0777 -e '
            my $rows = decode_json(<STDIN>);
            exit((grep { (($_->{tokenid} // q{}) eq q{bootstrap-runner}) } @$rows) ? 0 : 1);
        '
}

remove_token_acls_by_id() {
    local token_id=$1 entry path role
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        path=${entry%%|*}
        role=${entry#*|}
        pveum acl delete "$path" --tokens "$token_id" --roles "$role" || true
    done < <(
        pveum acl list --output-format json             | perl -MJSON::PP -0777 -e '
                my $token = shift;
                my $rows = decode_json(<STDIN>);
                for my $row (@$rows) {
                    next unless (($row->{type} // q{}) eq q{token});
                    next unless (($row->{ugid} // q{}) eq $token);
                    print(($row->{path} // q{}), q{|}, ($row->{roleid} // q{}), qq{\n});
                }
            ' "$token_id"
    )
}

remove_named_token() {
    local user=$1 token_name=$2 token_id
    token_id="$user!$token_name"
    remove_token_acls_by_id "$token_id"
    if pveum user token list "$user" --output-format json 2>/dev/null         | perl -MJSON::PP -0777 -e '
            my $token = shift;
            my $rows = decode_json(<STDIN>);
            exit((grep { (($_->{tokenid} // q{}) eq $token) } @$rows) ? 0 : 1);
        ' "$token_name"; then
        pveum user token remove "$user" "$token_name"
    fi
}

remove_private_access() {
    local helper
    if assert_owned_ct && ct_exec test -f "$PROJECT_DIR/scripts/bootstrap-runner/pve-access.sh"; then
        helper="$(mktemp /run/bootstrap-runner-pve-access-remove.XXXXXX)"
        pct pull "$CTID" "$PROJECT_DIR/scripts/bootstrap-runner/pve-access.sh" "$helper"
        chmod 0700 "$helper"
        BOOTSTRAP_RUNNER_MODE=remove BOOTSTRAP_RUNNER_CTID="$CTID" "$helper"
        rm -f "$helper"
    else
        remove_named_token "root@pam" "bootstrap-runner"
    fi
    temporary_token_exists && die "временный PVE API token 990 не удалён"
}

remove_downloaded_template() {
    local ref volume
    [[ -s "$HOST_TEMPLATE_MARKER" ]] || return 0
    ref="$(cat "$HOST_TEMPLATE_MARKER")"
    if pvesm path "$ref" >/dev/null 2>&1; then
        volume="${ref#*:}"
        pvesm free "$ref" >/dev/null 2>&1 || rm -f -- "$(pvesm path "$ref")"
        info "Удалён временно скачанный LXC-шаблон: $volume"
    fi
    rm -f "$HOST_TEMPLATE_MARKER"
}

finalize_bootstrap_runner() {
    assert_owned_ct || die "невозможно завершить bootstrap: LXC 990 отсутствует"
    ct_exec rm -rf /etc/bootstrap-runner/secrets /var/lib/bootstrap-runner/opentofu/state
    ct_exec test ! -e /etc/bootstrap-runner/secrets         || die "временные секреты 990 не удалены"
    ct_exec test ! -e /var/lib/bootstrap-runner/opentofu/state         || die "временное состояние OpenTofu 990 не удалено"

    remove_private_access

    if [[ "$(pct status "$CTID" | awk '{print $2}')" == "running" ]]; then
        pct stop "$CTID"
    fi
    pct destroy "$CTID" --purge 1
    ct_exists && die "LXC 990 не удалён"
    remove_downloaded_template
    ok "Временный контур 990 полностью удалён"
}

remove_bootstrap_runner_if_present() {
    if ct_exists; then
        assert_owned_ct || die "VMID 990 занят чужим объектом"
        remove_private_access
        if [[ "$(pct status "$CTID" | awk '{print $2}')" == "running" ]]; then
            pct stop "$CTID"
        fi
        pct destroy "$CTID" --purge 1
    else
        remove_named_token "root@pam" "bootstrap-runner"
    fi
    remove_downloaded_template
}

remove_infra_manager() {
    remove_bootstrap_runner_if_present
    if infra_manager_exists; then
        local config
        config="$(pct config "$INFRA_CTID")"
        grep -Fxq "hostname: $INFRA_HOSTNAME" <<<"$config"             || die "VMID $INFRA_CTID занят чужим объектом"
        remove_named_token "root@pam" "infra-manager"
        pct set "$INFRA_CTID" --protection 0 >/dev/null
        if [[ "$(pct status "$INFRA_CTID" | awk '{print $2}')" == "running" ]]; then
            pct stop "$INFRA_CTID"
        fi
        pct destroy "$INFRA_CTID" --purge 1
        ok "LXC 910 удалён"
    else
        remove_named_token "root@pam" "infra-manager"
        ok "LXC 910 уже отсутствует"
    fi
}

check_ready() {
    infra_manager_exists || die "LXC 910 отсутствует"
    verify_infra_manager_ready
    ct_exists && die "после успешного bootstrap временный LXC 990 не должен существовать"
    temporary_token_exists && die "после успешного bootstrap временный token 990 не должен существовать"
    ok "Постоянный 910 готов, временный контур отсутствует"
}

prepare_runner() {
    ensure_ct
    ensure_running
    prepare_base_os
    prepare_project_access
    checkout_project
    run_private_host_access
    prepare_runtime
}

apply() {
    local existed=0 runner_owns_910=0
    infra_manager_exists && existed=1

    prepare_runner

    if ct_exec test -s /var/lib/bootstrap-runner/opentofu/state/proxmox.tfstate; then
        runner_owns_910=1
    fi

    if ((existed && runner_owns_910)); then
        info "Найден незавершённый первоначальный контур; продолжается его state"
        ensure_existing_infra_manager_running
        create_infra_manager_infrastructure
        prepare_infra_manager_base
        if [[ "$MODE" == "recover" ]]; then
            handoff_infra_manager recover
        else
            handoff_infra_manager
        fi
        provision_infra_manager
    elif ((existed)); then
        ensure_existing_infra_manager_running
        if [[ "$MODE" == "recover" ]]; then
            prepare_infra_manager_pve_access recover
        fi
        handoff_existing_infra_manager
        provision_existing_infra_manager
    else
        create_infra_manager_infrastructure
        prepare_infra_manager_base
        if [[ "$MODE" == "recover" ]]; then
            handoff_infra_manager recover
        else
            handoff_infra_manager
        fi
        provision_infra_manager
    fi

    verify_infra_manager_ready
    finalize_bootstrap_runner
    check_ready
}

main() {
    parse_args "$@"
    require_pve
    acquire_lock
    info "Public Bootstrap $PUBLIC_BOOTSTRAP_VERSION, режим: $MODE"

    case "$MODE" in
        apply|recover)
            apply
            ;;
        check)
            check_ready
            ;;
        remove)
            remove_infra_manager
            ;;
        purge)
            remove_infra_manager
            rm -rf "$HOST_BOOTSTRAP_DIR"
            ok "Постоянный GitHub Deploy Key удалён"
            ;;
        *)
            die "неизвестный режим: $MODE"
            ;;
    esac
}

main "$@"
