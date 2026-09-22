# Proxmox Bootstrap

Публичный bootstrap для первоначального развёртывания и обслуживания `910 infra-deployer` на Proxmox VE.

## Запуск

Обычная установка или повторное применение:

~~~bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/infra-iac-redesign/bootstrap-pve.sh | bash
~~~

Справка:

~~~bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/infra-iac-redesign/bootstrap-pve.sh | bash -s -- --help
~~~

Основные режимы:

~~~bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/infra-iac-redesign/bootstrap-pve.sh | bash -s -- --check
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/infra-iac-redesign/bootstrap-pve.sh | bash -s -- --recover
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/infra-iac-redesign/bootstrap-pve.sh | bash -s -- --remove
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/infra-iac-redesign/bootstrap-pve.sh | bash -s -- --purge
~~~

При первом запуске потребуется один раз добавить показанный GitHub Deploy Key в закрытый репозиторий как read-only.

Подробная архитектура, состав 910, модель доступа, параметры сети, команды эксплуатации, повторный запуск, удаление и восстановление описываются в закрытом репозитории:

~~~text
https://github.com/zsergeyru/proxmox
~~~

На физический PVE bootstrap не устанавливает Docker, Semaphore, OpenTofu, Ansible или Packer.
