# Proxmox Bootstrap — infra-iac-redesign

Публичный bootstrap состоит из одного файла:

~~~text
bootstrap-pve.sh
~~~

Он всегда запускается только на PVE. Этапы оформлены отдельными функциями, а `main()` последовательно вызывает их в понятном порядке.

## Запуск

~~~bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/infra-iac-redesign/bootstrap-pve.sh | bash
~~~

## Последовательность выполнения

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

## Удаление

Удаление выполняется тем же `bootstrap-pve.sh`.

Мягкое удаление:

~~~bash
bootstrap-pve.sh --remove
~~~

Удаляет:

~~~text
LXC 910
PVE API token root@pam!infra-deployer
ACL этого token
пустой pool managed
~~~

Сохраняет:

~~~text
/root/.config/proxmox-bootstrap/
GitHub Deploy Key
Debian 13 LXC template
~~~

Это удобно, если 910 нужно пересоздать: новый контейнер получит тот же GitHub Deploy Key.

Полное удаление:

~~~bash
bootstrap-pve.sh --purge
~~~

Выполняет мягкое удаление и дополнительно удаляет:

~~~text
/root/.config/proxmox-bootstrap/
GitHub Deploy Key
Debian 13 LXC template, если bootstrap ранее отметил его как скачанный им
~~~

Чужой или заранее существовавший Debian template автоматически не удаляется.

Оба режима защищают чужие объекты: VM с VMID 910, LXC без bootstrap-меток, непустой pool `managed`, VM 100 HAOS и хранилище `backup` не удаляются.

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
