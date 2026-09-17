#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# Public Bootstrap для Proxmox VE
# =============================================================================
# Первый запуск сразу создаёт постоянный root-only read-only GitHub Deploy Key,
# получает private zsergeyru/proxmox и передаёт управление PVE Configuration.
# Повторный запуск использует тот же credential, обновляет canonical private
# checkout и снова запускает актуальную PVE Configuration.

PUBLIC_BOOTSTRAP_VERSION=12

PRIVATE_REPO="git@github.com:zsergeyru/proxmox.git"
PRIVATE_BRANCH="main"
DEPLOY_USER="pvedeploy"

BOOTSTRAP_TEMP_DIR="/var/lib/proxmox-bootstrap"
TEMP_REPO="${BOOTSTRAP_TEMP_DIR}/private-repo"

# Только для безопасного продолжения незавершённого запуска Public Bootstrap v11.
# v12 никогда не создаёт эти файлы и удаляет их после успешной миграции.
LEGACY_BOOTSTRAP_KEY_FILE="${BOOTSTRAP_TEMP_DIR}/github_proxmox_repo_ed25519"
LEGACY_BOOTSTRAP_KEY_PUB_FILE="${LEGACY_BOOTSTRAP_KEY_FILE}.pub"
LEGACY_BOOTSTRAP_KNOWN_HOSTS="${BOOTSTRAP_TEMP_DIR}/known_hosts"
LEGACY_BOOTSTRAP_SSH_CONFIG="${BOOTSTRAP_TEMP_DIR}/ssh_config"

PERMANENT_CONFIG_DIR="/etc/proxmox-deployer"
PERMANENT_SSH_DIR="${PERMANENT_CONFIG_DIR}/ssh"
PERMANENT_KEY_FILE="${PERMANENT_SSH_DIR}/github_proxmox_repo_ed25519"
PERMANENT_KEY_PUB_FILE="${PERMANENT_KEY_FILE}.pub"
PERMANENT_KNOWN_HOSTS="${PERMANENT_SSH_DIR}/known_hosts"
PERMANENT_SSH_CONFIG="${PERMANENT_SSH_DIR}/config"

PERMANENT_RUNTIME_DIR="/var/lib/proxmox-deployer"
PERMANENT_STATE_DIR="${PERMANENT_RUNTIME_DIR}/state"
COMPLETE_MARKER="${PERMANENT_STATE_DIR}/bootstrap-complete"
PERMANENT_REPO="${PERMANENT_RUNTIME_DIR}/repo"
LOCK_FILE="/run/lock/proxmox-orchestration.lock"
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

bootstrap_banner_border() {
    local left=$1 right=$2 rule=''
    printf -v rule '%*s' 68 ''
    rule=${rule// /─}
    printf '%s%s%s\n' "$left" "$rule" "$right"
}

bootstrap_banner_line() {
    local text=$1 width=66 pad=''
    local LC_ALL=C.UTF-8
    if (( ${#text} > width )); then
        printf '│ %s │\n' "$text"
        return
    fi
    printf -v pad '%*s' "$((width - ${#text}))" ''
    printf '│ %s%s │\n' "$text" "$pad"
}

bootstrap_mode() {
    printf '%s%s[РЕЖИМ]%s %s\n' "$C_BOLD" "$C_MAGENTA" "$C_RESET" "$*"
}

show_bootstrap_banner() {
    local arg
    printf '\n%s%s' "$C_BOLD" "$C_CYAN"
    bootstrap_banner_border '┌' '┐'
    bootstrap_banner_line 'Proxmox Project — Public Bootstrap'
    bootstrap_banner_line ''
    bootstrap_banner_line 'Подготавливает host, обновляет root-trusted private repo'
    bootstrap_banner_line 'и запускает PVE Configuration.'
    bootstrap_banner_line ''
    bootstrap_banner_line "Public Bootstrap: v${PUBLIC_BOOTSTRAP_VERSION}"
    bootstrap_banner_border '└' '┘'
    printf '%s' "$C_RESET"

    for arg in "${FORWARD_ARGS[@]}"; do
        case "$arg" in
            --smoke-test-template)
                bootstrap_mode 'Full Clone smoke-test template 9000 через временную VM 9099'
                ;;
            --update-system)
                bootstrap_mode 'Включено полное обновление Proxmox/Debian'
                ;;
        esac
    done
}

show_handoff_banner() {
    printf '\n%s%s%s\n' "$C_BOLD" "$C_CYAN" '════════════════════════════════════════════════════════════════════'
    printf ' Public Bootstrap завершил подготовку.\n'
    printf ' Передача управления PVE Configuration...\n'
    printf '%s%s\n' '════════════════════════════════════════════════════════════════════' "$C_RESET"
}

usage() {
    cat <<'USAGE'
Использование:
  bootstrap-pve.sh [--update-system] [--smoke-test-template] [--help]

Public Bootstrap — публичная точка входа проекта Proxmox.

Первый запуск:
  - создаёт постоянный root-only read-only GitHub Deploy Key;
  - получает private zsergeyru/proxmox;
  - запускает scripts/pve/setup/configure-pve.sh.

Повторный запуск или продолжение незавершённого первого запуска:
  - всегда использует тот же постоянный root-only read-only Deploy Key;
  - новый временный GitHub Deploy Key не создаёт;
  - обновляет root-owned /var/lib/proxmox-deployer/repo;
  - запускает актуальную PVE Configuration.

Public Bootstrap и PVE Configuration используют одну orchestration lock, поэтому
canonical checkout и host configuration никогда не изменяются параллельно.

Параметры:
  --update-system        дополнительно запросить apt full-upgrade Proxmox/Debian
  --smoke-test-template  выполнить Full Clone smoke-test template 9000 через временную VM 9099
  -h, --help             показать эту справку
USAGE
}

while (($#)); do
    case "$1" in
        --update-system) FORWARD_ARGS+=("--update-system") ;;
        --smoke-test-template) FORWARD_ARGS+=("--smoke-test-template") ;;
        -h|--help) usage; exit 0 ;;
        *) die "Неизвестный параметр: $1" ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] || die "Запустите скрипт от root на хосте Proxmox"
command -v pveversion >/dev/null 2>&1 || die "Команда pveversion не найдена: этот скрипт нужно запускать на Proxmox VE"
pveversion >/dev/null
show_bootstrap_banner
ok "Proxmox VE обнаружен"

acquire_bootstrap_lock() {
    command -v flock >/dev/null 2>&1 \
        || die "Не найдена команда flock; на штатном Proxmox VE она должна предоставляться util-linux"
    install -d -m 0755 /run/lock
    exec 9>"$LOCK_FILE"
    flock -n 9 \
        || die "Другой Public Bootstrap или PVE Configuration уже выполняется. Параллельный запуск запрещён."
    ok "Получена общая orchestration lock Public Bootstrap/PVE Configuration"
}

ensure_minimal_packages() {
    local packages=(git openssh-client curl jq ca-certificates util-linux)
    local missing=0 cmd

    for cmd in git ssh ssh-keygen curl jq; do
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

    for cmd in git ssh ssh-keygen curl jq; do
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

prepare_permanent_github_access() {
    log "Подготовка постоянного root-only GitHub Deploy Key"

    install -d -o root -g root -m 0755 "$PERMANENT_CONFIG_DIR"
    if getent group "$DEPLOY_USER" >/dev/null 2>&1; then
        install -d -o root -g "$DEPLOY_USER" -m 0750 "$PERMANENT_SSH_DIR"
    else
        install -d -o root -g root -m 0700 "$PERMANENT_SSH_DIR"
    fi

    if [[ ! -f "$PERMANENT_KEY_FILE" ]]; then
        [[ ! -e "$PERMANENT_KEY_PUB_FILE" ]] \
            || die "Private Deploy Key ${PERMANENT_KEY_FILE} отсутствует, но public-файл существует. Автоматическая ротация запрещена."

        if [[ -f "$LEGACY_BOOTSTRAP_KEY_FILE" ]]; then
            install -o root -g root -m 0600 "$LEGACY_BOOTSTRAP_KEY_FILE" "$PERMANENT_KEY_FILE"
            ok "Существующий ключ незавершённого Public Bootstrap v11 перенесён в постоянное хранилище"
        else
            local old_umask
            old_umask="$(umask)"
            umask 077
            if ! ssh-keygen -q -t ed25519 -N '' \
                -C 'pve-canonical-readonly-zsergeyru-proxmox' \
                -f "$PERMANENT_KEY_FILE"; then
                umask "$old_umask"
                die "Не удалось создать постоянный GitHub Deploy Key"
            fi
            umask "$old_umask"
            ok "Создан постоянный root-only GitHub Deploy Key"
        fi
    else
        ok "Используется существующий постоянный GitHub Deploy Key"
    fi

    local derived_pub tmp_pub
    derived_pub="$(ssh-keygen -y -f "$PERMANENT_KEY_FILE" 2>/dev/null)" \
        || die "Не удалось прочитать постоянный Deploy Key: ${PERMANENT_KEY_FILE}"
    [[ "$derived_pub" == ssh-ed25519\ * ]] \
        || die "Постоянный GitHub Deploy Key должен быть Ed25519"

    chown root:root "$PERMANENT_KEY_FILE"
    chmod 0600 "$PERMANENT_KEY_FILE"

    tmp_pub="$(mktemp "${PERMANENT_SSH_DIR}/.github-key-pub.XXXXXX")"
    printf '%s %s\n' "$derived_pub" 'pve-canonical-readonly-zsergeyru-proxmox' >"$tmp_pub"
    install -o root -g root -m 0644 "$tmp_pub" "$PERMANENT_KEY_PUB_FILE"
    rm -f "$tmp_pub"

    if [[ -f "$LEGACY_BOOTSTRAP_KEY_FILE" ]]; then
        local legacy_pub
        legacy_pub="$(ssh-keygen -y -f "$LEGACY_BOOTSTRAP_KEY_FILE" 2>/dev/null || true)"
        [[ -n "$legacy_pub" ]] || die "Нечитаемый старый temporary Deploy Key: ${LEGACY_BOOTSTRAP_KEY_FILE}"
        [[ "$legacy_pub" == "$derived_pub" ]] \
            || die "Старый temporary Deploy Key отличается от постоянного. Автоматическое удаление неоднозначного credential запрещено."
        rm -f -- "$LEGACY_BOOTSTRAP_KEY_FILE" "$LEGACY_BOOTSTRAP_KEY_PUB_FILE"
        ok "Старая временная копия GitHub Deploy Key удалена; постоянный ключ сохранён"
    fi

    local tmp_hosts tmp_config
    tmp_hosts="$(mktemp "${PERMANENT_SSH_DIR}/.known-hosts.XXXXXX")"
    curl -fsSL --connect-timeout 10 --max-time 20 https://api.github.com/meta \
        | jq -r '.ssh_keys[] | "github.com " + .' >"$tmp_hosts"
    [[ -s "$tmp_hosts" ]] || { rm -f "$tmp_hosts"; die "Не удалось получить SSH host keys GitHub через api.github.com/meta"; }
    install -o root -g root -m 0644 "$tmp_hosts" "$PERMANENT_KNOWN_HOSTS"
    rm -f "$tmp_hosts"

    tmp_config="$(mktemp "${PERMANENT_SSH_DIR}/.config.XXXXXX")"
    cat >"$tmp_config" <<EOF_SSH
Host github.com
    HostName github.com
    User git
    IdentityFile ${PERMANENT_KEY_FILE}
    IdentitiesOnly yes
    UserKnownHostsFile ${PERMANENT_KNOWN_HOSTS}
    StrictHostKeyChecking yes
    BatchMode yes
    ConnectTimeout 10
    ServerAliveInterval 15
    ServerAliveCountMax 2
EOF_SSH
    install -o root -g root -m 0600 "$tmp_config" "$PERMANENT_SSH_CONFIG"
    rm -f "$tmp_config"

    rm -f -- "$LEGACY_BOOTSTRAP_KNOWN_HOSTS" "$LEGACY_BOOTSTRAP_SSH_CONFIG"
}

bootstrap_git() {
    env GIT_SSH_COMMAND="ssh -F ${PERMANENT_SSH_CONFIG}" \
        git -c "safe.directory=${TEMP_REPO}" "$@"
}

private_branch_accessible() {
    local out
    if ! out="$(bootstrap_git ls-remote "$PRIVATE_REPO" "refs/heads/${PRIVATE_BRANCH}" 2>/dev/null)"; then
        return 1
    fi
    [[ -n "$out" ]] || die "Private repo доступен, но ожидаемая ветка ${PRIVATE_BRANCH} отсутствует."
}

show_deploy_key_instructions() {
    printf '\n%s%sОЖИДАНИЕ АВТОРИЗАЦИИ GITHUB%s\n\n' "$C_BOLD" "$C_MAGENTA" "$C_RESET"
    printf 'Добавьте следующий постоянный публичный ключ в private repo zsergeyru/proxmox:\n\n'
    cat "$PERMANENT_KEY_PUB_FILE"
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
        || die "Deploy Key ещё не авторизован, а интерактивный терминал недоступен. Добавьте показанный постоянный public key в GitHub и повторите bootstrap-pve.sh."

    printf 'Нажмите Enter после добавления Deploy Key в GitHub...' >/dev/tty
    IFS= read -r _ </dev/tty || die "Не удалось дождаться подтверждения через терминал"
    printf '\n' >/dev/tty

    check_github_connectivity
    private_branch_accessible \
        || die "Read-only доступ к ${PRIVATE_REPO}, ветка ${PRIVATE_BRANCH}, по-прежнему отсутствует. Проверьте постоянный Deploy Key и повторите bootstrap-pve.sh."
    ok "Read-only доступ к private repo подтверждён"
}

sync_temporary_private_repo() {
    log "Получение private PVE Configuration"

    if [[ ! -d "$TEMP_REPO/.git" ]]; then
        rm -rf "$TEMP_REPO"
        bootstrap_git clone --depth 1 --branch "$PRIVATE_BRANCH" "$PRIVATE_REPO" "$TEMP_REPO"
    else
        local origin_url
        origin_url="$(bootstrap_git -C "$TEMP_REPO" remote get-url origin 2>/dev/null || true)"
        [[ "$origin_url" == "$PRIVATE_REPO" ]] \
            || die "Временный checkout ${TEMP_REPO} имеет неожиданный origin '${origin_url:-не задан}'. Автоматическая подмена origin запрещена."
        bootstrap_git -C "$TEMP_REPO" fetch --depth 1 origin "$PRIVATE_BRANCH"
        bootstrap_git -C "$TEMP_REPO" reset --hard FETCH_HEAD
        bootstrap_git -C "$TEMP_REPO" clean -ffdx
    fi

    ok "Private repo получен shallow clone глубиной 1 commit"
}

handoff_to_pve_configuration() {
    local configure="${TEMP_REPO}/scripts/pve/setup/configure-pve.sh"
    local revision
    [[ -f "$configure" ]] || die "В private repo не найден scripts/pve/setup/configure-pve.sh"
    revision="$(bootstrap_git -C "$TEMP_REPO" rev-parse HEAD)"

    show_handoff_banner
    info "PVE Configuration revision=${revision}"
    PVE_CONFIGURATION_SOURCE_REVISION="$revision" \
    PVE_ORCHESTRATION_LOCK_HELD=1 \
        bash "$configure" "${FORWARD_ARGS[@]}"
}

prepare_root_owned_permanent_git_runtime() {
    log "Проверка canonical source в root trust boundary"

    install -d -o root -g "$DEPLOY_USER" -m 0750 "$PERMANENT_RUNTIME_DIR"
    install -d -o root -g "$DEPLOY_USER" -m 0750 "$PERMANENT_SSH_DIR"

    chown root:root "$PERMANENT_KEY_FILE"
    chmod 0600 "$PERMANENT_KEY_FILE"
    chown root:root "$PERMANENT_KEY_PUB_FILE" "$PERMANENT_KNOWN_HOSTS" "$PERMANENT_SSH_CONFIG"
    chmod 0644 "$PERMANENT_KEY_PUB_FILE" "$PERMANENT_KNOWN_HOSTS"
    chmod 0600 "$PERMANENT_SSH_CONFIG"

    chown -R root:root "$PERMANENT_REPO"
    chmod -R go-w "$PERMANENT_REPO"
    ok "Canonical repo и GitHub credential находятся под root trust boundary"
}

permanent_git() {
    env GIT_SSH_COMMAND="ssh -F ${PERMANENT_SSH_CONFIG}" \
        git -c "safe.directory=${PERMANENT_REPO}" "$@"
}

permanent_runtime_ready_for_refresh() {
    id "$DEPLOY_USER" >/dev/null 2>&1 \
        && [[ -f "$PERMANENT_KEY_FILE" ]] \
        && [[ -f "$PERMANENT_KNOWN_HOSTS" ]] \
        && [[ -f "$PERMANENT_SSH_CONFIG" ]] \
        && [[ -d "$PERMANENT_REPO/.git" ]]
}

assert_permanent_source_trust() {
    local parent_owner parent_mode violation key_owner key_mode config_owner config_mode

    parent_owner="$(stat -c '%U:%G' "$PERMANENT_RUNTIME_DIR" 2>/dev/null || true)"
    parent_mode="$(stat -c '%a' "$PERMANENT_RUNTIME_DIR" 2>/dev/null || true)"
    [[ "$parent_owner" == "root:${DEPLOY_USER}" && "$parent_mode" == "750" ]] \
        || die "${PERMANENT_RUNTIME_DIR} должен быть root:${DEPLOY_USER} 0750, обнаружено ${parent_owner:-?} ${parent_mode:-?}"

    key_owner="$(stat -c '%U:%G' "$PERMANENT_KEY_FILE" 2>/dev/null || true)"
    key_mode="$(stat -c '%a' "$PERMANENT_KEY_FILE" 2>/dev/null || true)"
    [[ "$key_owner" == "root:root" && "$key_mode" == "600" ]] \
        || die "Canonical GitHub private key должен быть root:root 0600, обнаружено ${key_owner:-?} ${key_mode:-?}"

    config_owner="$(stat -c '%U:%G' "$PERMANENT_SSH_CONFIG" 2>/dev/null || true)"
    config_mode="$(stat -c '%a' "$PERMANENT_SSH_CONFIG" 2>/dev/null || true)"
    [[ "$config_owner" == "root:root" && "$config_mode" == "600" ]] \
        || die "Canonical Git SSH config должен быть root:root 0600, обнаружено ${config_owner:-?} ${config_mode:-?}"

    violation="$(find "$PERMANENT_REPO" -xdev \( -type f -o -type d \) \( ! -uid 0 -o -perm /022 \) -print -quit 2>/dev/null || true)"
    [[ -z "$violation" ]] \
        || die "Canonical checkout не является root-trusted: '${violation}' не root-owned или доступен на запись группе/остальным"
}

assert_permanent_repo_clean() {
    local status
    status="$(permanent_git -C "$PERMANENT_REPO" status --porcelain=v1 --untracked-files=all --ignored)" \
        || die "Не удалось проверить clean state canonical checkout ${PERMANENT_REPO}"
    [[ -z "$status" ]] \
        || die "Canonical checkout ${PERMANENT_REPO} содержит локальный drift. Bootstrap не выполняет destructive reset/clean поверх локальных данных. Первый элемент: $(head -n1 <<<"$status")"
}

refresh_permanent_repo_and_handoff() {
    log "Обновление root-trusted canonical private checkout"

    id "$DEPLOY_USER" >/dev/null 2>&1 \
        || die "Linux-пользователь ${DEPLOY_USER} отсутствует. Восстановите PVE Configuration runtime."
    [[ -f "$PERMANENT_KEY_FILE" ]] || die "Постоянный Deploy Key ${PERMANENT_KEY_FILE} отсутствует. Автоматическая ротация запрещена."
    [[ -f "$PERMANENT_KNOWN_HOSTS" ]] || die "Отсутствует ${PERMANENT_KNOWN_HOSTS}. Восстановите canonical SSH runtime."
    [[ -f "$PERMANENT_SSH_CONFIG" ]] || die "Отсутствует ${PERMANENT_SSH_CONFIG}. Восстановите canonical SSH runtime."
    [[ -d "$PERMANENT_REPO/.git" ]] || die "Canonical checkout ${PERMANENT_REPO} отсутствует или не является Git repository."

    prepare_root_owned_permanent_git_runtime
    assert_permanent_source_trust

    local origin_url refs revision configuration_version
    origin_url="$(permanent_git -C "$PERMANENT_REPO" remote get-url origin 2>/dev/null || true)"
    [[ "$origin_url" == "$PRIVATE_REPO" ]] \
        || die "Canonical checkout ${PERMANENT_REPO} имеет неожиданный origin '${origin_url:-не задан}'. Ожидается '${PRIVATE_REPO}'."

    assert_permanent_repo_clean

    refs="$(permanent_git ls-remote "$PRIVATE_REPO" "refs/heads/${PRIVATE_BRANCH}" 2>/dev/null || true)"
    [[ -n "$refs" ]] || die "Постоянный root-only Deploy Key не даёт read-only доступ к ${PRIVATE_REPO}/${PRIVATE_BRANCH}."

    permanent_git -C "$PERMANENT_REPO" fetch --depth 1 origin "$PRIVATE_BRANCH" \
        || die "Не удалось получить актуальную ветку ${PRIVATE_BRANCH} private repo"
    permanent_git -C "$PERMANENT_REPO" reset --hard FETCH_HEAD \
        || die "Не удалось переключить canonical checkout на полученную ${PRIVATE_BRANCH}"
    permanent_git -C "$PERMANENT_REPO" clean -ffd \
        || die "Не удалось очистить canonical checkout от неотслеживаемых файлов"
    chown -R root:root "$PERMANENT_REPO"
    chmod -R go-w "$PERMANENT_REPO"
    assert_permanent_source_trust
    assert_permanent_repo_clean

    revision="$(permanent_git -C "$PERMANENT_REPO" rev-parse HEAD)"
    [[ -f "$PVE_CONFIGURATION_CANONICAL" ]] || die "После обновления private repo не найден ${PVE_CONFIGURATION_CANONICAL}"

    configuration_version="$(sed -n 's/^PVE_CONFIGURATION_VERSION=//p' "$PVE_CONFIGURATION_VERSION_FILE" | head -n1)"
    ok "Canonical private repo обновлён: ${revision}"
    [[ -n "$configuration_version" ]] && ok "Будет запущена PVE Configuration version=${configuration_version}"

    show_handoff_banner
    info "PVE Configuration revision=${revision}"
    PVE_CONFIGURATION_SOURCE_REVISION="$revision" \
    PVE_ORCHESTRATION_LOCK_HELD=1 \
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
        || die "PVE Configuration завершилась, но постоянный state-каталог ${PERMANENT_STATE_DIR} не найден; temporary checkout сохранён для диагностики"
    permanent_runtime_ready_for_refresh \
        || die "PVE Configuration завершилась, но canonical permanent runtime неполон; temporary checkout сохранён для диагностики"

    assert_permanent_source_trust
    revision="$(permanent_git -C "$PERMANENT_REPO" rev-parse HEAD 2>/dev/null || true)"
    [[ "$revision" =~ ^[0-9a-f]{40}$ ]] \
        || die "Не удалось определить final revision canonical private checkout"

    rm -rf "$BOOTSTRAP_TEMP_DIR"
    [[ ! -e "$BOOTSTRAP_TEMP_DIR" ]] || die "Не удалось полностью удалить temporary checkout ${BOOTSTRAP_TEMP_DIR}"
    write_complete_marker "$revision"
    ok "Public Bootstrap завершён; temporary checkout удалён, marker записан для revision ${revision}"
}

main() {
    local revision
    acquire_bootstrap_lock
    ensure_minimal_packages
    check_github_connectivity
    prepare_permanent_github_access

    if [[ -f "$COMPLETE_MARKER" ]]; then
        info "Public Bootstrap уже выполнялся; будет обновлён private checkout"
        permanent_runtime_ready_for_refresh \
            || die "Bootstrap marker существует, но canonical runtime неполон. Восстановите постоянный runtime; новый GitHub ключ создаваться не будет."
        ensure_private_repo_authorized
        refresh_permanent_repo_and_handoff
        revision="$(permanent_git -C "$PERMANENT_REPO" rev-parse HEAD 2>/dev/null || true)"
        write_complete_marker "$revision"
        printf '\n%s%sPVE CONFIGURATION УСПЕШНО ЗАВЕРШЕНА%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
        exit 0
    fi

    if permanent_runtime_ready_for_refresh; then
        info "Bootstrap marker отсутствует, но canonical runtime уже готов. Продолжается незавершённый первый запуск с тем же постоянным credential."
        ensure_private_repo_authorized
        refresh_permanent_repo_and_handoff
        finalize_bootstrap
        printf '\n%s%sPUBLIC BOOTSTRAP УСПЕШНО ВОЗОБНОВЛЁН И ЗАВЕРШЁН%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
        exit 0
    fi

    if [[ -d "$PERMANENT_REPO/.git" || -f "$PERMANENT_KEY_FILE" ]]; then
        info "Обнаружен частично созданный permanent runtime. Public Bootstrap продолжит первый запуск с существующим постоянным GitHub credential."
    fi

    prepare_bootstrap_temp_dir
    ensure_private_repo_authorized
    sync_temporary_private_repo
    handoff_to_pve_configuration
    finalize_bootstrap

    printf '\n%s%sPUBLIC BOOTSTRAP УСПЕШНО ЗАВЕРШЁН%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
    printf 'Дальнейшее состояние PVE поддерживает private scripts/pve/setup/configure-pve.sh.\n'
    printf 'Для следующих запусков используйте ту же public bootstrap-pve.sh команду.\n'
}

main "$@"
