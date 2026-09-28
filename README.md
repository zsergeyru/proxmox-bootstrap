# Proxmox Bootstrap

Минимальная публичная точка входа для закрытого проекта `zsergeyru/proxmox`. `bootstrap-pve.sh` является только коротким загрузчиком; основная публичная логика находится в `bootstrap-pve.py`.

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

При первом запуске `bootstrap-pve.py` создаёт Deploy Key, показывает открытый ключ и завершает работу **до создания LXC 990**. Добавьте ключ в закрытый репозиторий как read-only и повторите ту же команду.

Публичная часть не содержит логику 910, PVE API-права, OpenTofu или Ansible. `bootstrap-pve.py` создаёт временный LXC 990, передаёт read-only Deploy Key, получает закрытый проект и запускает его `scripts/bootstrap-runner/bootstrap-host.py`.

Подробная архитектура, состав 910, модель доступа, параметры сети, команды эксплуатации, повторный запуск, удаление и восстановление описываются в закрытом репозитории:

~~~text
https://github.com/zsergeyru/proxmox
~~~

На физический PVE bootstrap не устанавливает Docker, Semaphore, OpenTofu, Ansible или Packer.
