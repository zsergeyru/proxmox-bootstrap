# Proxmox Bootstrap — infra-iac-redesign

Публичный bootstrap состоит из одного файла:

~~~text
bootstrap-pve.sh
~~~

Он всегда запускается только на PVE и линейно подготавливает LXC 910 infra-deployer.

## Запуск

~~~bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/infra-iac-redesign/bootstrap-pve.sh | bash
~~~

## Последовательность

~~~text
PVE
→ проверить минимальную основу
→ создать или найти LXC 910
→ запустить 910 и дождаться сети
→ создать или использовать постоянный GitHub Deploy Key на PVE
→ установить минимальные пакеты внутри 910 через pct exec
→ скопировать GitHub Deploy Key внутрь 910
→ проверить доступ к закрытому репозиторию
→ получить или обновить закрытый репозиторий внутри 910
→ выполнить private pve-bootstrap-access.sh на PVE
→ выполнить private setup.sh внутри 910
→ проверить infra-deployer
~~~

Отдельного bootstrap-910.sh больше нет.

## Постоянный GitHub Deploy Key

Ключ хранится на PVE и переживает удаление или пересоздание LXC 910:

~~~text
/root/.config/proxmox-bootstrap/
├── github_proxmox_repo_ed25519
└── github_proxmox_repo_ed25519.pub
~~~

Права:

~~~text
/root/.config/proxmox-bootstrap                0700
github_proxmox_repo_ed25519                    0600
github_proxmox_repo_ed25519.pub                0644
~~~

При создании нового 910 bootstrap копирует этот же ключ внутрь контейнера.

Поэтому после однократного добавления public key в GitHub новый ключ при пересоздании 910 больше не требуется.

## Закрытый проект

Внутри 910 закрытый проект хранится:

~~~text
/var/lib/infra-deployer/bootstrap-repo
~~~

Источник:

~~~text
git@github.com:zsergeyru/proxmox.git
~~~

При повторном запуске bootstrap обновляет выбранную ветку проекта.

Из закрытого проекта используются:

~~~text
scripts/infra-deployer/pve-bootstrap-access.sh
scripts/infra-deployer/setup.sh
~~~

Первый сценарий выполняется на PVE и содержит политику API token, pool и ACL.

Второй выполняется внутри 910 и устанавливает Docker, Semaphore, Runner, OpenTofu, Ansible, Packer и остальные компоненты infra-deployer.

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

## Технический лог

На экран выводятся основные этапы, успешные проверки и ошибки.

Подробный вывод установки внутри 910 сохраняется:

~~~text
/var/log/infra-deployer/bootstrap.log
~~~

При ошибке выводятся последние строки этого файла.

## Повторный запуск

Обычный повторный запуск приводит существующий 910 к актуальному состоянию.

~~~bash
bootstrap-pve.sh --check
~~~

только проверяет готовность.

~~~bash
bootstrap-pve.sh --recover
~~~

разрешает перевыпустить потерянный PVE API token.

## Что остаётся на PVE

Из bootstrap-состояния постоянно хранится только GitHub Deploy Key:

~~~text
/root/.config/proxmox-bootstrap/
~~~

На PVE не устанавливаются Docker, Semaphore, OpenTofu, Ansible, Packer или закрытый Git-репозиторий.
