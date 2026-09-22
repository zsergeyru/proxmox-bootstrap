# Proxmox Bootstrap — infra-iac-redesign

Публичный bootstrap нужен только для рождения постоянного разворачивателя 910 infra-deployer на чистом Proxmox VE и одноразового установления доверия между PVE и 910.

~~~text
чистый PVE
→ bootstrap-pve.sh на PVE
→ создать/запустить 910
→ передать bootstrap-910.sh внутрь 910
→ bootstrap-910.sh готовит 910 и получает закрытый проект
→ закрытый проект готовит одноразовый PVE helper
→ bootstrap-pve.sh выполняет helper на PVE
→ дальнейшая настройка выполняется внутри 910
~~~

На PVE публичный bootstrap не устанавливает дополнительные пакеты и не содержит внутреннюю логику infra-deployer.

## Запуск

До переноса новой архитектуры в main используется ветка:

~~~bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/infra-iac-redesign/bootstrap-pve.sh | bash
~~~

Единственное обязательное ручное действие при первом запуске — добавить показанный public Deploy Key в GitHub как read-only ключ репозитория zsergeyru/proxmox.

## Что делает bootstrap-pve.sh на PVE

~~~text
проверить root и минимальную основу PVE
→ проверить VMID 910
→ при необходимости скачать Debian 13 LXC template
→ создать 910
→ запустить 910 и дождаться сети
→ передать bootstrap-910.sh внутрь 910
→ запустить этап подготовки внутри 910
→ один раз выполнить подготовленный private PVE helper от root
→ снова передать управление 910
→ получить итоговый результат проверки
~~~

bootstrap-pve.sh не содержит список пакетов 910, GitHub Deploy Key, клонирование закрытого проекта, путь к внутреннему setup.sh или устройство Semaphore/OpenTofu/Ansible/Packer.

## Что делает bootstrap-910.sh внутри 910

~~~text
подготовить минимальный Debian
→ создать/проверить GitHub Deploy Key
→ проверить read-only доступ к закрытому проекту
→ получить/обновить закрытый проект
→ подготовить одноразовый PVE helper
→ после выдачи PVE-доступа запустить внутренний setup.sh
→ проверить готовность infra-deployer
~~~

Docker, Semaphore, OpenTofu, Ansible, Packer и остальные инструменты устанавливаются и настраиваются только внутри 910 закрытым проектом.

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

## Одноразовый доступ к PVE

Модель PVE-прав хранится только в закрытом проекте.

После получения закрытого репозитория гостевой bootstrap подготавливает:

~~~text
scripts/infra-deployer/pve-bootstrap-access.sh
~~~

bootstrap-pve.sh только передаёт этот сценарий в bash на PVE от root. Именно закрытый проект определяет API token, pool и ACL.

После этого 910 получает ограниченный API-доступ и дальше управляет PVE самостоятельно.

## GitHub

Deploy Key создаётся и хранится только внутри 910. На PVE private key не хранится.

Если ключ ещё не зарегистрирован, гостевой bootstrap показывает public key. После его добавления в:

~~~text
GitHub → zsergeyru/proxmox → Settings → Deploy keys
Allow write access: выключен
~~~

публичный host-bootstrap повторяет этап подготовки 910.

## Повторный запуск

Корректный 910 используется повторно. Гостевой bootstrap обновляет закрытую ветку, после чего повторяемая внутренняя настройка приводит 910 к текущему состоянию.

~~~bash
bootstrap-pve.sh --check
~~~

только проверяет готовое состояние через гостевой bootstrap.

~~~bash
bootstrap-pve.sh --recover
~~~

разрешает перевыпустить потерянный PVE API token при восстановлении 910.

## Что не должно появляться на PVE

Публичный host-bootstrap не должен устанавливать дополнительные пакеты и не должен содержать:

~~~text
GitHub Deploy Key или private key
git clone/fetch закрытого проекта
модель PVE-ролей и ACL
Docker
Semaphore
OpenTofu
Ansible
Packer
постоянную закрытую Git-копию
постоянные каталоги проекта
~~~

## CI

CI отдельно проверяет границу ответственности: bootstrap-pve.sh остаётся минимальным host-bootstrap, а подготовка Debian/GitHub/закрытого проекта выполняется bootstrap-910.sh внутри LXC 910.
