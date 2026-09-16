#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# Публичная Stage 0 для нового Proxmox VE
# =============================================================================
#
# Этот скрипт намеренно почти ничего не знает о внутренней архитектуре PVE-проекта.
# Его задача при первом запуске:
#   1) обеспечить наличие Git/SSH;
#   2) создать временный read-only GitHub Deploy Key;
#   3) помочь человеку добавить public key в приватный zsergeyru/proxmox;
#   4) получить временный shallow checkout private repo;
#   5) передать управление приватному bootstrap;
#   6) после успешного handoff удалить временную Stage 0 область целиком.
#
# После успешной Stage 0 этот же entrypoint используется только как безопасный
# updater/handoff: он переиспользует постоянный read-only Deploy Key, обновляет
# canonical private checkout и запускает уже свежую private Stage 1.
#
# Все роли, ACL, API-токены, pools, templates, deployer и прочая инфраструктура
# описываются и создаются только кодом из закрытого репозитория.

STAGE0_VERSION=4

PRIVATE_REPO="git@github.com:zsergeyru/proxmox.git"
PRIVATE_BRANCH="main"
DEPLOY_USER="pvedeploy"

# Полностью временная рабочая область zero-day bootstrap.
STAGE0_DIR="/var/lib/proxmox-bootstrap"
KEY_FILE="${STAGE0_DIR}/github_proxmox_repo_ed25519"
KEY_PUB_FILE="${KEY_FILE}.pub"
KNOWN_HOSTS="${STAGE0_DIR}/known_hosts"
SSH_CONFIG="${STAGE0_DIR}/ssh_config"
TEMP_REPO="${STAGE0_DIR}/private-repo"

# После успешного handoff marker и private checkout находятся уже в постоянной
# структуре, созданной private Stage 1.
PERMANENT_STATE_DIR="/var/lib/proxmox-deployer/state"
COMPLETE_MARKER="${PERMANENT_STATE_DIR}/stage0-complete"
PERMANENT_REPO="/var/lib/proxmox-deployer/repo"
PERMANENT_SSH_DIR="/etc/proxmox-deployer/ssh"
PERMANENT_KEY_FILE="${PERMANENT_SSH_DIR}/github_proxmox_repo_ed25519"
PERMANENT_KNOWN_HOSTS="${PERMANENT_SSH_DIR}/known_hosts"
PERMANENT_SSH_CONFIG="${PERMANENT_SSH_DIR}/config"
LOCK_FILE="/run/lock/proxmox-bootstrap-stage0.lock"
PRIVATE_INIT_CANONICAL="${PERMANENT_REPO}/scripts/pve/bootstrap/init-pve.sh"

FORWARD_ARGS=()

log()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '[ОК] %s\n' "$*"; }
warn() { printf '[ПРЕДУПРЕЖДЕНИЕ] %s\n' "$*" >&2; }
die()  { printf '\nОШИБКА: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Использование:
  init-pve.sh [--update-system] [--help]

Публичная точка входа bootstrap Proxmox VE.

При первом запуске она подготавливает временный read-only Deploy Key для
приватного zsergeyru/proxmox и после авторизации передаёт управление private
Stage 1. Если Deploy Key ещё не добавлен в GitHub, скрипт покажет public key,
подождёт нажатия Enter и затем один раз повторит проверку доступа.

После уже завершённой Stage 0 тот же entrypoint не создаёт новые credentials:
он проверяет постоянный Deploy Key/private checkout, обновляет canonical main и
запускает свежую private Stage 1.

Параметры:
  --update-system  передать private Stage 1 запрос полного обновления PVE
  -h, --help       показать эту справку
USAGE
}

while (($#)); do
    case "$1" in
        --update-system)
            FORWARD_ARGS+=("--update-system")
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

[[ $EUID -eq 0 ]] || die "Запустите скрипт от root на хосте Proxmox"
command -v pveversion >/dev/null 2>&1 || die "Команда pveversion не найдена: этот скрипт нужно запускать на Proxmox VE"
pveversion >/dev/null
ok "Proxmox VE обнаружен"

acquire_stage0_lock() {
    command -v flock >/dev/null 2>&1 \
        || die "Не найдена команда flock; на штатном Proxmox VE она должна предоставляться util-linux"
    install -d -m 0755 /run/lock
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Другой экземпляр публичного bootstrap уже выполняется. Параллельный запуск запрещён."
    ok "Получена эксклюзивная блокировка public bootstrap"
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
        warn "Первая попытка установки пакетов не удалась; выполняется apt update без изменения конфигурации репозиториев"
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
    getent ahosts github.com >/dev/null \
        || die "Не работает DNS-разрешение github.com"
    getent ahosts api.github.com >/dev/null \
        || die "Не работает DNS-разрешение api.github.com"

    curl -fsS --connect-timeout 10 --max-time 20 -o /dev/null https://github.com/ \
        || die "GitHub недоступен по HTTPS с этого Proxmox host"
    curl -fsS --connect-timeout 10 --max-time 20 -o /dev/null https://api.github.com/meta \
        || die "GitHub API недоступен по HTTPS с этого Proxmox host"

    ok "DNS и HTTPS-доступ к GitHub работают"
}

prepare_stage0_dir() {
    install -d -o root -g root -m 0700 "$STAGE0_DIR"
}

prepare_github_key() {
    log "Подготовка временного read-only Deploy Key для приватного GitHub-репозитория"

    if [[ ! -f "$KEY_FILE" ]]; then
        ssh-keygen -q -t ed25519 -N '' \
            -C 'pve-zero-day-readonly-zsergeyru-proxmox' \
            -f "$KEY_FILE"
        ok "Создан новый временный Deploy Key"
    else
        ok "Используется существующий временный Deploy Key"
    fi

    chmod 0600 "$KEY_FILE"

    # Private key — source of truth. Public часть каждый запуск восстанавливается
    # из него, поэтому потерянный/повреждённый .pub не ломает повторный запуск.
    local tmp_pub derived_pub
    tmp_pub="$(mktemp "${STAGE0_DIR}/.deploy-key-pub.XXXXXX")"
    derived_pub="$(ssh-keygen -y -f "$KEY_FILE")" \
        || { rm -f "$tmp_pub"; die "Не удалось прочитать существующий Deploy Key: ${KEY_FILE}"; }
    [[ -n "$derived_pub" ]] \
        || { rm -f "$tmp_pub"; die "Из private Deploy Key не удалось получить public key"; }
    printf '%s %s\n' "$derived_pub" 'pve-zero-day-readonly-zsergeyru-proxmox' >"$tmp_pub"
    install -o root -g root -m 0644 "$tmp_pub" "$KEY_PUB_FILE"
    rm -f "$tmp_pub"

    local tmp_hosts
    tmp_hosts="$(mktemp "${STAGE0_DIR}/.known-hosts.XXXXXX")"
    curl -fsSL --connect-timeout 10 --max-time 20 https://api.github.com/meta \
        | jq -r '.ssh_keys[] | "github.com " + .' >"$tmp_hosts"

    [[ -s "$tmp_hosts" ]] || {
        rm -f "$tmp_hosts"
        die "Не удалось получить SSH host keys GitHub через api.github.com/meta"
    }

    install -o root -g root -m 0644 "$tmp_hosts" "$KNOWN_HOSTS"
    rm -f "$tmp_hosts"

    cat >"$SSH_CONFIG" <<EOF_SSH
Host github.com
    HostName github.com
    User git
    IdentityFile ${KEY_FILE}
    IdentitiesOnly yes
    UserKnownHostsFile ${KNOWN_HOSTS}
    StrictHostKeyChecking yes
    BatchMode yes
    ConnectTimeout 10
EOF_SSH
    chmod 0600 "$SSH_CONFIG"
}

git_private() {
    env GIT_SSH_COMMAND="ssh -F ${SSH_CONFIG}" git "$@"
}

private_branch_accessible() {
    local out
    if ! out="$(git_private ls-remote "$PRIVATE_REPO" "refs/heads/${PRIVATE_BRANCH}" 2>/dev/null)"; then
        return 1
    fi

    [[ -n "$out" ]] \
        || die "Приватный репозиторий доступен, но ожидаемая ветка ${PRIVATE_BRANCH} отсутствует. Bootstrap не будет продолжать с другой веткой."
}

show_deploy_key_instructions() {
    printf '\nОЖИДАНИЕ АВТОРИЗАЦИИ GITHUB\n\n'
    printf 'Добавьте следующий публичный ключ в приватный репозиторий zsergeyru/proxmox:\n\n'
    cat "$KEY_PUB_FILE"
    printf '\nПуть: GitHub -> zsergeyru/proxmox -> Settings -> Deploy keys -> Add deploy key\n'
    printf 'Allow write access: ВЫКЛЮЧЕН\n'
    printf '\nПосле добавления ключа вернитесь в этот терминал.\n'
}

ensure_private_repo_authorized() {
    if private_branch_accessible; then
        ok "Read-only доступ к приватному репозиторию и ветке ${PRIVATE_BRANCH} уже подтверждён"
        return
    fi

    show_deploy_key_instructions

    [[ -r /dev/tty ]] \
        || die "Deploy Key ещё не авторизован, а интерактивный терминал недоступен. Добавьте показанный public key в GitHub и повторно запустите init-pve.sh."

    printf 'Нажмите Enter после добавления Deploy Key в GitHub...' >/dev/tty
    IFS= read -r _ </dev/tty \
        || die "Не удалось дождаться подтверждения через терминал"
    printf '\n' >/dev/tty

    # После ожидания отдельно перепроверяем сеть, чтобы отличить проблему GitHub
    # от ошибочно/неполностью добавленного Deploy Key.
    check_github_connectivity

    if ! private_branch_accessible; then
        die "После подтверждения read-only доступ к ${PRIVATE_REPO}, ветка ${PRIVATE_BRANCH}, по-прежнему отсутствует. Проверьте, что показанный public key добавлен именно в zsergeyru/proxmox как Deploy Key с выключенным Allow write access, и что SSH-доступ к github.com не блокируется. После исправления повторно запустите init-pve.sh."
    fi

    ok "Read-only доступ к приватному репозиторию и ветке ${PRIVATE_BRANCH} подтверждён после добавления Deploy Key"
}

sync_private_repo() {
    log "Получение временного private bootstrap"

    if [[ ! -d "$TEMP_REPO/.git" ]]; then
        rm -rf "$TEMP_REPO"
        git_private clone --depth 1 --branch "$PRIVATE_BRANCH" "$PRIVATE_REPO" "$TEMP_REPO"
    else
        local origin_url
        origin_url="$(git_private -C "$TEMP_REPO" remote get-url origin 2>/dev/null || true)"
        [[ "$origin_url" == "$PRIVATE_REPO" ]] \
            || die "Временный checkout ${TEMP_REPO} имеет неожиданный origin '${origin_url:-не задан}'. Ожидается '${PRIVATE_REPO}'. Автоматическая подмена origin запрещена."

        git_private -C "$TEMP_REPO" fetch --depth 1 origin "$PRIVATE_BRANCH"
        git_private -C "$TEMP_REPO" reset --hard FETCH_HEAD
        git_private -C "$TEMP_REPO" clean -ffd
    fi

    ok "Приватный репозиторий получен shallow clone глубиной 1 commit"
}

handoff_to_private_bootstrap() {
    local private_init="${TEMP_REPO}/scripts/pve/bootstrap/init-pve.sh"
    [[ -f "$private_init" ]] || die "В приватном репозитории не найден scripts/pve/bootstrap/init-pve.sh"

    log "Передача управления приватной инициализации PVE"

    PVE_STAGE0_DIR="$STAGE0_DIR" \
    PVE_STAGE0_KEY_FILE="$KEY_FILE" \
    PVE_STAGE0_KNOWN_HOSTS="$KNOWN_HOSTS" \
        bash "$private_init" "${FORWARD_ARGS[@]}"
}

permanent_git() {
    runuser -u "$DEPLOY_USER" -- \
        env GIT_SSH_COMMAND="ssh -F ${PERMANENT_SSH_CONFIG}" git "$@"
}

refresh_permanent_repo_and_handoff() {
    log "Обновление постоянного private checkout перед запуском Stage 1"

    ensure_minimal_packages
    check_github_connectivity

    id "$DEPLOY_USER" >/dev/null 2>&1 \
        || die "Marker Stage 0 существует, но Linux-пользователь ${DEPLOY_USER} отсутствует. Автоматическое создание или новый credential запрещены; восстановите private Stage 1 runtime."
    [[ -f "$PERMANENT_KEY_FILE" ]] \
        || die "Marker Stage 0 существует, но постоянный Deploy Key ${PERMANENT_KEY_FILE} отсутствует. Автоматическая ротация запрещена; восстановите credential из backup или выполните отдельную rotation operation."
    [[ -f "$PERMANENT_KNOWN_HOSTS" ]] \
        || die "Marker Stage 0 существует, но ${PERMANENT_KNOWN_HOSTS} отсутствует. Восстановите canonical SSH runtime private Stage 1."
    [[ -f "$PERMANENT_SSH_CONFIG" ]] \
        || die "Marker Stage 0 существует, но ${PERMANENT_SSH_CONFIG} отсутствует. Восстановите canonical SSH runtime private Stage 1."
    [[ -d "$PERMANENT_REPO/.git" ]] \
        || die "Marker Stage 0 существует, но canonical checkout ${PERMANENT_REPO} отсутствует или не является Git repository. Автоматический новый clone после завершённой Stage 0 запрещён."

    local origin_url refs revision bootstrap_version
    origin_url="$(permanent_git -C "$PERMANENT_REPO" remote get-url origin 2>/dev/null || true)"
    [[ "$origin_url" == "$PRIVATE_REPO" ]] \
        || die "Canonical checkout ${PERMANENT_REPO} имеет неожиданный origin '${origin_url:-не задан}'. Ожидается '${PRIVATE_REPO}'. Автоматическая подмена origin запрещена."

    refs="$(permanent_git ls-remote "$PRIVATE_REPO" "refs/heads/${PRIVATE_BRANCH}" 2>/dev/null || true)"
    [[ -n "$refs" ]] \
        || die "Постоянный Deploy Key не даёт read-only доступ к ${PRIVATE_REPO}, ветка ${PRIVATE_BRANCH}. Public bootstrap не создаёт новый key после завершённой Stage 0; восстановите/ротируйте canonical credential явно."

    permanent_git -C "$PERMANENT_REPO" fetch --depth 1 origin "$PRIVATE_BRANCH" \
        || die "Не удалось получить актуальную ветку ${PRIVATE_BRANCH} приватного репозитория"
    permanent_git -C "$PERMANENT_REPO" reset --hard FETCH_HEAD \
        || die "Не удалось переключить canonical checkout на полученную ${PRIVATE_BRANCH}"
    permanent_git -C "$PERMANENT_REPO" clean -ffd \
        || die "Не удалось очистить canonical checkout от неотслеживаемых файлов"

    revision="$(permanent_git -C "$PERMANENT_REPO" rev-parse HEAD)"
    [[ -f "$PRIVATE_INIT_CANONICAL" ]] \
        || die "После обновления private repo не найден ${PRIVATE_INIT_CANONICAL}"

    bootstrap_version="$(sed -n 's/^BOOTSTRAP_VERSION=//p' "$PRIVATE_INIT_CANONICAL" | head -n1)"
    ok "Canonical private repo обновлён: ${revision}"
    if [[ -n "$bootstrap_version" ]]; then
        ok "Будет запущена private Stage 1 BOOTSTRAP_VERSION=${bootstrap_version}"
    fi

    log "Передача управления свежей private Stage 1"
    bash "$PRIVATE_INIT_CANONICAL" "${FORWARD_ARGS[@]}"
}

cleanup_stage0() {
    local revision now marker_tmp
    revision="$(git -C "$TEMP_REPO" rev-parse HEAD 2>/dev/null || true)"
    now="$(date --iso-8601=seconds)"

    [[ -d "$PERMANENT_STATE_DIR" ]] \
        || die "Private Stage 1 завершилась, но постоянный state-каталог ${PERMANENT_STATE_DIR} не найден; временная Stage 0 область сохранена для безопасного повторного запуска"

    # Подготавливаем marker вне временной области, но публикуем его только после
    # успешного удаления всей Stage 0 директории.
    marker_tmp="${PERMANENT_STATE_DIR}/.stage0-complete.$$.tmp"
    cat >"$marker_tmp" <<EOF_MARKER
stage0=complete
stage0_version=${STAGE0_VERSION}
timestamp=${now}
private_revision=${revision}
EOF_MARKER
    chmod 0600 "$marker_tmp"

    rm -rf "$STAGE0_DIR"
    [[ ! -e "$STAGE0_DIR" ]] \
        || { rm -f "$marker_tmp"; die "Не удалось полностью удалить временную Stage 0 область ${STAGE0_DIR}"; }

    mv -f "$marker_tmp" "$COMPLETE_MARKER"
    chmod 0600 "$COMPLETE_MARKER"

    ok "Stage 0 завершена; временный Deploy Key и temporary checkout удалены вместе с ${STAGE0_DIR}"
}

main() {
    acquire_stage0_lock

    if [[ -f "$COMPLETE_MARKER" ]]; then
        printf '\nStage 0 уже была успешно завершена.\n'
        printf 'Новый public запуск обновит canonical private checkout и запустит свежую Stage 1.\n'
        refresh_permanent_repo_and_handoff
        printf '\nPRIVATE STAGE 1 УСПЕШНО ЗАВЕРШЕНА\n'
        exit 0
    fi

    prepare_stage0_dir
    ensure_minimal_packages
    check_github_connectivity
    prepare_github_key
    ensure_private_repo_authorized
    sync_private_repo
    handoff_to_private_bootstrap
    cleanup_stage0

    printf '\nПУБЛИЧНАЯ STAGE 0 УСПЕШНО ЗАВЕРШЕНА\n'
    printf 'Дальнейший source of truth и вся логика PVE находятся в приватном zsergeyru/proxmox.\n'
    printf 'Для последующих запусков используйте ту же public curl-команду: она обновит private main и передаст управление свежей Stage 1.\n'
}

main "$@"
