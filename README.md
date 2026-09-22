# Proxmox Bootstrap

Публичный bootstrap для первоначального развёртывания и обслуживания `910 infra-deployer` на Proxmox VE.

Основной файл:

~~~text
bootstrap-pve.sh
~~~

Он запускается на PVE от `root`, создаёт или проверяет LXC 910, подготавливает доступ к закрытому проекту и передаёт дальнейшую настройку закрытому репозиторию `zsergeyru/proxmox`.

## Запуск

Текущая рабочая ветка:

~~~bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/infra-iac-redesign/bootstrap-pve.sh | bash
~~~

При первом запуске потребуется один раз добавить показанный GitHub Deploy Key в закрытый репозиторий как read-only.

## Режимы

~~~text
без параметров   установка или повторное применение
--check          проверка готовности
--recover        восстановление PVE API token
--remove         мягкое удаление с сохранением GitHub Deploy Key
--purge          полное удаление bootstrap-состояния
~~~

Подробная архитектура, состав 910, модель доступа, команды эксплуатации, повторный запуск, удаление и восстановление описываются в закрытом репозитории:

~~~text
https://github.com/zsergeyru/proxmox
~~~

На физический PVE bootstrap не устанавливает Docker, Semaphore, OpenTofu, Ansible или Packer.
