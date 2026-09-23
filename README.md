# Proxmox Bootstrap

Публичный bootstrap для первоначального развёртывания и обслуживания `910 infra-deployer` на Proxmox VE.

## Быстрый запуск

Обычная установка или повторное применение без параметров — сразу из GitHub:

~~~bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/bootstrap-pve.sh | bash
~~~

## Запуск с параметрами

Если нужны `--help`, проверка, восстановление, удаление или другие параметры, сначала скачайте сценарий:

~~~bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/bootstrap-pve.sh -o bootstrap-pve.sh
chmod +x bootstrap-pve.sh
~~~

Справка:

~~~bash
./bootstrap-pve.sh --help
~~~

Основные режимы:

~~~bash
./bootstrap-pve.sh --check
./bootstrap-pve.sh --recover
./bootstrap-pve.sh --remove
./bootstrap-pve.sh --purge
~~~

При первом запуске потребуется один раз добавить показанный GitHub Deploy Key в закрытый репозиторий как read-only.

Подробная архитектура, состав 910, модель доступа, параметры сети, команды эксплуатации, повторный запуск, удаление и восстановление описываются в закрытом репозитории:

~~~text
https://github.com/zsergeyru/proxmox
~~~

На физический PVE bootstrap не устанавливает Docker, Semaphore, OpenTofu, Ansible или Packer.
