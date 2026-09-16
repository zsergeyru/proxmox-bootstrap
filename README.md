# Proxmox Bootstrap

Публичный репозиторий содержит минимальную точку входа для первоначального подключения Proxmox VE к приватному инфраструктурному репозиторию и для последующих повторных запусков конфигурации.

Текущая версия Public Bootstrap:

```text
PUBLIC_BOOTSTRAP_VERSION=10
```

В проекте два компонента:

```text
Public Bootstrap
bootstrap-pve.sh
→ безопасно получить или обновить private repo
→ выбрать точную Git revision
→ удерживать общую orchestration lock
→ поддерживать root trust boundary canonical source
→ запустить PVE Configuration из этой revision

PVE Configuration
zsergeyru/proxmox/scripts/pve/setup/configure-pve.sh
→ привести Proxmox VE к ожидаемому состоянию проекта
```

## Основная команда

Войдите в shell Proxmox под `root` и используйте одну и ту же команду при первоначальной установке, последующих запусках и продолжении незавершённого first run:

```bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/bootstrap-pve.sh | bash
```

Обычный запуск не выполняет полный `apt full-upgrade`.

Для осознанного полного обновления Proxmox VE / Debian:

```bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/bootstrap-pve.sh | bash -s -- --update-system
```

## Общая orchestration lock

Public Bootstrap и private PVE Configuration используют одну lock:

```text
/run/lock/proxmox-orchestration.lock
```

Bootstrap берёт lock до работы с private checkout и держит её до полного завершения PVE Configuration. Lock передаётся child process через открытый fd.

Поэтому одновременно не выполняются:

```text
bootstrap + bootstrap
bootstrap + configure-pve.sh
configure-pve.sh + configure-pve.sh
```

Это исключает ситуацию, когда canonical checkout переключается на другую revision в середине configuration run.

## Первый запуск

Если permanent marker отсутствует и canonical runtime ещё не создан:

```text
root + Proxmox check
→ shared orchestration lock
→ minimal Git/SSH packages
→ DNS/HTTPS GitHub check
→ temporary read-only GitHub Deploy Key
→ authorization private repo/main
→ temporary shallow checkout root:root
→ определить exact HEAD private repo
→ передать SHA в PVE Configuration
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

Если Deploy Key ещё не добавлен в GitHub, Public Bootstrap показывает public key и ждёт подтверждение пользователя через терминал. Write access не включается.

## Продолжение незавершённого первого запуска

Если PVE Configuration была прервана после частичного или полного создания permanent runtime, **не нужно удалять `/etc/proxmox-deployer` или `/var/lib/proxmox-deployer`**.

Та же команда безопасно продолжает работу. Существующие API token secrets и SSH private keys не удаляются и не ротируются автоматически.

Если permanent runtime уже содержит `pvedeploy`, canonical Deploy Key, SSH config/known_hosts и canonical checkout, Public Bootstrap использует их как permanent runtime и повторно запускает текущую PVE Configuration.

Если runtime создан только частично, first-run path продолжается через temporary runtime. Временный checkout считается одноразовым: перед повторным handoff он переводится на свежий `FETCH_HEAD` и очищается через `git clean -ffdx`, включая ignored cache/build artifacts. Это предотвращает ложный STOP строгой source-проверки из-за `__pycache__`, `.cache` и других временных файлов. Permanent checkout такого destructive cleanup не получает.

## Root trust boundary canonical source

Canonical repository и Git credential являются частью root-trusted host configuration, а не рабочего пространства `pvedeploy`.

Ожидаемая модель:

```text
/var/lib/proxmox-deployer
→ root:pvedeploy 0750

/var/lib/proxmox-deployer/repo
→ root-owned tree
→ group/other write запрещён

/etc/proxmox-deployer/ssh/github_proxmox_repo_ed25519
→ root:root 0600

/etc/proxmox-deployer/ssh/config
→ root:root 0600
```

`pvedeploy` может читать project source через parent directory, но не может менять canonical checkout, `.git` metadata или GitHub Deploy Key. Это не мешает будущему `deploy-guest` читать manifests/scripts, но не позволяет ограниченному runtime user подменить код, который позже будет исполнен `root`.

Public Bootstrap v10 автоматически переводит существующий старый `pvedeploy`-owned checkout/credential в эту модель до запуска PVE Configuration. После миграции каждый handoff дополнительно проверяет ownership и отсутствие group/other write.

## Повторный запуск после завершённого bootstrap

При наличии:

```text
/var/lib/proxmox-deployer/state/bootstrap-complete
```

используется permanent runtime:

```text
pvedeploy
/etc/proxmox-deployer/ssh/github_proxmox_repo_ed25519
/etc/proxmox-deployer/ssh/config
/etc/proxmox-deployer/ssh/known_hosts
/var/lib/proxmox-deployer/repo
```

Перед любым reset Public Bootstrap проверяет:

```text
root trust boundary canonical source
origin == git@github.com:zsergeyru/proxmox.git
canonical worktree полностью clean
```

Clean означает отсутствие tracked, staged, untracked и ignored drift.

Если локальный drift обнаружен, Bootstrap делает STOP и **не выполняет destructive reset/clean поверх локальных данных**.

Для clean checkout алгоритм:

```text
проверить root ownership / write boundary
→ проверить read-only доступ к zsergeyru/proxmox/main
→ fetch main от root
→ reset --hard FETCH_HEAD
→ clean -ffd
→ повторно подтвердить trust boundary + clean state
→ определить SHA
→ запустить PVE Configuration с PVE_CONFIGURATION_SOURCE_REVISION=<SHA>
```

Private credential не ротируется автоматически. Повреждённый permanent runtime требует явного recovery.

## Одна revision на один configuration run

После выбора private revision Public Bootstrap передаёт:

```text
PVE_CONFIGURATION_SOURCE_REVISION=<40-char SHA>
PVE_ORCHESTRATION_LOCK_HELD=1
```

PVE Configuration до загрузки своих модулей проверяет, что source checkout имеет именно этот HEAD, не содержит local drift и является root-owned/non-writable для `pvedeploy` или других non-root users. Canonical checkout после sync также обязан совпасть с source SHA.

Если `main` изменится между temporary checkout и canonical clone/fetch, текущий run остановится вместо смешивания commits.

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

## CI

Public repository checks включают:

```text
bash -n
ShellCheck
whitespace check
```

Private repository выполняет дополнительные runtime/template/validator tests.

В публичном репозитории не хранятся внутренняя конфигурация Proxmox, роли, ACL, API tokens, планы VM/LXC, template implementation, конфигурация AI или другие детали приватной инфраструктуры.

Secrets, private keys, passwords и рабочие credentials в Git не сохраняются.
