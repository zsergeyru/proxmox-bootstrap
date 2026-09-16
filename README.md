# Proxmox Bootstrap

Публичный репозиторий содержит минимальную точку входа для первоначального подключения Proxmox VE к приватному инфраструктурному репозиторию и для последующих повторных запусков конфигурации.

В проекте используются два понятных компонента:

```text
Public Bootstrap
bootstrap-pve.sh
→ получить или обновить private repo
→ запустить PVE Configuration

PVE Configuration
scripts/pve/setup/configure-pve.sh
→ привести Proxmox VE к ожидаемому состоянию проекта
```

Термины `Stage 0` и `Stage 1` больше не используются как основные названия.

## Основная команда

Войдите в shell Proxmox под `root` и используйте одну и ту же команду как при первоначальной установке, так и при последующих запусках:

```bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/bootstrap-pve.sh | bash
```

Это основной рекомендуемый запуск. Он:

```text
проверяет Public Bootstrap runtime
→ получает или обновляет zsergeyru/proxmox
→ запускает актуальную PVE Configuration
→ проверяет и применяет проектную конфигурацию PVE
```

Обычный запуск **не выполняет полный `apt full-upgrade` системы**.

## Что означает `--update-system`

`--update-system` нужен только тогда, когда вместе с обычной PVE Configuration нужно дополнительно выполнить полное обновление пакетов самого Proxmox VE / Debian.

```bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/bootstrap-pve.sh | bash -s -- --update-system
```

Это означает:

```text
обычный Public Bootstrap
→ обновить private repo
→ запустить PVE Configuration
→ выполнить обычные проверки и настройку проекта
→ дополнительно выполнить apt full-upgrade
```

Без `--update-system` PVE Configuration всё равно может выполнять `apt update` и устанавливать отсутствующие пакеты, необходимые проекту, но не обновляет без необходимости весь установленный набор системных пакетов.

### Когда использовать обычный запуск

Используйте обычную команду в большинстве случаев:

```bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/bootstrap-pve.sh | bash
```

Например, когда нужно получить свежую конфигурацию проекта, применить изменения ролей/ACL/storage/template prerequisites или повторно проверить состояние хоста.

### Когда использовать `--update-system`

Используйте этот вариант только когда осознанно хотите обновить сам Proxmox VE / Debian и все доступные системные пакеты:

```bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/bootstrap-pve.sh | bash -s -- --update-system
```

## Первый запуск: Public Bootstrap

Если постоянный marker ещё отсутствует, `bootstrap-pve.sh` выполняет первоначальное подключение хоста:

```text
проверяет Proxmox и минимальный Git/SSH runtime
→ создаёт временный read-only GitHub Deploy Key
→ если ключ ещё не авторизован, показывает public key и инструкцию
→ ждёт подтверждения после добавления Deploy Key в GitHub
→ проверяет доступ к zsergeyru/proxmox/main
→ делает temporary shallow clone private repo
→ запускает scripts/pve/setup/configure-pve.sh
→ PVE Configuration создаёт постоянный Deploy Key/runtime и canonical checkout
→ Public Bootstrap удаляет /var/lib/proxmox-bootstrap
→ создаёт /var/lib/proxmox-deployer/state/bootstrap-complete
```

Если Deploy Key не авторизован, выполнение завершается с явной ошибкой. При повторном незавершённом Public Bootstrap существующий временный private key используется повторно.

## Повторный запуск

После успешного первоначального bootstrap новая временная identity не создаётся.

Та же команда:

```bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/bootstrap-pve.sh | bash
```

выполняет:

```text
проверить постоянный Linux user pvedeploy
→ проверить canonical read-only Deploy Key и SSH runtime
→ проверить origin /var/lib/proxmox-deployer/repo
→ fetch zsergeyru/proxmox/main
→ обновить canonical checkout
→ запустить scripts/pve/setup/configure-pve.sh
```

Private key не ротируется автоматически. Если постоянный credential, SSH config или canonical checkout отсутствует/повреждён, Public Bootstrap останавливается и требует явного recovery.

Постоянный private checkout:

```text
/var/lib/proxmox-deployer/repo
```

Каноническая PVE Configuration:

```text
/var/lib/proxmox-deployer/repo/scripts/pve/setup/configure-pve.sh
```

## Совместимость со старыми командами

Старый public путь временно сохранён:

```bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/init-pve.sh | bash
```

Он показывает предупреждение и загружает `bootstrap-pve.sh`. Для новых инструкций и автоматизации следует использовать только `bootstrap-pve.sh`.

Существующий legacy marker:

```text
/var/lib/proxmox-deployer/state/stage0-complete
```

также распознаётся. После успешного повторного запуска создаётся новый marker:

```text
/var/lib/proxmox-deployer/state/bootstrap-complete
```

В этом публичном репозитории не хранятся внутренняя конфигурация Proxmox, роли, ACL, API-токены, планы VM/LXC, шаблоны, конфигурация AI или другие детали приватной инфраструктуры.

Секреты, private keys, passwords и рабочие credentials в Git не сохраняются.
