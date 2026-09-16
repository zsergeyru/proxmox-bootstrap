# Proxmox Bootstrap

Публичный репозиторий содержит минимальную публичную точку входа для bootstrap и последующего запуска private Stage 1 на Proxmox VE.

## Основная команда

Войдите в shell Proxmox под `root` и используйте одну и ту же команду как при первоначальной установке, так и при последующих запусках:

```bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/init-pve.sh | bash
```

Если нужно дополнительно передать private Stage 1 запрос на `apt full-upgrade`:

```bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/init-pve.sh | bash -s -- --update-system
```

Активная точка входа:

```text
init-pve.sh
```

## Первый запуск

При отсутствии marker завершённой Stage 0 скрипт выполняет zero-day bootstrap:

```text
проверяет Proxmox и минимальный Git/SSH runtime
→ создаёт временный read-only GitHub Deploy Key
→ если ключ ещё не авторизован, показывает public key и инструкцию
→ ждёт нажатия Enter после добавления ключа в GitHub Deploy keys
→ повторно проверяет доступ именно к ветке main
→ делает shallow clone private repo глубиной 1 commit
→ запускает private Stage 1
→ private Stage 1 создаёт постоянный Deploy Key/runtime и canonical checkout
→ после успешного handoff public bootstrap удаляет /var/lib/proxmox-bootstrap целиком
→ создаёт постоянный stage0-complete marker
```

Если после Enter доступ к private repo не появился, выполнение завершается с явной ошибкой. При повторном незавершённом Stage 0 запуске существующий временный private key используется повторно, а public часть восстанавливается из него.

## Повторный запуск после завершённой Stage 0

После появления постоянного marker public bootstrap **не создаёт новый Deploy Key и не повторяет zero-day setup**.

Вместо этого та же public команда выполняет безопасный updater/handoff:

```text
проверяет постоянный Linux user pvedeploy
→ проверяет canonical read-only Deploy Key и SSH runtime
→ проверяет origin /var/lib/proxmox-deployer/repo
→ подтверждает read-only доступ к zsergeyru/proxmox/main
→ fetch main
→ reset canonical checkout на полученный commit
→ clean project checkout
→ запускает уже обновлённый scripts/pve/bootstrap/init-pve.sh
```

Private key не ротируется автоматически. Если постоянный credential, SSH config или canonical checkout отсутствует/повреждён, public bootstrap останавливается и требует явного recovery вместо создания нового credential.

Постоянный private checkout:

```text
/var/lib/proxmox-deployer/repo
```

Private Stage 1:

```text
/var/lib/proxmox-deployer/repo/scripts/pve/bootstrap/init-pve.sh
```

То есть штатный повторный запуск теперь снова выполняется той же короткой командой:

```bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/init-pve.sh | bash
```

а полный system upgrade:

```bash
curl -fsSL https://raw.githubusercontent.com/zsergeyru/proxmox-bootstrap/main/init-pve.sh | bash -s -- --update-system
```

В этом репозитории не хранятся внутренняя конфигурация Proxmox, роли, ACL, API-токены, планы VM/LXC, шаблоны, конфигурация AI или другие детали приватной инфраструктуры.

Секреты, private keys, passwords и рабочие credentials в Git не сохраняются.
