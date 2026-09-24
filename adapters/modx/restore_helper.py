#!/usr/bin/env python3
"""Помощник разворачивания MODX: всё, что удобнее и безопаснее делать не в sh.

    restore_helper.py extract ARCHIVE DEST              распаковать zip или tar.gz с проверкой путей
    restore_helper.py find-root DIR                     докрут сайта внутри распакованного снимка
    restore_helper.py find-dump DIR SITE                единственный дамп снимка
    restore_helper.py config SITE                       корень старой площадки и префикс таблиц
    restore_helper.py write-config ENV DB SITE OLD      привести конфиг к реквизитам .env стека
    restore_helper.py remnants SITE [--delete]          установщик, остатки хостинга и кэш
    restore_helper.py env-get ENV KEY                   значение из .env тем же разбором, что пишет конфиг

Вызывается из restore.sh на хосте. Нужен только Python 3 из стандартной
поставки: на сервере он уже есть ради сторожа.

Код 0: успех. Код 1: отказ с причиной в stderr.
"""

from __future__ import annotations

import os
import re
import secrets
import shutil
import stat
import sys
import tarfile
import zipfile
from pathlib import Path, PurePosixPath

NEW_ROOT = "/var/www/html"
CONFIG = "core/config/config.inc.php"
# Пароль базы отдельным файлом рядом с конфигом. Бэкап ядра роняет набор, в
# котором нашёлся пароль из .env, и исключает только этот файл; конфиг с
# ключом сессии и идентификатором установки остаётся в наборе, и сайт можно
# развернуть из собственного бэкапа тем же restore.sh.
PASSWORD_FILE = "core/config/db-password.inc.php"
PASSWORD_REQUIRE = "require __DIR__ . '/db-password.inc.php'"
# Три файла, которые называют ядру путь до core/ до того, как прочитан конфиг.
CORE_POINTERS = ("config.core.php", "manager/config.core.php", "connectors/config.core.php")

# Что в докрут не попадает. setup/ это установщик MODX: оставленный на живом
# сайте, он переустановит его любому, кто откроет адрес. php.ini и .user.ini
# это переопределения PHP старого хостинга, 105-байтный php.ini уже бывал
# вредоносом. Кэш собран на старой площадке и несёт её пути и настройки.
REMNANT_ROOT_NAMES = {"setup", "php.ini", ".user.ini", ".ftpquota"}
# Лог ошибок хостинга встречается на любой глубине и бывает многогигабайтным.
REMNANT_ANYWHERE = {"error_log", ".ftp-deploy-sync-state.json"}


class RestoreError(Exception):
    """Отказ с причиной для человека."""


# --- распаковка -------------------------------------------------------------

def _check_name(name: str) -> str:
    """Относительный путь без выхода наружу, иначе отказ."""
    if not name or "\\" in name or "\0" in name or re.match(r"^[A-Za-z]:", name) or name.startswith("/"):
        raise RestoreError(f"небезопасный путь в архиве: {name!r}")
    parts = [p for p in PurePosixPath(name).parts if p != "."]
    if not parts or ".." in parts:
        raise RestoreError(f"небезопасный путь в архиве: {name!r}")
    return "/".join(parts)


def _plan_zip(archive: zipfile.ZipFile) -> list[tuple[str, bool, zipfile.ZipInfo]]:
    plan = []
    for info in archive.infolist():
        if not info.filename.rstrip("/"):
            continue
        rel = _check_name(info.filename.rstrip("/"))
        kind = (info.external_attr >> 16) & 0o170000
        if kind == stat.S_IFLNK:
            raise RestoreError(f"символическая ссылка в архиве запрещена: {info.filename}")
        if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise RestoreError(f"особый файл в архиве запрещён: {info.filename}")
        plan.append((rel, info.is_dir(), info))
    return plan


def _plan_tar(archive: tarfile.TarFile) -> list[tuple[str, bool, tarfile.TarInfo]]:
    plan = []
    for member in archive.getmembers():
        if member.name in (".", "./"):
            continue
        rel = _check_name(member.name)
        if member.issym() or member.islnk():
            raise RestoreError(f"ссылка в архиве запрещена: {member.name}")
        if not (member.isfile() or member.isdir()):
            raise RestoreError(f"особый файл в архиве запрещён: {member.name}")
        plan.append((rel, member.isdir(), member))
    return plan


def safe_extract(archive_path: Path, dest: Path) -> int:
    """Распаковать архив в dest. Сначала проверяется весь список, потом пишется.

    Права из архива не переносятся: каталоги 0755, файлы 0644. Докрут
    хостинга приезжал с 0700, и веб-сервер получал отказ на всё.
    """
    if zipfile.is_zipfile(archive_path):
        with zipfile.ZipFile(archive_path) as archive:
            plan = _plan_zip(archive)
            try:
                return _write(plan, dest, lambda info: archive.open(info))
            except zipfile.BadZipFile as exc:
                raise RestoreError(f"архив повреждён: {exc}") from exc
    if tarfile.is_tarfile(archive_path):
        with tarfile.open(archive_path) as archive:
            plan = _plan_tar(archive)
            return _write(plan, dest, lambda member: archive.extractfile(member))
    raise RestoreError(f"не zip и не tar: {archive_path}")


def _write(plan, dest: Path, opener) -> int:
    files = 0
    for rel, is_dir, info in plan:
        target = dest / rel
        if is_dir:
            target.mkdir(parents=True, exist_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        source = opener(info)
        if source is None:
            raise RestoreError(f"запись не читается: {rel}")
        try:
            with source, open(target, "xb") as out:
                shutil.copyfileobj(source, out, 1 << 20)
        except FileExistsError as exc:
            raise RestoreError(f"имя встречается в архиве дважды: {rel}") from exc
        files += 1
    for path in [dest, *dest.rglob("*")]:
        path.chmod(0o755 if path.is_dir() else 0o644)
    return files


# --- где сайт и где дамп ----------------------------------------------------

def find_root(top: Path) -> Path:
    """Докрут: каталог с config.core.php и index.php. Ровно один.

    Архив хостинга приходит с префиксом вроде data/www/имя-сайта/, и глубина
    у каждого хостинга своя, поэтому докрут ищется, а не отрезается числом.
    """
    roots = sorted({p.parent for p in top.rglob("config.core.php")
                    if (p.parent / "index.php").is_file() and p.parent.name not in ("manager", "connectors")})
    if not roots:
        raise RestoreError("в снимке нет докрута MODX: не найден config.core.php рядом с index.php")
    if len(roots) > 1:
        listed = ", ".join(r.relative_to(top).as_posix() or "." for r in roots)
        raise RestoreError(f"в снимке два и больше сайтов MODX ({listed}): нужен архив одного докрута")
    root = roots[0]
    if not (root / CONFIG).is_file():
        raise RestoreError("ядро MODX вне докрута (нет core/config/config.inc.php рядом с index.php): "
                           "такое разворачивание адаптер не поддерживает")
    return root


def _is_dump(path: Path) -> bool:
    return path.is_file() and (path.name.endswith(".sql") or path.name.endswith(".sql.gz"))


def find_dump(top: Path, site: Path) -> Path:
    """Единственный дамп в снимке: рядом с докрутом или в его корне.

    SQL внутри core/ это схемы компонентов, а не база сайта.
    """
    candidates = sorted(p for p in top.rglob("*") if _is_dump(p) and site / "core" not in p.parents)
    if len(candidates) == 1:
        return candidates[0]
    listed = ", ".join(p.relative_to(top).as_posix() for p in candidates) or "ни одного"
    raise RestoreError(f"дамп базы в снимке не определён однозначно ({listed}): передайте --dump и --dump-sha256")


# --- конфиг -----------------------------------------------------------------

def _assignment(name: str) -> re.Pattern[str]:
    return re.compile(r"\$" + re.escape(name) + r"\s*=\s*'((?:[^'\\]|\\.)*)'\s*;")


# Пароль: литерал из снимка хостинга или ссылка на файл после разворачивания.
_PASSWORD = re.compile(r"\$database_password\s*=\s*(?:'(?:[^'\\]|\\.)*'|" + re.escape(PASSWORD_REQUIRE) + r")\s*;")


def _php_unquote(value: str) -> str:
    return re.sub(r"\\([\\'])", r"\1", value)


def read_config(site: Path) -> dict[str, str]:
    text = (site / CONFIG).read_text(encoding="utf-8", errors="replace")
    base = _assignment("modx_base_path").search(text)
    if base is None:
        raise RestoreError(f"в {CONFIG} нет $modx_base_path: корень старой площадки не определить")
    prefix = _assignment("table_prefix").search(text)
    if prefix is None or not re.fullmatch(r"[A-Za-z0-9_]+", _php_unquote(prefix.group(1))):
        raise RestoreError(f"в {CONFIG} нет $table_prefix из [A-Za-z0-9_]")
    return {"old_root": _php_unquote(base.group(1)).rstrip("/") or "/", "prefix": _php_unquote(prefix.group(1))}


def _read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip() and not line.lstrip().startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                values[key.strip()] = value
    return values


def ensure_env(path: Path, db_user: str) -> dict[str, str]:
    """Дописать в .env реквизиты MODX, если их там нет, и вернуть их.

    Существующие значения не трогаются: пароль в .env единственный источник,
    из которого на каждом прогоне пишутся и конфиг, и пользователь базы.
    """
    values = _read_env(path)
    wanted = {"MODX_DB_USER": db_user, "MODX_DB_PASSWORD": secrets.token_hex(24)}
    missing = {k: v for k, v in wanted.items() if k not in values}
    if missing:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
            existing = path.read_text(encoding="utf-8")
            if existing and not existing.endswith("\n"):
                fh.write("\n")
            for key, value in missing.items():
                fh.write(f"{key}={value}\n")
        values.update(missing)
    path.chmod(0o600)
    return {k: values[k] for k in wanted}


def php_string(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def write_config(site: Path, values: dict[str, str], *, db_name: str, old_root: str) -> None:
    """Реквизиты базы из .env стека и пути нового докрута. Остальное не трогается.

    Конфиг правится, а не генерируется, как у WordPress: в нём ключ сессии,
    идентификатор установки и опции драйвера, которые принадлежат сайту.
    Каждое присваивание обязано найтись ровно один раз: иначе конфиг чужой
    формы, и тихая частичная правка хуже отказа.
    """
    if not re.fullmatch(r"[A-Za-z0-9_]+", db_name):
        raise RestoreError(f"имя базы не из [A-Za-z0-9_]: {db_name}")
    path = site / CONFIG
    text = path.read_text(encoding="utf-8", errors="strict")
    assignments = {
        "database_server": "mariadb",
        "database_user": values["MODX_DB_USER"],
        "database_connection_charset": "utf8mb4",
        "dbase": db_name,
        "database_dsn": f"mysql:host=mariadb;dbname={db_name};charset=utf8mb4",
    }
    for name, value in assignments.items():
        literal = php_string(value)
        text, count = _assignment(name).subn(lambda _m, n=name, v=literal: f"${n} = {v};", text)
        if count != 1:
            raise RestoreError(f"в {CONFIG} присваивание ${name} найдено {count} раз, ожидалось одно")
    text, count = _PASSWORD.subn(lambda _m: f"$database_password = {PASSWORD_REQUIRE};", text)
    if count != 1:
        raise RestoreError(f"в {CONFIG} присваивание $database_password найдено {count} раз, ожидалось одно")
    old = old_root.rstrip("/") + "/"
    text = text.replace(old, NEW_ROOT + "/")
    for name in ("modx_core_path", "modx_processors_path", "modx_connectors_path", "modx_manager_path",
                 "modx_base_path", "modx_assets_path"):
        for match in _assignment(name).finditer(text):
            if not _php_unquote(match.group(1)).startswith(NEW_ROOT + "/"):
                raise RestoreError(f"${name} после правки не в новом докруте: {match.group(1)}")
    _write_private(site / PASSWORD_FILE, f"<?php\nreturn {php_string(values['MODX_DB_PASSWORD'])};\n")
    _write_private(path, text)
    for rel in CORE_POINTERS:
        pointer = site / rel
        if not pointer.is_file():
            if rel == "config.core.php":
                raise RestoreError(f"в снимке нет {rel}")
            continue
        content = pointer.read_text(encoding="utf-8").replace(old, NEW_ROOT + "/")
        core = re.search(r"define\(\s*'MODX_CORE_PATH'\s*,\s*'([^']*)'", content)
        if core is None or core.group(1) != NEW_ROOT + "/core/":
            raise RestoreError(f"{rel}: MODX_CORE_PATH не указывает на {NEW_ROOT}/core/ после правки")
        pointer.write_text(content, encoding="utf-8")


def _write_private(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".new")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    tmp.chmod(0o640)
    os.replace(tmp, path)


# --- остатки ----------------------------------------------------------------

def remnants(site: Path) -> list[Path]:
    found: set[Path] = set()
    for entry in site.iterdir():
        if entry.name in REMNANT_ROOT_NAMES:
            found.add(entry)
    cache = site / "core/cache"
    if cache.is_dir():
        found.update(cache.iterdir())
    for path in site.rglob("*"):
        if path.name in REMNANT_ANYWHERE and not any(parent in found for parent in path.parents):
            found.add(path)
    return sorted(found)


def remove(paths: list[Path]) -> None:
    for path in paths:
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()


# --- командная строка -------------------------------------------------------

def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 1
    cmd, args = argv[0], argv[1:]
    try:
        if cmd == "extract" and len(args) == 2:
            print(safe_extract(Path(args[0]), Path(args[1])))
        elif cmd == "find-root" and len(args) == 1:
            print(find_root(Path(args[0])))
        elif cmd == "find-dump" and len(args) == 2:
            print(find_dump(Path(args[0]), Path(args[1])))
        elif cmd == "config" and len(args) == 1:
            info = read_config(Path(args[0]))
            print(f"{info['old_root']}\t{info['prefix']}")
        elif cmd == "write-config" and len(args) == 4:
            env, db_name, site, old = args
            write_config(Path(site), ensure_env(Path(env), db_name), db_name=db_name, old_root=old)
        elif cmd == "env-get" and len(args) == 2:
            values = _read_env(Path(args[0]))
            if args[1] not in values:
                raise RestoreError(f"в {args[0]} нет {args[1]}")
            print(values[args[1]])
        elif cmd == "remnants" and len(args) in (1, 2) and args[1:] in ([], ["--delete"]):
            site = Path(args[0])
            found = remnants(site)
            for path in found:
                print(path.relative_to(site).as_posix())
            if args[1:] == ["--delete"]:
                remove(found)
        else:
            print(__doc__, file=sys.stderr)
            return 1
    except (RestoreError, OSError, UnicodeDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
