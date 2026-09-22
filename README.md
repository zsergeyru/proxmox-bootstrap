# Proxmox Bootstrap

Публичный bootstrap предназначен для первоначального развёртывания и обслуживания LXC 910 `infra-deployer` на чистом Proxmox VE.

В публичном репозитории используется один основной сценарий:

~~~text
bootstrap-pve.sh
~~~

Он всегда запускается на PVE от `root`. Отдельного `bootstrap-910.sh` нет.

## Назначение

`bootstrap-pve.sh` отвечает только за начальную подготовку управляющего контейнера 910 и передачу управления закрытому проекту.

Общая схема:

~~~text
PVE
→ bootstrap-pve.sh
→ создать или проверить LXC 910
→ подготовить минимальный Debian внутри 910
→ передать постоянный GitHub Deploy Key
→ получить закрытый проект zsergeyru/proxmox
→ выполнить закрытую настройку доступа к PVE
→ выполнить закрытую настройку infra-deployer внутри 910
→ проверить итоговое состояние
~~~

Docker, Semaphore, OpenTofu, Ansible, Packer и остальные рабочие компоненты устанавливаются только внутри 910 закрытым проектом.

На физический PVE bootstrap не устанавливает дополнительные пакеты.

## Запуск

Текущая рабочая ветка:

~~~bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/infra-iac-redesign/bootstrap-pve.sh | bash
~~~

Справка:

~~~bash
bootstrap-pve.sh --help
~~~

## Последовательность установки

Основной `main()` вызывает этапы в понятном порядке:

~~~text
проверить PVE
→ получить блокировку bootstrap
→ проверить хранилища и vmbr0
→ создать или проверить LXC 910
→ запустить 910
→ дождаться сети и DNS
→ создать или использовать постоянный GitHub Deploy Key на PVE
→ установить минимальные пакеты внутри 910
→ передать GitHub Deploy Key внутрь 910
→ проверить read-only доступ к закрытому проекту
→ получить или обновить закрытый проект внутри 910
→ выполнить scripts/infra-deployer/pve-bootstrap-access.sh на PVE
→ выполнить scripts/infra-deployer/setup.sh внутри 910
→ проверить infra-deployer
~~~

Детали каждого этапа оформлены отдельными функциями, а `main()` задаёт только последовательность их выполнения.

## LXC 910

Параметры создаваемого контейнера:

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
tags:        infra-deployer;proxmox-bootstrap
~~~

Bootstrap не заменяет автоматически чужой объект с VMID 910.

Если VMID 910 занят виртуальной машиной либо LXC не имеет ожидаемого hostname и bootstrap-меток, выполнение прекращается.

## Debian 13 template

Если подходящий Debian 13 LXC template уже существует в `local:vztmpl`, bootstrap использует его и не считает своим.

Если template отсутствует:

~~~text
bootstrap
→ скачивает Debian 13 template
→ отмечает его как временный
→ создаёт LXC 910
→ сразу удаляет скачанный template
~~~

После успешного создания 910 скачанный bootstrap template на PVE не остаётся.

Если запуск прервался после скачивания template, временный template будет удалён при следующем `--remove` или `--purge`.

Заранее существовавший чужой template автоматически не удаляется.

## Постоянный GitHub Deploy Key

GitHub Deploy Key хранится вне 910, непосредственно на PVE:

~~~text
/root/.config/proxmox-bootstrap/
├── github_proxmox_repo_ed25519
└── github_proxmox_repo_ed25519.pub
~~~

Права:

~~~text
/root/.config/proxmox-bootstrap/               0700
github_proxmox_repo_ed25519                    0600
github_proxmox_repo_ed25519.pub                0644
~~~

При первом запуске bootstrap создаёт ключ и, если доступа к закрытому проекту ещё нет, показывает public key для однократного добавления в GitHub:

~~~text
GitHub
→ zsergeyru/proxmox
→ Settings
→ Deploy keys
→ Add deploy key
→ Allow write access: выключен
~~~

При последующих пересозданиях 910 используется тот же ключ. Повторно добавлять Deploy Key в GitHub не требуется.

## Закрытый проект

Закрытый репозиторий:

~~~text
git@github.com:zsergeyru/proxmox.git
~~~

Рабочая копия внутри 910:

~~~text
/var/lib/infra-deployer/bootstrap-repo
~~~

По умолчанию используется ветка:

~~~text
infra-iac-redesign
~~~

При повторном запуске bootstrap выполняет обновление этой ветки и приводит рабочую копию к её текущему состоянию.

Основные сценарии закрытого проекта:

~~~text
scripts/infra-deployer/pve-bootstrap-access.sh
scripts/infra-deployer/setup.sh
~~~

`pve-bootstrap-access.sh` выполняется на PVE от `root` и содержит политику доступа 910 к Proxmox:

~~~text
pool managed
PVE API token root@pam!infra-deployer
ACL для token
PVE CA для 910
~~~

`setup.sh` выполняется внутри 910 и настраивает:

~~~text
Docker Engine
Semaphore Server
Semaphore Runner
OpenTofu
Ansible
Packer
proxmoxer
служебные команды infra-deployer
~~~

Политика PVE-прав находится только в закрытом проекте и не дублируется в публичном bootstrap.

## Постоянное состояние на PVE

После успешной установки из bootstrap-состояния на PVE постоянно остаётся только:

~~~text
/root/.config/proxmox-bootstrap/
└── GitHub Deploy Key
~~~

Кроме этого, остаются штатные сущности Proxmox, необходимые для работы 910:

~~~text
LXC 910
pool managed
PVE API token root@pam!infra-deployer
ACL token
~~~

На PVE не остаются:

~~~text
Debian template, скачанный bootstrap
закрытая Git-копия проекта
Docker
Semaphore
OpenTofu
Ansible
Packer
каталоги /etc/infra-deployer
каталоги /var/lib/infra-deployer
~~~

Рабочие данные infra-deployer находятся внутри LXC 910.

## Технический лог

На экран выводятся основные этапы, успешные проверки, предупреждения и ошибки.

Подробный технический вывод команд внутри 910 сохраняется:

~~~text
/var/log/infra-deployer/bootstrap.log
~~~

Туда попадает служебный вывод установки пакетов, Git и других длительных операций.

Если команда внутри 910 завершается ошибкой, bootstrap показывает последние строки технического лога и путь к полному файлу.

## Режимы

Обычная установка или повторное приведение 910 к актуальному состоянию:

~~~bash
bootstrap-pve.sh
~~~

Проверка готового состояния без переустановки:

~~~bash
bootstrap-pve.sh --check
~~~

Восстановление потерянного PVE API token:

~~~bash
bootstrap-pve.sh --recover
~~~

Мягкое удаление:

~~~bash
bootstrap-pve.sh --remove
~~~

Полное удаление:

~~~bash
bootstrap-pve.sh --purge
~~~

Для статического адреса 910:

~~~bash
bootstrap-pve.sh --ip 192.168.1.90/24 --gateway 192.168.1.1
~~~

Для другой ветки закрытого проекта:

~~~bash
bootstrap-pve.sh --project-branch NAME
~~~

## Мягкое удаление

~~~bash
bootstrap-pve.sh --remove
~~~

Удаляет:

~~~text
LXC 910
PVE API token root@pam!infra-deployer
ACL этого token
pool managed, если он пуст
временный Debian template bootstrap, если он остался после прерванного запуска
~~~

Сохраняет:

~~~text
/root/.config/proxmox-bootstrap/
GitHub Deploy Key
~~~

Мягкое удаление предназначено для пересоздания 910 без повторной регистрации GitHub Deploy Key.

## Полное удаление

~~~bash
bootstrap-pve.sh --purge
~~~

Выполняет всё мягкое удаление и дополнительно удаляет:

~~~text
/root/.config/proxmox-bootstrap/
GitHub Deploy Key
~~~

После `--purge` следующий запуск будет считаться новой установкой и создаст новый Deploy Key.

## Защита от лишнего удаления

Режимы удаления не должны превращаться в общую очистку PVE.

Bootstrap не удаляет автоматически:

~~~text
VM 100 HAOS
хранилище backup
чужую VM с VMID 910
чужой LXC с VMID 910
LXC 910 без ожидаемых bootstrap-меток
непустой pool managed
заранее существовавший Debian template
другие VM и LXC
~~~

Если `managed` содержит участников или сторонние ACL, pool сохраняется с предупреждением.

Для полной лабораторной очистки PVE в репозитории остаётся отдельный служебный сценарий `reset-pve-clean-slate.sh`; он не является частью обычного жизненного цикла infra-deployer.

## Повторный запуск

Bootstrap рассчитан на повторное выполнение.

Для существующего 910 он:

~~~text
проверяет контейнер
→ проверяет сеть
→ использует постоянный GitHub Deploy Key
→ обновляет закрытый проект
→ повторно применяет настройку PVE-доступа
→ повторно выполняет setup.sh
→ проверяет итоговое состояние
~~~

Повторный запуск не должен требовать нового GitHub Deploy Key и не должен пересоздавать корректный LXC 910.

## Граница публичного bootstrap

Публичный сценарий содержит только начальную оркестрацию:

~~~text
PVE
LXC 910
GitHub Deploy Key
получение закрытого проекта
вызов закрытых сценариев
проверка состояния
удаление bootstrap-состояния
~~~

Он не содержит конкретную модель ролей и ACL Proxmox и не содержит внутреннюю логику настройки Semaphore/OpenTofu/Ansible/Packer.
