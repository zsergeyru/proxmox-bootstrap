# Proxmox Bootstrap

Публичный репозиторий содержит только минимальный zero-day bootstrap для нового Proxmox VE.

Активная точка входа:

```text
init-pve.sh
```

Скрипт:

```text
проверяет Proxmox и минимальный Git/SSH runtime
→ создаёт временный read-only GitHub Deploy Key
→ если ключ ещё не авторизован, показывает public key и инструкцию
→ ждёт нажатия Enter после добавления ключа в GitHub Deploy keys
→ повторно проверяет доступ
→ делает shallow clone private repo глубиной 1 commit
→ запускает private Stage 1
→ после успешного handoff удаляет /var/lib/proxmox-bootstrap целиком
```

Если после Enter доступ к private repo не появился, выполнение завершается с явной ошибкой. При повторном запуске существующий временный private key используется повторно, а public часть восстанавливается из него.

После успешного Stage 0 постоянный Deploy Key и private checkout уже находятся в файловой структуре, созданной private Stage 1. Временный zero-day каталог не сохраняется.

В этом репозитории не хранятся внутренняя конфигурация Proxmox, роли, ACL, API-токены, планы VM/LXC, шаблоны, конфигурация AI или другие детали приватной инфраструктуры.

Секреты, private keys, passwords и рабочие credentials в Git не сохраняются.
