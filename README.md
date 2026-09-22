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
→ создать/проверить GitHub Deploy Key
→ получить закрытый проект внутри 910
→ временно запустить из закрытого проекта PVE access helper
→ helper передаст PVE CA и ограниченный API token в 910
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

Публичный bootstrap не содержит модель PVE-прав.

После получения закрытого репозитория он временно забирает из 910:

~~~text
scripts/infra-deployer/pve-bootstrap-access.sh
~~~

и выполняет этот доверенный сценарий на PVE от root. Именно закрытый проект определяет token, pool и ACL.

После подготовки доступа временная копия сценария на PVE удаляется.

## GitHub

Deploy Key создаётся и хранится внутри 910. На PVE private key не хранится.

Если ключ ещё не зарегистрирован, bootstrap показывает public key и ждёт Enter после его добавления в:

~~~text
GitHub → zsergeyru/proxmox → Settings → Deploy keys
Allow write access: выключен
~~~

## Повторный запуск

Корректный 910 используется повторно. Закрытая ветка обновляется, после чего повторяемый внутренний setup.sh приводит 910 к текущему состоянию.

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
модель PVE-ролей и ACL внутри public bootstrap
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
