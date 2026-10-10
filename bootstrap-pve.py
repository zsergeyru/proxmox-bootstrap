#!/usr/bin/env python3
"""Первоначальная точка входа Proxmox: подготовка временного LXC 990.

Проверяет возможность запуска на PVE, обеспечивает доступ к GitHub, создаёт
чистый временный 990, получает основной проект и передаёт управление его
закрытому исполнителю. Не определяет состояние постоянных гостей и не
принимает решений об их создании, удалении или восстановлении.

При повторном запуске прежний 990 можно удалить только после подтверждения
его принадлежности и отсутствия посторонних подключений. Данные GitHub-доступа
на PVE сохраняются; подробности ошибок записываются в технический журнал.
"""

from __future__ import annotations

import argparse
import fcntl
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

VERSION = "6.0.0-dev1"

# Параметры временного LXC 990. Этот контейнер существует только на время
# получения закрытого проекта и выполнения закрытого bootstrap.
CTID = 990
CT_HOSTNAME = "bootstrap-runner"
CT_CORES = 2
CT_MEMORY_MB = 2048
CT_SWAP_MB = 512
CT_DISK_GB = 16
CT_STORAGE = "local-lvm"
CT_BRIDGE = "vmbr0"
TEMPLATE_STORAGE = "local"

# Вся проектная оркестрация и политика доступа находятся в основном репозитории.
PROJECT_REPO = "git@github.com:zsergeyru/proxmox.git"
PROJECT_DIR = Path("/var/lib/bootstrap-runner/project")
PRIVATE_ROOT = PROJECT_DIR / "scripts/bootstrap-runner"
PRIVATE_ENTRYPOINT = PRIVATE_ROOT / "bootstrap-host.py"
CT_PRIVATE_ARCHIVE = Path("/run/proxmox-private-bootstrap.tar")

# На PVE постоянно сохраняется только read-only Deploy Key и служебный маркер
# скачанного шаблона. Остальные данные bootstrap должны быть временными.
HOST_BOOTSTRAP_DIR = Path("/root/.config/proxmox-bootstrap")
HOST_GITHUB_KEY = HOST_BOOTSTRAP_DIR / "github_proxmox_repo_ed25519"
HOST_GITHUB_PUB = Path(f"{HOST_GITHUB_KEY}.pub")
HOST_TEMPLATE_MARKER = HOST_BOOTSTRAP_DIR / "debian13-template.ref"
HOST_LOG_FILE = Path("/var/log/proxmox-bootstrap.log")
LOCK_FILE = Path("/run/lock/proxmox-bootstrap.lock")

CT_GITHUB_KEY = Path("/root/.ssh/github_proxmox_repo_ed25519")
CT_GITHUB_CONFIG = Path("/root/.ssh/github_config")
CT_GITHUB_KNOWN_HOSTS = Path("/root/.ssh/github_known_hosts")

# Закреплённый официальный Ed25519 host key GitHub не позволяет принимать
# произвольный ключ из сети при первом SSH-подключении.
GITHUB_ED25519_KNOWN_HOST = "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"


class BootstrapError(RuntimeError):
    """Ожидаемая ошибка загрузчика с сообщением для пользователя."""

    pass


def version_sort_key(value: str) -> tuple[object, ...]:
    """Сортировать имена версий естественно: 13.10 должно быть новее 13.9."""
    parts = re.split(r"(\d+)", value)
    return tuple(int(part) if part.isdigit() else part for part in parts)


class PublicBootstrap:
    """Управлять временным 990 и передачей управления основному проекту."""

    def __init__(self, project_branch: str, forward_args: list[str]) -> None:
        """Сохранить параметры запуска и подготовить счётчики времени и вывод."""
        self.project_branch = project_branch
        self.forward_args = forward_args
        self.color = not os.environ.get("NO_COLOR") and os.environ.get("TERM") != "dumb"
        self.c_reset = "\033[0m" if self.color else ""
        self.c_bold = "\033[1m" if self.color else ""
        self.c_green = "\033[32m" if self.color else ""
        self.c_blue = "\033[34m" if self.color else ""
        self.c_red = "\033[31m" if self.color else ""
        self.c_cyan = "\033[36m" if self.color else ""
        self._lock_handle = None
        self._started_at = time.monotonic()
        self._active_timing: tuple[str, float] | None = None
        self._timed_ok_count = 0
        self._section_title: str | None = None
        self._section_started = 0.0

    def finish_section(self, *, interrupted: bool = False) -> None:
        """Напечатать общее время раздела перед следующим заголовком."""

        title = self._section_title
        if title is None:
            return
        elapsed = self.format_duration(time.monotonic() - self._section_started)
        marker = "[ИТОГ]" if not interrupted else "[ПРЕРВАНО]"
        print(f"{marker} {title:<55} ({elapsed})", flush=True)
        self._section_title = None

    def log(self, message: str) -> None:
        """Начать новый раздел журнала и завершить предыдущий."""
        self.finish_section()
        self._section_title = message
        self._section_started = time.monotonic()
        print(f"\n{self.c_bold}{self.c_blue}==> {message}{self.c_reset}")

    def ok(self, message: str) -> None:
        """Показать успешный шаг и время, если вызов измеряется."""
        if self._active_timing is not None:
            _, started = self._active_timing
            message = f"{message:<55} ({self.format_duration(time.monotonic() - started)})"
            self._timed_ok_count += 1
        print(f"{self.c_bold}{self.c_green}[ОК]{self.c_reset} {message}")

    def info(self, message: str) -> None:
        """Вывести обычное информационное сообщение без изменения состояния."""
        print(f"{self.c_bold}{self.c_cyan}[ИНФО]{self.c_reset} {message}")

    def fail(self, message: str) -> None:
        """Прервать текущий этап понятной ошибкой BootstrapError."""
        raise BootstrapError(message)

    @staticmethod
    def format_duration(seconds: float) -> str:
        """Представить длительность в минутах и секундах либо часах."""
        total = max(0, int(seconds))
        hours, remainder = divmod(total, 3600)
        minutes, remaining = divmod(remainder, 60)
        if not hours:
            return f"{minutes:02d}:{remaining:02d}"
        return f"{hours:02d}:{minutes:02d}:{remaining:02d}"

    def timed_step(self, name: str, operation, *args, **kwargs):
        """Дополнить существующую строку [ОК] временем выполнения."""

        started = time.monotonic()
        previous = self._active_timing
        previous_count = self._timed_ok_count
        self._active_timing = (name, started)
        self._timed_ok_count = 0
        try:
            result = operation(*args, **kwargs)
            if not self._timed_ok_count:
                self.ok(name)
            return result
        except BootstrapError as exc:
            elapsed = self.format_duration(time.monotonic() - started)
            raise BootstrapError(f"{exc} (этап «{name}»: {elapsed})") from exc
        finally:
            self._active_timing = previous
            self._timed_ok_count = previous_count

    def run(
        self,
        *args: str,
        quiet: bool = False,
        check: bool = True,
        capture: bool = False,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        """Выполнить внешнюю команду на PVE и проверить её результат.

        quiet направляет вывод в защищённый журнал; capture возвращает вывод
        вызывающему коду; check определяет, считать ли ненулевой код ошибкой;
        env добавляет переменные окружения. При ошибке тихой команды выводятся
        последние строки журнала. В аргументах не должно быть секретов."""
        command_env = os.environ.copy()
        if env:
            command_env.update(env)

        if quiet:
            # Служебный вывод не засоряет консоль, но полностью сохраняется
            # для диагностики неудачного запуска.
            HOST_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
            with HOST_LOG_FILE.open("a", encoding="utf-8") as log:
                result = subprocess.run(
                    args,
                    text=True,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    check=False,
                    env=command_env,
                )
            if check and result.returncode:
                self.show_log_tail()
                self.fail(
                    f"Не удалось выполнить {' '.join(args)} (код {result.returncode}). "
                    f"Причина указана выше; полный журнал: {HOST_LOG_FILE}. "
                    "Исправьте ошибку и повторите запуск."
                )
            return result

        result = subprocess.run(
            args,
            text=True,
            capture_output=capture,
            check=False,
            env=command_env,
        )
        if check and result.returncode:
            if capture and result.stderr:
                print(result.stderr.rstrip(), file=sys.stderr)
            self.fail(
                f"Не удалось выполнить {' '.join(args)} (код {result.returncode}). "
                f"Проверьте результат команды и журнал {HOST_LOG_FILE}."
            )
        return result

    def show_log_tail(self) -> None:
        """Показать последние строки журнала для диагностики ошибки команды."""
        print("Последние строки технического журнала:", file=sys.stderr)
        try:
            for line in HOST_LOG_FILE.read_text(errors="replace").splitlines()[-30:]:
                print(line, file=sys.stderr)
        except OSError:
            pass
        print(f"Полный журнал: {HOST_LOG_FILE}", file=sys.stderr)

    def require_pve(self) -> None:
        """Проверить права root и наличие необходимых программ PVE."""
        if os.geteuid() != 0:
            self.fail("сценарий должен выполняться от root на PVE")
        for command in (
            "pct",
            "qm",
            "pveam",
            "pvesm",
            "ssh-keygen",
            "python3",
            "tar",
        ):
            if shutil.which(command) is None:
                self.fail(f"не найден {command}")

    def acquire_lock(self) -> None:
        """Не допустить параллельного запуска двух загрузчиков.

        Неблокирующий flock защищает операции над одним и тем же LXC 990.
        При занятой блокировке выполнение прекращается без изменений."""
        LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
        self._lock_handle = LOCK_FILE.open("a+")
        try:
            fcntl.flock(self._lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.fail("другой bootstrap уже выполняется")

    def init_log(self) -> None:
        """Подготовить защищённый журнал текущего запуска на PVE."""
        HOST_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        HOST_LOG_FILE.touch()
        HOST_LOG_FILE.chmod(0o600)
        with HOST_LOG_FILE.open("a", encoding="utf-8") as log:
            log.write(f"\n===== Public Bootstrap {VERSION} =====\n")

    def ensure_host_github_key(self) -> bool:
        """Проверить постоянный GitHub Deploy Key и вернуть признак его создания.

        Первый запуск лишь создаёт пару ключей и показывает публичный ключ
        для регистрации в GitHub. До регистрации 990 не создаётся.
        Закрытый ключ не выводится и не передаётся через сообщения."""
        # Первый запуск только создаёт ключ. 990 появится уже после того,
        # как пользователь добавит открытый ключ в GitHub.
        HOST_BOOTSTRAP_DIR.mkdir(parents=True, exist_ok=True)
        HOST_BOOTSTRAP_DIR.chmod(0o700)

        created = False
        if not HOST_GITHUB_KEY.is_file() or HOST_GITHUB_KEY.stat().st_size == 0:
            self.run(
                "ssh-keygen",
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-C",
                "proxmox-bootstrap-readonly-zsergeyru-proxmox",
                "-f",
                str(HOST_GITHUB_KEY),
            )
            created = True

        result = self.run(
            "ssh-keygen",
            "-y",
            "-f",
            str(HOST_GITHUB_KEY),
            check=False,
            capture=True,
        )
        if result.returncode:
            self.fail(f"повреждён GitHub Deploy Key: {HOST_GITHUB_KEY}")

        if created:
            self.info("Создан новый read-only Deploy Key.")
            print("Добавьте этот открытый ключ в GitHub-репозиторий zsergeyru/proxmox:")
            print()
            print(HOST_GITHUB_PUB.read_text().strip())
            print()
            print("После добавления ключа повторите ту же команду bootstrap.")
        return created

    def pct(self, *args: str, **kwargs) -> subprocess.CompletedProcess[str]:
        """Выполнить команду pct на физическом PVE."""
        return self.run("pct", *args, **kwargs)

    def ct_exec(
        self, *args: str, quiet: bool = False, check: bool = True
    ) -> subprocess.CompletedProcess[str]:
        """Выполнить команду внутри временного 990 через pct exec."""
        return self.run(
            "pct",
            "exec",
            str(CTID),
            "--",
            *args,
            quiet=quiet,
            check=check,
        )

    def ct_exists(self) -> bool:
        """Проверить наличие контейнера с зарезервированным номером 990."""
        return self.pct("config", str(CTID), check=False, capture=True).returncode == 0

    def pct_config(self) -> str:
        """Прочитать конфигурацию LXC 990 на физическом PVE."""
        return self.pct("config", str(CTID), capture=True).stdout

    def assert_owned_ct(self) -> None:
        """Подтвердить принадлежность 990 публичному загрузчику до удаления.

        Проверить имя, точные метки и признаки владения в описании.
        При дополнительных подключениях или скрипте запуска отказать:
        такой контейнер не должен удаляться автоматически."""
        if not self.ct_exists():
            self.fail(f"LXC {CTID} отсутствует")
        config = self.pct_config()
        if f"hostname: {CT_HOSTNAME}\n" not in f"{config}\n":
            self.fail(
                f"LXC {CTID}: имя не равно {CT_HOSTNAME}. "
                "Контейнер не изменён; проверьте pct config 990."
            )
        tags = next((line for line in config.splitlines() if line.startswith("tags:")), "")
        description = next(
            (line for line in config.splitlines() if line.startswith("description:")), ""
        )
        if "bootstrap-runner" not in tags.removeprefix("tags:").strip().split(";"):
            self.fail(f"LXC {CTID}: отсутствует метка bootstrap-runner. Контейнер не изменён.")
        if "proxmox-bootstrap" not in tags.removeprefix("tags:").strip().split(";"):
            self.fail(f"LXC {CTID}: отсутствует метка proxmox-bootstrap. Контейнер не изменён.")
        if "managed-by=proxmox-bootstrap" not in description.split():
            self.fail(f"LXC {CTID}: отсутствует признак владения в описании. Контейнер не изменён.")
        if "role=bootstrap-runner" not in description.split():
            self.fail(f"LXC {CTID}: неверная роль в описании. Контейнер не изменён.")
        # Не удалять контейнер, к которому могли вручную подключить данные.
        unsafe = [
            line.split(":", 1)[0] for line in config.splitlines()
            if re.fullmatch(r"(?:mp|unused|dev)\d+", line.split(":", 1)[0])
            or line.startswith("hookscript:")
        ]
        if unsafe:
            self.fail(
                f"LXC {CTID}: обнаружены дополнительные подключения "
                f"({', '.join(unsafe)}). Автоматическое удаление запрещено; "
                "проверьте pct config 990 и разберите подключения вручную."
            )

    def find_local_template(self) -> str | None:
        """Найти новейший доступный локальный шаблон Debian 13."""
        result = self.run(
            "pvesm",
            "list",
            TEMPLATE_STORAGE,
            "--content",
            "vztmpl",
            capture=True,
        )
        pattern = re.compile(
            rf"^{re.escape(TEMPLATE_STORAGE)}:vztmpl/"
            r"debian-13-standard_.*_amd64\.tar\.(?:zst|gz)$"
        )
        matches = []
        for line in result.stdout.splitlines()[1:]:
            if not line.strip():
                continue
            ref = line.split()[0]
            if pattern.match(ref):
                matches.append(ref)
        return max(matches, key=version_sort_key) if matches else None

    def ensure_template(self) -> str:
        """Получить шаблон Debian 13, если он ещё не сохранён на PVE.

        Подготовка проводится до возможного удаления старого 990, чтобы
        ошибка скачивания не уничтожила оставшуюся временную среду."""
        template = self.find_local_template()
        if template:
            return template

        self.info("Скачивается Debian 13 LXC-шаблон")
        self.run("pveam", "update", quiet=True)
        available = self.run(
            "pveam",
            "available",
            "--section",
            "system",
            capture=True,
        ).stdout

        pattern = re.compile(r"debian-13-standard_.*_amd64\.tar\.(?:zst|gz)$")
        names = []
        for line in available.splitlines():
            parts = line.split()
            if len(parts) >= 2 and pattern.fullmatch(parts[1]):
                names.append(parts[1])
        if not names:
            self.fail("не найден Debian 13 LXC-шаблон")

        name = max(names, key=version_sort_key)
        self.run("pveam", "download", TEMPLATE_STORAGE, name, quiet=True)
        HOST_BOOTSTRAP_DIR.mkdir(parents=True, exist_ok=True)
        ref = f"{TEMPLATE_STORAGE}:vztmpl/{name}"
        HOST_TEMPLATE_MARKER.write_text(f"{ref}\n")
        HOST_TEMPLATE_MARKER.chmod(0o600)
        return ref

    def create_ct(self, template_ref: str) -> None:
        """Создать новый временный LXC 990 с известной конфигурацией.

        Установить непостоянный диск, сеть, метки владения и отключить
        автозапуск. Остальные номера VM/LXC не затрагиваются."""
        self.log(f"Создание временного LXC {CTID}")

        # Параметр и его значение держим рядом: так команду pct можно читать
        # почти как её эквивалент в консоли.
        create_args = [
            "create", str(CTID), template_ref,
            "--hostname", CT_HOSTNAME,
            "--ostype", "debian",
            "--unprivileged", "1",
            "--cores", str(CT_CORES),
            "--memory", str(CT_MEMORY_MB),
            "--swap", str(CT_SWAP_MB),
            "--rootfs", f"{CT_STORAGE}:{CT_DISK_GB}",
            "--net0", f"name=eth0,bridge={CT_BRIDGE},ip=dhcp,type=veth",
            "--features", "nesting=1,keyctl=1",
            "--onboot", "0",
            "--protection", "0",
            "--tags", "bootstrap-runner;proxmox-bootstrap",
            "--description",
            "managed-by=proxmox-bootstrap role=bootstrap-runner temporary=true",
        ]
        self.pct(*create_args, quiet=True)
        self.ok(f"LXC {CTID} создан")

    def ensure_ct(self) -> None:
        """Создать чистый 990 вместо повторного использования предыдущего.

        Сначала обеспечить наличие шаблона, затем проверить принадлежность
        прежнего 990 и отсутствие дополнительных подключений. Только после
        проверок остановить и удалить прежний контейнер. Ошибка удаления
        прекращает запуск; новый контейнер не создаётся поверх старого."""
        # Не удалять старый 990, пока не подготовлен шаблон для нового.
        template_ref = self.ensure_template()
        if self.ct_exists():
            self.assert_owned_ct()
            self.log(f"Удаление предыдущего временного LXC {CTID}")
            status = self.pct("status", str(CTID), capture=True).stdout.strip()
            if status.endswith("running"):
                self.pct("stop", str(CTID), quiet=True)
            self.pct("destroy", str(CTID), "--purge", "1", quiet=True)
            if self.ct_exists():
                self.fail(
                    f"LXC {CTID} не удалён. Проверьте pct status {CTID} "
                    "и технический журнал перед повторным запуском."
                )
            self.ok(f"Предыдущий LXC {CTID} удалён")
        self.create_ct(template_ref)

    def ensure_running(self) -> None:
        """Запустить новый 990 и дождаться готовности сети.

        Проверить маршрут по умолчанию и DNS для GitHub. Ограничить число
        попыток, чтобы при неисправности сети вывести понятную ошибку."""
        status = self.pct("status", str(CTID), capture=True).stdout.split()
        if not status or status[-1] != "running":
            self.run("pct", "start", str(CTID), quiet=True)

        for _ in range(60):
            result = self.ct_exec(
                "sh",
                "-c",
                'ip -4 route show default | grep -q "^default " '
                "&& getent ahostsv4 github.com >/dev/null 2>&1",
                check=False,
            )
            if result.returncode == 0:
                self.ok(f"Сеть LXC {CTID} готова")
                return
            time.sleep(2)
        self.fail(f"сеть LXC {CTID} не готова")

    def ensure_apt_dns(self) -> None:
        """Проверить сетевой доступ к репозиториям Debian от пользователя _apt.

        Ошибочные права /etc исправляются только внутри временного 990.
        Проверка нужна до установки пакетов и не затрагивает PVE."""
        """Проверить права /etc и разрешение DNS именно от пользователя _apt."""

        mode = self.run(
            "pct", "exec", str(CTID), "--",
            "stat", "-c", "%a", "/etc", capture=True,
        ).stdout.strip()
        if mode != "755":
            self.ct_exec("chmod", "0755", "/etc", quiet=True)
            self.info(f"LXC {CTID}: права /etc исправлены ({mode} → 755)")

        for domain in ("deb.debian.org", "security.debian.org"):
            result = self.ct_exec(
                "runuser", "-u", "_apt", "--",
                "getent", "ahostsv4", domain,
                quiet=True,
                check=False,
            )
            if result.returncode != 0:
                self.fail(
                    f"LXC {CTID}: пользователь _apt не может разрешить {domain}. "
                    "Проверьте DNS и права /etc/resolv.conf"
                )
        self.ok(f"LXC {CTID}: DNS для APT проверен от пользователя _apt")

    def push_file(self, source: Path, target: Path, mode: str) -> None:
        """Передать файл из PVE в 990 с явно заданными владельцем и правами."""
        # Все файлы передаются в 990 от root с явно заданными правами.
        push_args = [
            "push", str(CTID), str(source), str(target),
            "--user", "0",
            "--group", "0",
            "--perms", mode,
        ]
        self.pct(*push_args)

    def prepare_git_access(self) -> None:
        """Создать внутри 990 временный SSH-доступ к GitHub.

        Копируется только ключ чтения проекта; ключ сервера GitHub закреплён
        заранее, чтобы не доверять произвольному ответу при первом соединении."""
        # В 990 копируется только ключ чтения закрытого проекта.
        self.ct_exec("install", "-d", "-m", "0700", "/root/.ssh")
        self.push_file(HOST_GITHUB_KEY, CT_GITHUB_KEY, "0600")

        fd, name = tempfile.mkstemp(prefix="bootstrap-runner-known-hosts.", dir="/run")
        os.close(fd)
        known_hosts = Path(name)
        try:
            known_hosts.write_text(f"{GITHUB_ED25519_KNOWN_HOST}\n")
            self.push_file(known_hosts, CT_GITHUB_KNOWN_HOSTS, "0644")
        finally:
            known_hosts.unlink(missing_ok=True)

        config = """Host github.com
    HostName github.com
    User git
    IdentityFile /root/.ssh/github_proxmox_repo_ed25519
    IdentitiesOnly yes
    UserKnownHostsFile /root/.ssh/github_known_hosts
    StrictHostKeyChecking yes
"""
        fd, name = tempfile.mkstemp(prefix="bootstrap-runner-github-config.", dir="/run")
        os.close(fd)
        config_file = Path(name)
        try:
            config_file.write_text(config)
            self.push_file(config_file, CT_GITHUB_CONFIG, "0600")
        finally:
            config_file.unlink(missing_ok=True)

    def prepare_git(self) -> None:
        """Установить Git, SSH и необходимые пакеты внутри 990.

        На физическом PVE дополнительные программы не устанавливаются."""
        self.log("Подготовка доступа к закрытому проекту")

        # На физический PVE Git не устанавливаем. Он нужен только внутри 990.
        self.ct_exec(
            "env",
            "LANG=C.UTF-8",
            "LC_ALL=C.UTF-8",
            "apt-get",
            "update",
            quiet=True,
        )
        self.ct_exec(
            "env",
            "LANG=C.UTF-8",
            "LC_ALL=C.UTF-8",
            "DEBIAN_FRONTEND=noninteractive",
            "apt-get",
            "install",
            "-y",
            "--no-install-recommends",
            "ca-certificates",
            "git",
            "openssh-client",
            "tar",
            quiet=True,
        )
        self.prepare_git_access()

    def checkout_project(self) -> None:
        """Получить выбранную ветку основного проекта в чистом 990.

        Контейнер всегда новый, поэтому используется только git clone.
        При отсутствии закрытой точки входа выполнение прекращается."""
        git_ssh = f"ssh -F {CT_GITHUB_CONFIG}"
        self.ct_exec("install", "-d", "-m", "0755", str(PROJECT_DIR.parent))
        clone_args = [
            "env", f"GIT_SSH_COMMAND={git_ssh}",
            "git", "clone",
            "--branch", self.project_branch,
            "--single-branch",
            PROJECT_REPO, str(PROJECT_DIR),
        ]
        self.ct_exec(*clone_args, quiet=True)

        if self.ct_exec("test", "-s", str(PRIVATE_ENTRYPOINT), check=False).returncode:
            self.fail(f"в закрытом проекте отсутствует {PRIVATE_ENTRYPOINT.name}")
        self.ok(f"Закрытый проект получен внутри LXC {CTID}")

    def run_private_bootstrap(self) -> None:
        """Передать управление исполнителю из основного проекта.

        Внутри 990 создать архив закрытого исполнителя, временно извлечь
        его на PVE и запустить оттуда с ограниченным набором переменных.
        Временные файлы на PVE удаляются после завершения вызова."""
        # Закрытый bootstrap состоит из точки входа и соседнего Python-пакета.
        # На PVE весь каталог переносится только на время текущего запуска.
        with tempfile.TemporaryDirectory(
            prefix="proxmox-private-bootstrap.",
            dir="/run",
        ) as temporary:
            temporary_dir = Path(temporary)
            archive = temporary_dir / "bootstrap-runner.tar"
            try:
                self.ct_exec(
                    "tar",
                    "-C",
                    str(PROJECT_DIR / "scripts"),
                    "-cf",
                    str(CT_PRIVATE_ARCHIVE),
                    "bootstrap-runner",
                )
                self.pct(
                    "pull",
                    str(CTID),
                    str(CT_PRIVATE_ARCHIVE),
                    str(archive),
                )
            finally:
                self.ct_exec(
                    "rm",
                    "-f",
                    str(CT_PRIVATE_ARCHIVE),
                    check=False,
                )

            self.run(
                "tar",
                "-C",
                str(temporary_dir),
                "-xf",
                str(archive),
            )
            helper = temporary_dir / "bootstrap-runner" / "bootstrap-host.py"
            if not helper.is_file() or helper.stat().st_size == 0:
                self.fail("закрытый bootstrap передан без bootstrap-host.py")
            helper.chmod(0o700)

            self.log("Передача управления закрытому bootstrap")
            # Явно передаём только данные, согласованные между публичной и закрытой частями.
            env = {
                "PROJECT_BRANCH": self.project_branch,
                "PROJECT_DIR": str(PROJECT_DIR),
                "BOOTSTRAP_RUNNER_CTID": str(CTID),
                "HOST_BOOTSTRAP_DIR": str(HOST_BOOTSTRAP_DIR),
                "HOST_GITHUB_KEY": str(HOST_GITHUB_KEY),
                "HOST_TEMPLATE_MARKER": str(HOST_TEMPLATE_MARKER),
                "HOST_LOG_FILE": str(HOST_LOG_FILE),
            }
            self.run("python3", str(helper), *self.forward_args, env=env)

    def remove_owned_ct_on_failure(self) -> None:
        """Удалить только собственный одноразовый 990 после ранней ошибки.

        Вызывается также при ошибке до запуска закрытого исполнителя, когда
        тот ещё не мог отозвать временные доступы или удалить контейнер.
        Проверка меток запрещает удаление постороннего или изменённого LXC.
        """
        if not self.ct_exists():
            return
        self.assert_owned_ct()
        status = self.pct("status", str(CTID), capture=True).stdout.strip()
        if status.endswith("running"):
            self.pct("stop", str(CTID), quiet=True)
        self.pct("destroy", str(CTID), "--purge", "1", quiet=True)
        if self.ct_exists():
            self.fail(f"Временный LXC {CTID} остался после ошибки")
        self.ok(f"Одноразовый LXC {CTID} удалён после ошибки")

    def execute(self) -> None:
        """Выполнить полный первоначальный путь и передать управление.

        Блокировка удерживается на протяжении всех этапов; первая генерация
        GitHub-ключа завершает работу до создания контейнера. При сбое
        последнего этапа собственный 990 удаляется; журнал остаётся на PVE."""
        # Публичная часть заканчивается после передачи управления
        # закрытому сценарию bootstrap-host.py. 990 удаляется и при раннем
        # отказе, когда закрытая часть ещё не запускалась.
        cleanup_allowed = False
        try:
            self.require_pve()
            self.acquire_lock()
            self.init_log()
            self.info(f"Public Bootstrap {VERSION}")

            if self.ensure_host_github_key():
                return
            cleanup_allowed = True

            self.timed_step("Подготовка LXC 990", self.ensure_ct)
            self.timed_step("Запуск LXC 990", self.ensure_running)
            self.timed_step("Проверка DNS для APT в 990", self.ensure_apt_dns)
            self.timed_step("Подготовка Git в 990", self.prepare_git)
            self.timed_step("Получение закрытого проекта", self.checkout_project)
            self.timed_step("Закрытый bootstrap", self.run_private_bootstrap)
        except BaseException:
            self.finish_section(interrupted=True)
            if cleanup_allowed:
                try:
                    self.remove_owned_ct_on_failure()
                except Exception as cleanup_error:
                    # Не скрывать первоначальный отказ. Чужой LXC
                    # никогда не удаляется ради завершения очистки.
                    print(
                        f"ОШИБКА: не удалось удалить временный LXC {CTID}: "
                        f"{cleanup_error}",
                        file=sys.stderr,
                    )
            raise
        else:
            self.finish_section()
            elapsed = self.format_duration(time.monotonic() - self._started_at)
            label = (
                "Восстановление завершено"
                if "--recover" in self.forward_args
                else "Bootstrap завершён"
            )
            self.ok(f"{label:<55} ({elapsed})")


def parse_args() -> argparse.Namespace:
    """Разобрать ветку проекта и признак аварийного восстановления.

    Восстановление лишь передаётся закрытому исполнителю: публичная
        часть не исследует состояние постоянных гостей."""
    parser = argparse.ArgumentParser(
        description="Минимальная публичная точка входа для закрытого Proxmox bootstrap."
    )
    parser.add_argument(
        "--project-branch",
        default=os.environ.get("PROJECT_BRANCH", "main"),
    )
    # Временная совместимость: ранее установленный PVE-only помощник
    # вызывает загрузчик с --recover. Новый помощник использует внутренний
    # признак окружения и не добавляет публичных параметров.
    parser.add_argument("--recover", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()

    if not re.fullmatch(r"[A-Za-z0-9._/-]+", args.project_branch):
        parser.error(f"некорректное имя ветки проекта: {args.project_branch}")

    internal_mode = os.environ.get("PROXMOX_BOOTSTRAP_INTERNAL_RECOVERY", "")
    if internal_mode not in {"", "1"}:
        parser.error("Некорректный внутренний режим bootstrap")
    args.forward_args = ["--recover"] if internal_mode == "1" or args.recover else []
    return args


def main() -> int:
    """Запустить загрузчик и преобразовать ошибки в понятный оператору вывод.

    Ожидаемые ошибки выводятся без стека, непредвиденные подробности
        сохраняются в техническом журнале."""
    args = parse_args()
    try:
        PublicBootstrap(args.project_branch, args.forward_args).execute()
    except (BootstrapError, OSError, subprocess.SubprocessError) as exc:
        color = not os.environ.get("NO_COLOR") and os.environ.get("TERM") != "dumb"
        prefix = "\033[1;31mОШИБКА:\033[0m" if color else "ОШИБКА:"
        print(f"\n{prefix} {exc}", file=sys.stderr)
        print(
            f"Действие: проверьте доступность PVE, сеть и журнал {HOST_LOG_FILE}; "
            "после устранения причины повторите запуск.",
            file=sys.stderr,
        )
        return 1
    except Exception as exc:
        # Не выводить оператору стек вызовов; детали сохранять для диагностики.
        import traceback

        HOST_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with HOST_LOG_FILE.open("a", encoding="utf-8") as log:
            traceback.print_exc(file=log)
        print(
            f"ОШИБКА: Неожиданный сбой публичного загрузчика: {exc}.",
            file=sys.stderr,
        )
        print(
            f"Действие: проверьте журнал {HOST_LOG_FILE} и повторите запуск "
            "после устранения причины. Контейнеры с неподтверждённой "
            "принадлежностью автоматически не удаляются.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
