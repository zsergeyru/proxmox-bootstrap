#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# Public Bootstrap для Proxmox VE
# =============================================================================
# Первый запуск получает read-only доступ к private zsergeyru/proxmox и передаёт
# управление PVE Configuration. Повторный запуск обновляет canonical private
# checkout и снова запускает актуальную PVE Configuration.

PUBLIC_BOOTSTRAP_VERSION=7

PRIVATE_REPO="git@github.com:zsergeyru/proxmox.git"
PRIVATE_BRANCH="main"
DEPLOY_USER="pvedeploy"

BOOTSTRAP_TEMP_DIR="/var/lib/proxmox-bootstrap"
BOOTSTRAP_KEY_FILE="${BOOTSTRAP_TEMP_DIR}/github_proxmox_repo_ed25519"
BOOTSTRAP_KEY_PUB_FILE="${BOOTSTRAP_KEY_FILE}.pub"
BOOTSTRAP_KNOWN_HOSTS="${BOOTSTRAP_TEMP_DIR}/known_hosts"
BOOTSTRAP_SSH_CONFIG="${BOOTSTRAP_TEMP_DIR}/ssh_config"
TEMP_REPO="${BOOTSTRAP_TEMP_DIR}/private-repo"

PERMANENT_STATE_DIR="/var/lib/proxmox-deployer/state"
COMPLETE_MARKER="${PERMANENT_STATE_DIR}/bootstrap-complete"
PERMANENT_REPO="/var/lib/proxmox-deployer/repo"
PERMANENT_SSH_DIR="/etc/proxmox-deployer/ssh"
PERMANENT_KEY_FILE="${PERMANENT_SSH_DIR}/github_proxmox_repo_ed25519"
PERMANENT_KNOWN_HOSTS="${PERMANENT_SSH_DIR}/known_hosts"
PERMANENT_SSH_CONFIG="${PERMANENT_SSH_DIR}/config"
LOCK_FILE="/run/lock/proxmox-public-bootstrap.lock"
PVE_CONFIGURATION_CANONICAL="${PERMANENT_REPO}/scripts/pve/setup/configure-pve.sh"
PVE_CONFIGURATION_VERSION_FILE="${PERMANENT_REPO}/scripts/pve/setup/lib/00-common.sh"

FORWARD_ARGS=()

COLOR_ENABLED=0
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    COLOR_ENABLED=1
fi
if (( COLOR_ENABLED )); then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'; C_MAGENTA=$'\033[35m'
else
    C_RESET="" C_BOLD="" C_BLUE="" C_GREEN="" C_YELLOW="" C_RED="" C_CYAN="" C_MAGENTA=""
fi

log()  { printf '\n%s%s==> %s%s\n' "$C_BOLD" "$C_BLUE" "$*" "$C_RESET"; }
ok()   { printf '%s%s[ОК]%s %s\n' "$C_BOLD" "$C_GREEN" "$C_RESET" "$*"; }
info() { printf '%s%s[ИНФО]%s %s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$*"; }
warn() { printf '%s%s[ПРЕДУПРЕЖДЕНИЕ]%s %s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '\n%s%sОШИБКА:%s %s\n' "$C_BOLD" "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Использование:
  bootstrap-pve.sh [--update-system] [--help]

Public Bootstrap — публичная точка входа проекта Proxmox.

Первый запуск:
  - создаёт временный read-only GitHub Deploy Key;
  - получает private zsergeyru/proxmox;
  - запускает scripts/pve/setup/configure-pve.sh.

Повторный запуск или продолжение незавершённого первого запуска:
  - использует постоянный read-only Deploy Key, если permanent runtime уже готов;
  - обновляет /var/lib/proxmox-deployer/repo;
  - запускает актуальную PVE Configuration.

Параметры:
  --update-system  дополнительно запросить apt full-upgrade Proxmox/Debian
  -h, --help       показать эту справку
USAGE
}

while (($#)); do
    case "$1" in
        --update-system) FORWARD_ARGS+=("--update-system") ;;
        -h|--help) usage; exit 0 ;;
        *) die "Неизвестный параметр: $1" ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] || die "Запустите скрипт от root на хосте Proxmox"
command -v pveversion >/dev/null 2>&1 || die "Команда pveversion не найдена: этот скрипт нужно запускать на Proxmox VE"
pveversion >/dev/null
ok "Proxmox VE обнаружен"

acquire_bootstrap_lock() {
    command -v flock >/dev/null 2>&1 \
        || die "Не найдена команда flock; на штатном Proxmox VE она должна предоставляться util-linux"
    install -d -m 0755 /run/lock
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Другой экземпляр Public Bootstrap уже выполняется. Параллельный запуск запрещён."
    ok "Получена эксклюзивная блокировка Public Bootstrap"
}

ensure_minimal_packages() {
    local packages=(git openssh-client curl jq ca-certificates util-linux)
    local missing=0 cmd

    for cmd in git ssh ssh-keygen curl jq runuser; do
        command -v "$cmd" >/dev/null 2>&1 || missing=1
    done

    if (( ! missing )); then
        ok "Минимальный Git/SSH-набор уже установлен"
        return
    fi

    log "Установка минимального Git/SSH-набора"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"; then
        warn "Первая попытка установки пакетов не удалась; выполняется apt update без изменения repository policy"
        apt-get update || warn "apt update завершился с предупреждениями; выполняется повторная попытка установки"
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}" \
            || die "Не удалось установить минимальные пакеты. Исправьте доступность APT-репозиториев и повторите запуск."
    fi

    for cmd in git ssh ssh-keygen curl jq runuser; do
        command -v "$cmd" >/dev/null 2>&1 || die "После установки не найдена обязательная команда: $cmd"
    done
    ok "Минимальный Git/SSH-набор установлен"
}

check_github_connectivity() {
    log "Проверка доступности GitHub"
    command -v getent >/dev/null 2>&1 || die "Не найдена обязательная команда getent"
    getent ahosts github.com >/dev/null || die "Не работает DNS-разрешение github.com"
    getent ahosts api.github.com >/dev/null || die "Не работает DNS-разрешение api.github.com"
    curl -fsS --connect-timeout 10 --max-time 20 -o /dev/null https://github.com/ \
        || die "GitHub недоступен по HTTPS с этого Proxmox host"
    curl -fsS --connect-timeout 10 --max-time 20 -o /dev/null https://api.github.com/meta \
        || die "GitHub API недоступен по HTTPS с этого Proxmox host"
    ok "DNS и HTTPS-доступ к GitHub работают"
}

prepare_bootstrap_temp_dir() {
    install -d -o root -g root -m 0700 "$BOOTSTRAP_TEMP_DIR"
}

prepare_github_key() {
    log "Подготовка временного read-only Deploy Key для private repo"

    if [[ ! -f "$BOOTSTRAP_KEY_FILE" ]]; then
        ssh-keygen -q -t ed25519 -N '' \
            -C 'pve-public-bootstrap-readonly-zsergeyru-proxmox' \
            -f "$BOOTSTRAP_KEY_FILE"
        ok "Создан новый временный Deploy Key"
    else
        ok "Используется существующий временный Deploy Key"
    fi
    chmod 0600 "$BOOTSTRAP_KEY_FILE"

    local tmp_pub derived_pub tmp_hosts
    tmp_pub="$(mktemp "${BOOTSTRAP_TEMP_DIR}/.deploy-key-pub.XXXXXX")"
    derived_pub="$(ssh-keygen -y -f "$BOOTSTRAP_KEY_FILE")" \
        || { rm -f "$tmp_pub"; die "Не удалось прочитать существующий Deploy Key: ${BOOTSTRAP_KEY_FILE}"; }
    [[ -n "$derived_pub" ]] \
        || { rm -f "$tmp_pub"; die "Из private Deploy Key не удалось получить public key"; }
    printf '%s %s\n' "$derived_pub" 'pve-public-bootstrap-readonly-zsergeyru-proxmox' >"$tmp_pub"
    install -o root -g root -m 0644 "$tmp_pub" "$BOOTSTRAP_KEY_PUB_FILE"
    rm -f "$tmp_pub"

    tmp_hosts="$(mktemp "${BOOTSTRAP_TEMP_DIR}/.known-hosts.XXXXXX")"
    curl -fsSL --connect-timeout 10 --max-time 20 https://api.github.com/meta \
        | jq -r '.ssh_keys[] | "github.com " + .' >"$tmp_hosts"
    [[ -s "$tmp_hosts" ]] || { rm -f "$tmp_hosts"; die "Не удалось получить SSH host keys GitHub через api.github.com/meta"; }
    install -o root -g root -m 0644 "$tmp_hosts" "$BOOTSTRAP_KNOWN_HOSTS"
    rm -f "$tmp_hosts"

    cat >"$BOOTSTRAP_SSH_CONFIG" <<EOF_SSH
Host github.com
    HostName github.com
    User git
    IdentityFile ${BOOTSTRAP_KEY_FILE}
    IdentitiesOnly yes
    UserKnownHostsFile ${BOOTSTRAP_KNOWN_HOSTS}
    StrictHostKeyChecking yes
    BatchMode yes
    ConnectTimeout 10
EOF_SSH
    chmod 0600 "$BOOTSTRAP_SSH_CONFIG"
}

git_bootstrap() {
    env GIT_SSH_COMMAND="ssh -F ${BOOTSTRAP_SSH_CONFIG}" git "$@"
}

private_branch_accessible() {
    local out
    if ! out="$(git_bootstrap ls-remote "$PRIVATE_REPO" "refs/heads/${PRIVATE_BRANCH}" 2>/dev/null)"; then
        return 1
    fi
    [[ -n "$out" ]] || die "Private repo доступен, но ожидаемая ветка ${PRIVATE_BRANCH} отсутствует."
}

show_deploy_key_instructions() {
    printf '\n%s%sОЖИДАНИЕ АВТОРИЗАЦИИ GITHUB%s\n\n' "$C_BOLD" "$C_MAGENTA" "$C_RESET"
    printf 'Добавьте следующий публичный ключ в private repo zsergeyru/proxmox:\n\n'
    cat "$BOOTSTRAP_KEY_PUB_FILE"
    printf '\nПуть: GitHub -> zsergeyru/proxmox -> Settings -> Deploy keys -> Add deploy key\n'
    printf 'Allow write access: ВЫКЛЮЧЕН\n'
    printf '\nПосле добавления ключа вернитесь в этот терминал.\n'
}

ensure_private_repo_authorized() {
    if private_branch_accessible; then
        ok "Read-only доступ к private repo и ветке ${PRIVATE_BRANCH} уже подтверждён"
        return
    fi

    show_deploy_key_instructions
    [[ -r /dev/tty ]] \
        || die "Deploy Key ещё не авторизован, а интерактивный терминал недоступен. Добавьте показанный public key в GitHub и повторите bootstrap-pve.sh."

    printf 'Нажмите Enter после добавления Deploy Key в GitHub...' >/dev/tty
    IFS= read -r _ </dev/tty || die "Не удалось дождаться подтверждения через терминал"
    printf '\n' >/dev/tty

    check_github_connectivity
    private_branch_accessible \
        || die "Read-only доступ к ${PRIVATE_REPO}, ветка ${PRIVATE_BRANCH}, по-прежнему отсутствует. Проверьте Deploy Key и повторите bootstrap-pve.sh."
    ok "Read-only доступ к private repo подтверждён"
}

sync_temporary_private_repo() {
    log "Получение private PVE Configuration"

    if [[ ! -d "$TEMP_REPO/.git" ]]; then
        rm -rf "$TEMP_REPO"
        git_bootstrap clone --depth 1 --branch "$PRIVATE_BRANCH" "$PRIVATE_REPO" "$TEMP_REPO"
    else
        local origin_url
        origin_url="$(git_bootstrap -C "$TEMP_REPO" remote get-url origin 2>/dev/null || true)"
        [[ "$origin_url" == "$PRIVATE_REPO" ]] \
            || die "Временный checkout ${TEMP_REPO} имеет неожиданный origin '${origin_url:-не задан}'. Автоматическая подмена origin запрещена."
        git_bootstrap -C "$TEMP_REPO" fetch --depth 1 origin "$PRIVATE_BRANCH"
        git_bootstrap -C "$TEMP_REPO" reset --hard FETCH_HEAD
        git_bootstrap -C "$TEMP_REPO" clean -ffd
    fi

    ok "Private repo получен shallow clone глубиной 1 commit"
}

handoff_to_pve_configuration() {
    local configure="${TEMP_REPO}/scripts/pve/setup/configure-pve.sh"
    local revision
    [[ -f "$configure" ]] || die "В private repo не найден scripts/pve/setup/configure-pve.sh"
    revision="$(git_bootstrap -C "$TEMP_REPO" rev-parse HEAD)"

    log "Передача управления PVE Configuration revision=${revision}"
    PVE_BOOTSTRAP_TEMP_DIR="$BOOTSTRAP_TEMP_DIR" \
    PVE_BOOTSTRAP_KEY_FILE="$BOOTSTRAP_KEY_FILE" \
    PVE_BOOTSTRAP_KNOWN_HOSTS="$BOOTSTRAP_KNOWN_HOSTS" \
    PVE_CONFIGURATION_SOURCE_REVISION="$revision" \
        bash "$configure" "${FORWARD_ARGS[@]}"
}

permanent_git() {
    runuser -u "$DEPLOY_USER" -- \
        env GIT_SSH_COMMAND="ssh -F ${PERMANENT_SSH_CONFIG}" git "$@"
}

permanent_runtime_ready_for_refresh() {
    id "$DEPLOY_USER" >/dev/null 2>&1 \
        && [[ -f "$PERMANENT_KEY_FILE" ]] \
        && [[ -f "$PERMANENT_KNOWN_HOSTS" ]] \
        && [[ -f "$PERMANENT_SSH_CONFIG" ]] \
        && [[ -d "$PERMANENT_REPO/.git" ]]
}

refresh_permanent_repo_and_handoff() {
    log "Обновление canonical private checkout"

    ensure_minimal_packages
    check_github_connectivity

    id "$DEPLOY_USER" >/dev/null 2>&1 \
        || die "Linux-пользователь ${DEPLOY_USER} отсутствует. Восстановите PVE Configuration runtime."
    [[ -f "$PERMANENT_KEY_FILE" ]] || die "Постоянный Deploy Key ${PERMANENT_KEY_FILE} отсутствует. Автоматическая ротация запрещена."
    [[ -f "$PERMANENT_KNOWN_HOSTS" ]] || die "Отсутствует ${PERMANENT_KNOWN_HOSTS}. Восстановите canonical SSH runtime."
    [[ -f "$PERMANENT_SSH_CONFIG" ]] || die "Отсутствует ${PERMANENT_SSH_CONFIG}. Восстановите canonical SSH runtime."
    [[ -d "$PERMANENT_REPO/.git" ]] || die "Canonical checkout ${PERMANENT_REPO} отсутствует или не является Git repository."

    local origin_url refs revision configuration_version
    origin_url="$(permanent_git -C "$PERMANENT_REPO" remote get-url origin 2>/dev/null || true)"
    [[ "$origin_url" == "$PRIVATE_REPO" ]] \
        || die "Canonical checkout ${PERMANENT_REPO} имеет неожиданный origin '${origin_url:-не задан}'. Ожидается '${PRIVATE_REPO}'."

    refs="$(permanent_git ls-remote "$PRIVATE_REPO" "refs/heads/${PRIVATE_BRANCH}" 2>/dev/null || true)"
    [[ -n "$refs" ]] || die "Постоянный Deploy Key не даёт read-only доступ к ${PRIVATE_REPO}/${PRIVATE_BRANCH}."

    permanent_git -C "$PERMANENT_REPO" fetch --depth 1 origin "$PRIVATE_BRANCH" \
        || die "Не удалось получить актуальную ветку ${PRIVATE_BRANCH} private repo"
    permanent_git -C "$PERMANENT_REPO" reset --hard FETCH_HEAD \
        || die "Не удалось переключить canonical checkout на полученную ${PRIVATE_BRANCH}"
    permanent_git -C "$PERMANENT_REPO" clean -ffd \
        || die "Не удалось очистить canonical checkout от неотслеживаемых файлов"

    revision="$(permanent_git -C "$PERMANENT_REPO" rev-parse HEAD)"
    [[ -f "$PVE_CONFIGURATION_CANONICAL" ]] || die "После обновления private repo не найден ${PVE_CONFIGURATION_CANONICAL}"

    configuration_version="$(sed -n 's/^PVE_CONFIGURATION_VERSION=//p' "$PVE_CONFIGURATION_VERSION_FILE" | head -n1)"
    ok "Canonical private repo обновлён: ${revision}"
    [[ -n "$configuration_version" ]] && ok "Будет запущена PVE Configuration version=${configuration_version}"

    log "Запуск актуальной PVE Configuration revision=${revision}"
    PVE_CONFIGURATION_SOURCE_REVISION="$revision" \
        bash "$PVE_CONFIGURATION_CANONICAL" "${FORWARD_ARGS[@]}"
}

write_complete_marker() {
    local revision=$1 now marker_tmp
    now="$(date --iso-8601=seconds)"
    install -d -m 0750 "$PERMANENT_STATE_DIR"
    marker_tmp="${PERMANENT_STATE_DIR}/.bootstrap-complete.$$.tmp"
    cat >"$marker_tmp" <<EOF_MARKER
bootstrap=complete
public_bootstrap_version=${PUBLIC_BOOTSTRAP_VERSION}
timestamp=${now}
private_revision=${revision}
EOF_MARKER
    chmod 0600 "$marker_tmp"
    mv -f "$marker_tmp" "$COMPLETE_MARKER"
    chmod 0600 "$COMPLETE_MARKER"
}

finalize_bootstrap() {
    local revision
    [[ -d "$PERMANENT_STATE_DIR" ]] \
        || die "PVE Configuration завершилась, но постоянный state-каталог ${PERMANENT_STATE_DIR} не найден; temporary bootstrap сохранён для диагностики"
    permanent_runtime_ready_for_refresh \
        || die "PVE Configuration завершилась, но canonical permanent runtime неполон; temporary bootstrap сохранён для диагностики"

    revision="$(permanent_git -C "$PERMANENT_REPO" rev-parse HEAD 2>/dev/null || true)"
    [[ "$revision" =~ ^[0-9a-f]{40}$ ]] \
        || die "Не удалось определить final revision canonical private checkout"

    rm -rf "$BOOTSTRAP_TEMP_DIR"
    [[ ! -e "$BOOTSTRAP_TEMP_DIR" ]] || die "Не удалось полностью удалить temporary bootstrap ${BOOTSTRAP_TEMP_DIR}"
    write_complete_marker "$revision"
    ok "Public Bootstrap завершён; temporary runtime удалён, marker записан для revision ${revision}"
}

main() {
    local revision
    acquire_bootstrap_lock

    if [[ -f "$COMPLETE_MARKER" ]]; then
        info "Public Bootstrap уже выполнялся; будет обновлён private checkout"
        refresh_permanent_repo_and_handoff
        revision="$(permanent_git -C "$PERMANENT_REPO" rev-parse HEAD 2>/dev/null || true)"
        write_complete_marker "$revision"
        printf '\n%s%sPVE CONFIGURATION УСПЕШНО ЗАВЕРШЕНА%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
        exit 0
    fi

    if permanent_runtime_ready_for_refresh; then
        info "Bootstrap marker отсутствует, но canonical runtime уже готов. Продолжается незавершённый первый запуск без ротации credentials."
        refresh_permanent_repo_and_handoff
        finalize_bootstrap
        printf '\n%s%sPUBLIC BOOTSTRAP УСПЕШНО ВОЗОБНОВЛЁН И ЗАВЕРШЁН%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
        exit 0
    fi

    if [[ -d "$PERMANENT_REPO/.git" || -f "$PERMANENT_KEY_FILE" ]]; then
        info "Обнаружен частично созданный permanent runtime. Public Bootstrap продолжит первый запуск и не будет удалять или ротировать существующие credentials."
    fi

    prepare_bootstrap_temp_dir
    ensure_minimal_packages
    check_github_connectivity
    prepare_github_key
    ensure_private_repo_authorized
    sync_temporary_private_repo
    handoff_to_pve_configuration
    finalize_bootstrap

    printf '\n%s%sPUBLIC BOOTSTRAP УСПЕШНО ЗАВЕРШЁН%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
    printf 'Дальнейшее состояние PVE поддерживает private scripts/pve/setup/configure-pve.sh.\n'
    printf 'Для следующих запусков используйте ту же public bootstrap-pve.sh команду.\n'
}

main "$@"
