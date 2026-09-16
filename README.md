# Proxmox Bootstrap

Публичный репозиторий содержит минимальную точку входа для первоначального подключения Proxmox VE к приватному инфраструктурному репозиторию и для последующих повторных запусков конфигурации.

Текущая версия Public Bootstrap:

```text
PUBLIC_BOOTSTRAP_VERSION=7
```

В проекте два компонента:

```text
Public Bootstrap
bootstrap-pve.sh
→ получить или обновить private repo
→ выбрать точную Git revision
→ запустить PVE Configuration из этой revision

PVE Configuration
zsergeyru/proxmox/scripts/pve/setup/configure-pve.sh
→ привести Proxmox VE к ожидаемому состоянию проекта
```

## Основная команда

Войдите в shell Proxmox под `root` и используйте одну и ту же команду как при первоначальной установке, так и при последующих запусках или продолжении незавершённого первого запуска:

```bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/bootstrap-pve.sh | bash
```

Обычный запуск **не выполняет полный `apt full-upgrade` системы**.

Для осознанного полного обновления Proxmox VE / Debian:

```bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/bootstrap-pve.sh | bash -s -- --update-system
```

Без `--update-system` PVE Configuration всё равно может выполнять `apt update` и устанавливать отсутствующие пакеты, необходимые проекту.

## Первый запуск

Если постоянный marker отсутствует и canonical runtime ещё не создан, `bootstrap-pve.sh` выполняет:

```text
root + Proxmox check
→ exclusive lock
→ minimal Git/SSH packages
→ DNS/HTTPS GitHub check
→ temporary read-only GitHub Deploy Key
→ authorization private repo/main
→ temporary shallow checkout
→ определить точный HEAD private repo
→ передать этот SHA в PVE Configuration
→ PVE Configuration создаёт permanent runtime и canonical checkout той же revision
→ удалить /var/lib/proxmox-bootstrap
→ создать /var/lib/proxmox-deployer/state/bootstrap-complete
```

Временная область:

```text
/var/lib/proxmox-bootstrap/
├── github_proxmox_repo_ed25519
├── github_proxmox_repo_ed25519.pub
├── known_hosts
├── ssh_config
└── private-repo/
```

Если Deploy Key ещё не добавлен в GitHub, Public Bootstrap показывает public key и ждёт подтверждение пользователя через терминал. Write access для Deploy Key не включается.

## Продолжение незавершённого первого запуска

Если PVE Configuration была прервана после того, как permanent runtime уже частично или полностью создан, **не нужно удалять `/etc/proxmox-deployer` или `/var/lib/proxmox-deployer`**.

Та же основная команда безопасно продолжает работу:

```bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/bootstrap-pve.sh | bash
```

Если permanent runtime уже содержит `pvedeploy`, canonical Deploy Key, SSH config/known_hosts и canonical Git checkout, Public Bootstrap использует их как обычный permanent runtime, обновляет private repo и снова запускает PVE Configuration.

Если permanent runtime создан только частично, Public Bootstrap продолжает first-run path через сохранённый temporary runtime. Существующие постоянные credentials не удаляются и не ротируются автоматически.

Это важно для API tokens и SSH keys: если token уже создан в Proxmox, его одноразовый secret нельзя получить повторно, поэтому bootstrap не должен лечить частичную ошибку удалением локальных secrets.

## Повторный запуск после завершённого bootstrap

При наличии:

```text
/var/lib/proxmox-deployer/state/bootstrap-complete
```

Public Bootstrap использует permanent runtime:

```text
pvedeploy
/etc/proxmox-deployer/ssh/github_proxmox_repo_ed25519
/etc/proxmox-deployer/ssh/config
/etc/proxmox-deployer/ssh/known_hosts
/var/lib/proxmox-deployer/repo
```

Алгоритм:

```text
проверить permanent runtime
→ проверить origin canonical checkout
→ подтвердить read-only доступ к zsergeyru/proxmox/main
→ fetch main
→ reset --hard FETCH_HEAD
→ clean -ffd
→ зафиксировать полученный SHA
→ запустить scripts/pve/setup/configure-pve.sh с PVE_CONFIGURATION_SOURCE_REVISION=<SHA>
```

Private key не ротируется автоматически. Если постоянный credential, SSH config или canonical checkout повреждён, Public Bootstrap останавливается и требует явного recovery.

## Одна revision на один configuration run

После выбора private revision Public Bootstrap передаёт её в PVE Configuration через:

```text
PVE_CONFIGURATION_SOURCE_REVISION
```

Это предотвращает смешивание кода из двух commits в одном запуске. Если `main` изменится между temporary checkout и canonical clone/fetch, PVE Configuration не переключится молча на более новый commit, а остановится и предложит повторить Public Bootstrap.

## Постоянные пути

Canonical private checkout:

```text
/var/lib/proxmox-deployer/repo
```

Каноническая PVE Configuration:

```text
/var/lib/proxmox-deployer/repo/scripts/pve/setup/configure-pve.sh
```

Marker успешного первоначального bootstrap:

```text
/var/lib/proxmox-deployer/state/bootstrap-complete
```

В публичном репозитории не хранятся внутренняя конфигурация Proxmox, роли, ACL, API-токены, планы VM/LXC, template implementation, конфигурация AI или другие детали приватной инфраструктуры.

Secrets, private keys, passwords и рабочие credentials в Git не сохраняются.
