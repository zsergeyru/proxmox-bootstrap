# Proxmox Bootstrap — infra-iac-redesign

Публичный bootstrap нужен только для запуска постоянного разворачивателя 910 infra-deployer на чистом Proxmox VE.

~~~text
чистый PVE
→ bootstrap-pve.sh
→ создать/запустить 910
→ выдать 910 ограниченный PVE API token
→ создать GitHub Deploy Key внутри 910
→ получить закрытый проект
→ передать управление setup.sh внутри 910
~~~

После передачи управления публичный bootstrap не знает внутреннего устройства 910. Docker, Semaphore, OpenTofu, Ansible и Packer настраиваются закрытым проектом внутри контейнера.

## Запуск

До переноса новой архитектуры в main используется ветка:

~~~bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/infra-iac-redesign/bootstrap-pve.sh | bash
~~~

Единственное обязательное ручное действие при первом запуске — добавить показанный public Deploy Key в GitHub как read-only ключ репозитория zsergeyru/proxmox. После этого bootstrap продолжает работу автоматически.

## Что делает bootstrap

~~~text
проверить root и минимальную основу PVE
→ проверить VMID 910
→ при необходимости скачать Debian 13 LXC template
→ создать 910
→ запустить 910 и дождаться сети
→ установить минимальные Git/SSH/curl зависимости
→ передать PVE CA
→ создать pool managed
→ создать root@pam!infra-deployer с privsep=1
→ назначить token только необходимые ACL
→ передать secret в 910
→ создать/проверить GitHub Deploy Key
→ получить закрытый проект внутри 910
→ запустить scripts/infra-deployer/setup.sh
→ выполнить внутреннюю проверку 910
~~~

Bootstrap не настраивает Semaphore, OpenTofu, Ansible или Packer сам.

## Контракт 910

~~~text
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
~~~

Чужой LXC или VM с VMID 910 автоматически не заменяется.

## PVE API

Отдельный PVE-пользователь не создаётся. Используется API token существующего root@pam:

~~~text
root@pam!infra-deployer
~~~

Token создаётся с privsep=1. Это не даёт 910 права root: token получает только назначенные ему ACL.

~~~text
/                                 → PVEAuditor
/pool/managed                     → PVEVMAdmin
/storage/local-lvm                → PVEDatastoreUser
/sdn/zones/localnetwork/vmbr0     → PVESDNUser
/vms/9000                         → PVETemplateUser
~~~

Таким образом, изменяющие VM-права находятся только внутри managed; 910 в этот pool не входит.

## GitHub

Deploy Key создаётся и хранится внутри 910. На PVE private key не хранится.

Если ключ ещё не зарегистрирован, bootstrap показывает public key и ждёт Enter после его добавления в:

~~~text
GitHub → zsergeyru/proxmox → Settings → Deploy keys
Allow write access: выключен
~~~

## Повторный запуск

Корректный 910 используется повторно. Закрытая ветка обновляется, а внутренний setup.sh запускается только при новой ревизии проекта.

~~~bash
bootstrap-pve.sh --check
~~~

только проверяет готовое состояние.

~~~bash
bootstrap-pve.sh --recover
~~~

разрешает перевыпустить потерянный PVE API token при восстановлении 910.

## Что больше не используется

Публичному bootstrap не нужны:

~~~text
pvedeploy
отдельный infra-deployer@pve
InfraManagedGuest
двойные ACL user + token
PVE Configuration
deploy-guest
sync-management-keys
постоянная закрытая Git-копия на PVE
знание о Semaphore/OpenTofu/Ansible/Packer
~~~

## CI

Проверяются синтаксис shell, ShellCheck и пробельные ошибки.
