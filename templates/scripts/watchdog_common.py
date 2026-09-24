"""Общее для сторожа целостности: настройки, снимок состояния, эталон.

Эталон снимается ПОСЛЕ приёмки, по принятому состоянию докрута. Снятый
раньше, он превращает каждый перенесённый файл в находку, и сторожа
выключают на второй день.

Снимок состояния: файлы тома сайта (путь, размер, sha256, права), число
пользователей и опубликованных объектов по запросам адаптера, публичный
robots.txt побайтово. Том читается свежим контейнером из образа приложения,
без сети и только на чтение: работающему приложению сторож не доверяет.
Число пользователей и объектов считает админ базы по сокету, без пароля.

Сторож CMS-агностичный. Что считать пользователем и опубликованным объектом,
знает адаптер: он пишет запросы в watchdog.conf.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tarfile
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

SLUG = "{{SLUG}}"
DB_CONTAINER = SLUG + "-mariadb"
SITE_VOLUME = SLUG + "_site_data"
HELPER_IMAGE = SLUG + "-php-fpm:local"

STACK = Path(__file__).resolve().parents[1]
CONF_PATH = Path(os.environ.get("WATCHDOG_CONF", STACK / "watchdog.conf"))


class ConfigError(Exception):
    """Настройки неполны или опасны: код 2, прогон бессмыслен."""


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _norm(path: str) -> str:
    return path.strip().strip("/")


class Config:
    def __init__(self, path: Path = CONF_PATH) -> None:
        if not path.is_file():
            raise ConfigError(f"нет файла настроек: {path}")
        single: dict[str, str] = {}
        excludes: list[str] = []
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line or line.lstrip().startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key, value = key.strip(), value.strip()
            if key == "exclude":
                excludes.append(value)
            else:
                # Как в backup.conf: побеждает последняя строка.
                single[key] = value
        self.state_dir = Path(single.get("state_dir") or STACK / "watchdog")
        self.robots_url = single.get("robots_url", "")
        self.db_name = single.get("db_name", "")
        self.users_sql = single.get("users_sql", "")
        self.objects_sql = single.get("objects_sql", "")
        self.uploads = _norm(single.get("uploads", ""))
        self.notify_command = single.get("notify_command", "")
        self.excludes = [_norm(e) for e in excludes]

        if not self.uploads:
            raise ConfigError("uploads не задан: сторож обязан знать, какой каталог нельзя исключать")
        for excl in self.excludes:
            # Исключение, накрывающее загрузки целиком или изнутри, прячет
            # ровно то место, куда подсаживают файлы чаще всего.
            if not excl or self.uploads == excl or self.uploads.startswith(excl + "/") \
                    or excl.startswith(self.uploads + "/"):
                raise ConfigError(
                    f"исключение {excl or '(пустое)'!r} накрывает каталог загрузок {self.uploads!r}: так нельзя"
                )
        if not self.robots_url:
            raise ConfigError("robots_url не задан")
        if (self.users_sql or self.objects_sql) and not self.db_name.replace("_", "").isalnum():
            raise ConfigError(f"db_name пуст или не из [A-Za-z0-9_]: {self.db_name!r}")

    @property
    def baseline_path(self) -> Path:
        return self.state_dir / "baseline.json"

    @property
    def log_path(self) -> Path:
        return self.state_dir / "log.md"

    def excluded(self, path: str) -> bool:
        return any(path == e or path.startswith(e + "/") for e in self.excludes)


def snapshot_files(cfg: Config) -> dict[str, dict]:
    """Файлы тома: путь -> размер, sha256, права. Ссылки -> их цель."""
    files: dict[str, dict] = {}
    # stderr в файл, а не в трубу: tar, пишущий много предупреждений, упёрся бы
    # в полный буфер трубы, пока мы читаем stdout, и прогон бы повис.
    with tempfile.TemporaryFile() as err:
        proc = subprocess.Popen(
            ["docker", "run", "--rm", "--network", "none", "--entrypoint", "tar",
             "-v", f"{SITE_VOLUME}:/site:ro", HELPER_IMAGE, "-C", "/site", "-cf", "-", "."],
            stdout=subprocess.PIPE, stderr=err,
        )
        assert proc.stdout is not None
        try:
            with tarfile.open(fileobj=proc.stdout, mode="r|") as archive:
                for member in archive:
                    path = member.name[2:] if member.name.startswith("./") else member.name
                    if not path or path == "." or cfg.excluded(path):
                        continue
                    if member.isfile():
                        digest = hashlib.sha256()
                        handle = archive.extractfile(member)
                        assert handle is not None
                        for chunk in iter(lambda: handle.read(1 << 20), b""):
                            digest.update(chunk)
                        files[path] = {"size": member.size, "sha256": digest.hexdigest(), "mode": oct(member.mode)}
                    elif member.issym() or member.islnk():
                        files[path] = {"link": member.linkname}
        except tarfile.TarError as exc:
            # Пустой или оборванный поток это «не смог проверить», а не находка.
            proc.kill()
            proc.wait()
            err.seek(0)
            raise RuntimeError(f"том {SITE_VOLUME} не читается: {exc}; "
                               f"{err.read().decode(errors='replace').strip()}") from exc
        finally:
            proc.stdout.close()
        proc.wait()
        err.seek(0)
        if proc.returncode != 0:
            raise RuntimeError(f"том {SITE_VOLUME} не читается: {err.read().decode(errors='replace').strip()}")
    if not files:
        raise RuntimeError(f"в томе {SITE_VOLUME} не нашлось ни одного файла")
    return files


def count(cfg: Config, query: str) -> int | None:
    if not query:
        return None
    result = subprocess.run(
        ["docker", "exec", "-u", "mysql", DB_CONTAINER, "mariadb", "-N", "-B", cfg.db_name, "-e", query],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"запрос {query!r} не выполнился: {result.stderr.strip()}")
    value = result.stdout.strip()
    if not value.isdigit():
        raise RuntimeError(f"запрос {query!r} вернул не одно число: {value[:80]!r}")
    return int(value)


def fetch_robots(cfg: Config) -> dict:
    request = urllib.request.Request(cfg.robots_url, headers={"User-Agent": "integrity-watchdog"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            status, body = response.status, response.read()
    except urllib.error.HTTPError as exc:
        status, body = exc.code, exc.read()
    return {"status": status, "sha256": hashlib.sha256(body).hexdigest(),
            "text": body.decode("utf-8", errors="replace")}


def snapshot(cfg: Config) -> dict:
    return {
        "files": snapshot_files(cfg),
        "users": count(cfg, cfg.users_sql),
        "objects": count(cfg, cfg.objects_sql),
        "robots": fetch_robots(cfg),
    }


def write_private(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(path)


def append_log(cfg: Config, summary: str) -> None:
    cfg.state_dir.mkdir(parents=True, exist_ok=True)
    cfg.state_dir.chmod(0o700)
    with cfg.log_path.open("a", encoding="utf-8") as log:
        log.write(f"- {now_iso()} {summary}\n")
    cfg.log_path.chmod(0o600)


def load_baseline(cfg: Config) -> dict:
    if not cfg.baseline_path.is_file():
        raise ConfigError(
            f"эталон не найден: {cfg.baseline_path}. Снимите его после приёмки: scripts/watchdog-baseline.py"
        )
    return json.loads(cfg.baseline_path.read_text(encoding="utf-8"))
