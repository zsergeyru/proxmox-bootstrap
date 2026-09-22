# Proxmox Bootstrap — infra-iac-redesign

Публичный bootstrap подготавливает только минимальную основу PVE и специальный LXC `910 infra-deployer`.

Основная схема:

```text
PVE
→ bootstrap-pve.sh
→ 910 infra-deployer
→ дальнейшее управление инфраструктурой из 910
```

Закрытый репозиторий `zsergeyru/proxmox`, его GitHub Deploy Key, OpenTofu, Ansible и Packer на самом PVE не хранятся.

## Ветка разработки

Новая архитектура пока находится в ветке:

```text
infra-iac-redesign
```

Для проверки именно этой версии:

```bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/infra-iac-redesign/bootstrap-pve.sh | bash
```

До переноса в `main` эта команда является тестовой.

## Что делает bootstrap

Обычный первый запуск:

```text
проверить PVE
→ получить блокировку
→ проверить vmbr0, local и local-lvm
→ сохранить резервную копию критичной конфигурации
→ получить Debian 13 LXC template
→ проверить VMID 910
→ создать 910 infra-deployer
→ запустить 910
→ подготовить минимальный Debian
→ установить доверие к PVE CA
→ создать ограниченную PVE API identity
→ передать одноразовый API secret в 910
→ создать GitHub Deploy Key внутри 910
→ получить закрытый проект уже из 910
→ передать управление scripts/infra-deployer/setup.sh
→ проверить результат
```

Bootstrap не создаёт остальные VM/LXC.

## Контракт 910

Текущие параметры создания:

```text
CTID:        910
hostname:    infra-deployer
type:        LXC
OS:          Debian 13
unprivileged yes
CPU:         2
RAM:         2048 MiB
swap:        512 MiB
root disk:   32 GiB
storage:     local-lvm
bridge:      vmbr0
onboot:      yes
protection:  yes
features:    nesting=1,keyctl=1
```

Эти значения принадлежат публичному bootstrap, потому что он создаёт `910` ещё до появления доступа к закрытому проекту.

## Сеть

По умолчанию первый запуск использует DHCP:

```bash
bootstrap-pve.sh
```

Статический адрес можно указать явно:

```bash
bootstrap-pve.sh --ip 192.168.1.90/24 --gateway 192.168.1.1
```

Bootstrap намеренно не вычисляет адрес из VMID и не предполагает, что фактическая сеть имеет префикс `/16`.

## Повторный запуск

Если `910` уже существует, bootstrap сначала проверяет его принадлежность:

```text
CTID 910
+ hostname infra-deployer
+ tag infra-deployer
+ tag proxmox-bootstrap
```

Чужой LXC или VM с VMID `910` блокирует запуск.

Корректный существующий `910` повторно используется. Bootstrap не удаляет и не пересоздаёт его автоматически.

Изменение CPU/RAM и других ресурсов существующего `910` не выполняется скрытно: расхождение выводится как предупреждение.

## Проверка без изменений

```bash
bootstrap-pve.sh --check
```

Режим не создаёт LXC, не устанавливает пакеты, не скачивает шаблоны и не ротирует credentials.

## Восстановление

```bash
bootstrap-pve.sh --recover
```

Это явный режим для восстановления bootstrap-контура.

Он может создать отсутствующий `910` и явно перевыпустить API token. Неизвестный объект с VMID `910` всё равно не удаляется.

## PVE API

Используется техническая идентичность:

```text
infra-deployer@pve!automation
```

Токен использует `privsep=1`. Пользователь и токен получают одинаковые прямые ACL:

```text
/                                 → PVEAuditor
/pool/managed                     → InfraManagedGuest
/vms/9000                         → PVETemplateUser
/storage/local-lvm                → PVEDatastoreUser
/sdn/zones/localnetwork/vmbr0     → PVESDNUser
```

`InfraManagedGuest` — единственная собственная роль. Она даёт жизненный цикл обычных VM/LXC только внутри `managed`.

Bootstrap не выдаёт `PVEAdmin`, `Pool.Allocate`, `Permissions.Modify`, `Sys.Modify`, консольные, backup или snapshot-права.

Отдельно проверяется, что на `/vms/910` у token отсутствуют любые изменяющие VM privileges.

## GitHub

GitHub Deploy Key создаётся внутри `910`.

Он даёт только чтение:

```text
git@github.com:zsergeyru/proxmox.git
```

Если ключ ещё не добавлен в GitHub, bootstrap выводит public key и ждёт подтверждение пользователя.

На PVE этот private key не хранится.

## Передача управления закрытому проекту

После получения закрытой ветки внутри `910` bootstrap запускает:

```text
scripts/infra-deployer/setup.sh
```

Эта точка входа уже реализована в приватной ветке `infra-iac-redesign`. Она устанавливает Docker Engine, Semaphore Server/Runner, настраивает проект `Proxmox Infrastructure`, Key Store, Git repository и команду `infra-deployer-status`.

Bootstrap считает `910` готовым только после успешного выполнения этой внутренней проверки.

Код прошёл статические CI-проверки, но полный цикл ещё должен быть проверен на реальном PVE перед переносом ветки в `main`.

## Что удалено из старой архитектуры

Новый bootstrap больше не использует:

```text
pvedeploy
/etc/proxmox-deployer/
/var/lib/proxmox-deployer/
/var/lib/proxmox-deployer/repo
deploy-guest
sync-management-keys
PVE Configuration
PVE_CONFIGURATION_SOURCE_REVISION
--update-system
--smoke-test-template
```

## Блокировка

Используется:

```text
/run/lock/proxmox-bootstrap.lock
```

Одновременно выполняется только один bootstrap.

## CI

Репозиторий продолжает проверять:

```text
bash -n
ShellCheck
git diff --check
```
