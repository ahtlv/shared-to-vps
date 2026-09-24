#!/usr/bin/env python3
"""Помощник разворачивания WordPress: всё, что удобнее и безопаснее делать не в sh.

    restore_helper.py extract ARCHIVE DEST        распаковать zip или tar.gz с проверкой путей
    restore_helper.py find-dump ROOT              найти единственный дамп в распакованном снимке
    restore_helper.py prefix DUMP                 префикс таблиц WordPress по дампу
    restore_helper.py old-paths DUMP              абсолютные пути старой площадки в дампе
    restore_helper.py home DUMP PREFIX            адрес сайта из дампа
    restore_helper.py env ENV DB_USER             дописать в .env недостающие реквизиты и соли
    restore_helper.py wp-config ENV DB PREFIX URL ROOT   записать ROOT/wp-config.php
    restore_helper.py dropped-defines FILE        константы старого конфига, которые не переносятся
    restore_helper.py remnants ROOT [--delete]    установщик и его остатки
    restore_helper.py upload-code -               PHP с кодом из tar-потока загрузок

Вызывается из restore.sh на хосте. Нужен только Python 3 из стандартной
поставки: на сервере он уже есть ради сторожа.

Код 0: успех. Код 1: отказ с причиной в stderr.
"""

from __future__ import annotations

import gzip
import os
import re
import secrets
import shutil
import stat
import sys
import tarfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import IO, Iterator

NEW_ROOT = "/var/www/html"

SALT_KEYS = (
    "AUTH_KEY", "SECURE_AUTH_KEY", "LOGGED_IN_KEY", "NONCE_KEY",
    "AUTH_SALT", "SECURE_AUTH_SALT", "LOGGED_IN_SALT", "NONCE_SALT",
)

# Что в докрут не попадает никогда. Установщик архива это исполняемый код с
# полными правами на сайт и базу: оставленный на живом сайте, он переустановит
# его любому, кто откроет адрес. Хранилища бэкапов плагина несут те же
# установщики и полные дампы. php.ini и .user.ini это переопределения PHP
# старого хостинга, а 105-байтный php.ini уже бывал вредоносом. Конфиг
# генерируется заново, старый не читается приложением ни при каких условиях.
REMNANT_ROOT_NAMES = {"dup-installer", "installer.php", "php.ini", ".user.ini", "wp-config.php", "wp-snapshots"}
REMNANT_ROOT_GLOBS = ("*installer-backup.php", "*_installer.php", "dup-installer-bootlog__*",
                      "*_archive.zip", "*_archive.daf")
REMNANT_PATHS = ("wp-content/backups-dup-pro", "wp-content/backups-dup-lite", "wp-content/debug.log")
# Лог ошибок встречается на любой глубине и бывает многогигабайтным.
REMNANT_ANYWHERE = {"error_log"}


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
        rel = _check_name(info.filename.rstrip("/")) if info.filename.rstrip("/") else None
        if rel is None:
            continue
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

    Права из архива не переносятся: каталоги 0755, файлы 0644. Владельца
    назначает разворачивание, а не архив хостинга.
    """
    if zipfile.is_zipfile(archive_path):
        # Контрольные суммы записей сверяются при чтении, отдельный проход
        # testzip() распаковал бы многогигабайтный снимок дважды.
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
        # 'xb': повтор имени в архиве это отказ, а не тихая перезапись.
        try:
            with source, open(target, "xb") as out:
                shutil.copyfileobj(source, out, 1 << 20)
        except FileExistsError as exc:
            raise RestoreError(f"имя встречается в архиве дважды: {rel}") from exc
        files += 1
    for path in [dest, *dest.rglob("*")]:
        path.chmod(0o755 if path.is_dir() else 0o644)
    return files


# --- дамп -------------------------------------------------------------------

def _is_dump(path: Path) -> bool:
    return path.is_file() and (path.name.endswith(".sql") or path.name.endswith(".sql.gz"))


def find_dump(root: Path) -> Path:
    """Единственный дамп снимка. Два кандидата это не выбор, а отказ.

    В архиве установщика дамп лежит где-то внутри его каталога. Без
    установщика ищется только корень: SQL-файлы внутри плагинов это их схемы,
    а не база сайта.
    """
    installer = root / "dup-installer"
    candidates = sorted(p for p in installer.rglob("*") if _is_dump(p)) if installer.is_dir() \
        else sorted(p for p in root.iterdir() if _is_dump(p))
    if len(candidates) == 1:
        return candidates[0]
    listed = ", ".join(p.relative_to(root).as_posix() for p in candidates) or "ни одного"
    raise RestoreError(f"дамп базы в снимке не определён однозначно ({listed}): передайте --dump и --dump-sha256")


def open_text(path: Path) -> IO[str]:
    if path.name.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return open(path, encoding="utf-8", errors="replace")


def _lines(path: Path) -> Iterator[str]:
    with open_text(path) as fh:
        yield from fh


def detect_prefix(dump: Path) -> str:
    """Префикс, у которого в дампе есть options, posts и users одновременно."""
    return _prefix_from_lines(_lines(dump))


def detect_prefix_text(sql: str) -> str:
    return _prefix_from_lines(sql.splitlines())


def _prefix_from_lines(lines) -> str:
    created: set[str] = set()
    pattern = re.compile(r"^CREATE TABLE (?:IF NOT EXISTS )?`([^`]+)`", re.IGNORECASE)
    for line in lines:
        match = pattern.match(line)
        if match:
            created.add(match.group(1))
    prefixes = sorted(
        name[: -len("options")] for name in created
        if name.endswith("options") and name[: -len("options")] + "posts" in created
        and name[: -len("options")] + "users" in created
    )
    if len(prefixes) != 1:
        raise RestoreError(f"префикс таблиц WordPress не определён однозначно: {prefixes or 'ни одного'}")
    return prefixes[0]


# Абсолютный путь перед /wp-content/. Слева не буква, не слэш, не двоеточие и
# не точка: иначе адрес https://site/wp-content/ читался бы как путь /site.
_PATH_BEFORE_CONTENT = re.compile(r"(?<![\w/:.\-])(/(?:[\w.~@+\-]+/)*[\w.~@+\-]+)/wp-content/")
# Корень файловой системы, а не путь адреса: не меньше двух уровней и первый
# из тех, где хостинги держат сайты. Ссылка вида /blog/wp-content/... иначе
# сошла бы за корень, и замена /blog испортила бы каждую ссылку на раздел.
# Необычный корень называется явно: --old-path.
_FS_ROOT = re.compile(r"/(?:home\d*|var|srv|usr|opt|data\d*|www|web|mnt|storage|hosting|sites|domains|"
                      r"root|hsphere|htdocs|customers|kunden|u\d*)/[^/]+(?:/.*)?")


def old_paths(dump: Path) -> dict[str, int]:
    """Корни старой площадки, найденные в дампе, с числом вхождений.

    Путь встречается в трёх видах: как есть, в сериализованной строке (там он
    тоже как есть, меняется только длина) и в JSON, где слэш экранирован. В
    тексте дампа экранирование ещё и удвоено. Все три приводятся к одному.
    """
    counts: dict[str, int] = {}
    for line in _lines(dump):
        if "wp-content" not in line:
            continue
        plain = line.replace("\\\\/", "/").replace("\\/", "/")
        for match in _PATH_BEFORE_CONTENT.finditer(plain):
            root = match.group(1)
            if root == NEW_ROOT or not _FS_ROOT.fullmatch(root):
                continue
            counts[root] = counts.get(root, 0) + 1
    return counts


def dump_home(dump: Path, prefix: str) -> str:
    """Адрес сайта из дампа, до того как что-либо тронуто.

    Несовпадение с новым адресом должно остановить разворачивание до сноса
    тома, а не после: иначе опечатка в аргументе кладёт живой сайт.
    """
    table = re.escape(prefix + "options")
    insert = re.compile(rf"^INSERT(?:\s+IGNORE)?\s+INTO\s+`{table}`", re.IGNORECASE)
    value = re.compile(r"\(\s*['\"]?\d+['\"]?\s*,\s*(['\"])home\1\s*,\s*(['\"])((?:\\.|(?!\2).)*)\2")
    # Оператор идёт до строки, которая кончается точкой с запятой: mariadb-dump
    # пишет каждую строку расширенного INSERT на своей строке файла.
    inside = False
    for line in _lines(dump):
        inside = inside or bool(insert.match(line))
        if inside:
            match = value.search(line)
            if match:
                return match.group(3).rstrip("/")
            inside = not line.rstrip().endswith(";")
    raise RestoreError(f"в дампе нет адреса сайта ({prefix}options, home)")


# --- реквизиты и конфиг -----------------------------------------------------

def _read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip() and not line.lstrip().startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                values[key.strip()] = value
    return values


def ensure_env(path: Path, db_user: str) -> dict[str, str]:
    """Дописать в .env то, чего там нет, и вернуть реквизиты WordPress.

    Существующие значения не трогаются никогда: второй прогон обязан получить
    те же пароль и соли, иначе конфиг менялся бы от прогона к прогону, а все
    сессии сбрасывались бы при каждом повторе.
    """
    values = _read_env(path)
    wanted = {"WP_DB_USER": db_user, "WP_DB_PASSWORD": secrets.token_hex(24)}
    wanted.update({f"WP_{key}": secrets.token_urlsafe(48) for key in SALT_KEYS})
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


def render_wp_config(values: dict[str, str], *, db_name: str, prefix: str, url: str, wp_cache: bool) -> str:
    """Конфиг целиком из реквизитов контейнера. Из архива не берётся ничего."""
    if not re.fullmatch(r"[A-Za-z0-9_]+", prefix):
        raise RestoreError(f"недопустимый префикс таблиц: {prefix!r}")
    lines = [
        "<?php",
        "// Сгенерирован адаптером разворачивания. Конфиг старой площадки не",
        "// переносится: реквизиты и соли живут в .env стека, права 600.",
        f"define('DB_NAME', {php_string(db_name)});",
        f"define('DB_USER', {php_string(values['WP_DB_USER'])});",
        f"define('DB_PASSWORD', {php_string(values['WP_DB_PASSWORD'])});",
        "define('DB_HOST', 'mariadb');",
        "define('DB_CHARSET', 'utf8mb4');",
        "define('DB_COLLATE', '');",
        "",
    ]
    lines += [f"define('{key}', {php_string(values['WP_' + key])});" for key in SALT_KEYS]
    lines += [
        "",
        f"$table_prefix = {php_string(prefix)};",
        "",
        f"define('WP_HOME', {php_string(url)});",
        f"define('WP_SITEURL', {php_string(url)});",
        "define('WP_DEBUG', false);",
        "define('DISALLOW_FILE_EDIT', true);",
        "define('FS_METHOD', 'direct');",
    ]
    if wp_cache:
        lines += [
            "// В снимке есть drop-in страничного кэша. Плагин кэша пишет эту",
            "// константу сам при активации, которой здесь не было: без неё кэш",
            "// молча не включается, и каждую страницу собирает PHP.",
            "define('WP_CACHE', true);",
        ]
    lines += [
        "",
        "if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {",
        "    $_SERVER['HTTPS'] = 'on';",
        "}",
        "",
        "if (!defined('ABSPATH')) {",
        "    define('ABSPATH', __DIR__ . '/');",
        "}",
        "",
        "require_once ABSPATH . 'wp-settings.php';",
        "",
    ]
    return "\n".join(lines)


_DEFINE = re.compile(r"define\s*\(\s*['\"]([A-Za-z0-9_]+)['\"]")


def dropped_defines(config: Path) -> list[str]:
    """Константы старого конфига, которых нет в сгенерированном.

    Конфиг площадки не читается и не исполняется: он мог быть заражён. Но
    своё в нём бывает (лимит памяти, язык, отключённый крон), и человек должен
    увидеть, что именно не переехало, а не узнать об этом по поведению сайта.
    """
    ours = set(_DEFINE.findall(render_wp_config(
        {"WP_DB_USER": "", "WP_DB_PASSWORD": "", **{f"WP_{k}": "" for k in SALT_KEYS}},
        db_name="x", prefix="x", url="x", wp_cache=True)))
    text = config.read_text(encoding="utf-8", errors="replace")
    return sorted(set(_DEFINE.findall(text)) - ours)


# --- остатки ----------------------------------------------------------------

def remnants(root: Path) -> list[Path]:
    found: set[Path] = set()
    for entry in root.iterdir():
        if entry.name in REMNANT_ROOT_NAMES or any(entry.match(glob) for glob in REMNANT_ROOT_GLOBS):
            found.add(entry)
    for rel in REMNANT_PATHS:
        if (root / rel).exists():
            found.add(root / rel)
    for path in root.rglob("*"):
        if path.name in REMNANT_ANYWHERE and not any(parent in found for parent in path.parents):
            found.add(path)
    return sorted(found)


# Однострочный комментарий кончается и на ?>: после него снова код, поэтому
# внутри такого комментария ?> не допускается.
_STUB = re.compile(rb"<\?php\s*(?://(?:(?!\?>)[^\n])*|/\*.*?\*/|#(?!\[)(?:(?!\?>)[^\n])*)?\s*(?:\?>\s*)?", re.DOTALL)


def is_upload_stub(data: bytes) -> bool:
    """Штатная заглушка каталога: открывающий тег и не больше одного комментария.

    Плагины кладут в свои каталоги загрузок index.php с «Silence is golden»,
    чтобы веб-сервер не отдал листинг. Кода в заглушке нет, и всё, где код
    есть, заглушкой не считается, как бы файл ни назывался.
    """
    return len(data) < 512 and _STUB.fullmatch(data.strip()) is not None


def upload_code(stream) -> list[str]:
    """PHP-файлы из tar-потока каталога загрузок, которые не заглушки.

    Имена файлов не проходят через командную строку: имя в загрузках задаёт
    тот, кто файл туда положил, и кавычка в нём исполнилась бы в шелле.
    """
    found = []
    with tarfile.open(fileobj=stream, mode="r|") as archive:
        for member in archive:
            if not member.isfile() or not re.search(r"\.(?:php[0-9]?|phtml|phar)$", member.name, re.IGNORECASE):
                continue
            handle = archive.extractfile(member)
            data = handle.read() if handle else b""
            if not is_upload_stub(data):
                found.append(member.name.removeprefix("./"))
    return sorted(found)


# --- командная строка -------------------------------------------------------

def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 1
    cmd, args = argv[0], argv[1:]
    try:
        if cmd == "extract" and len(args) == 2:
            print(safe_extract(Path(args[0]), Path(args[1])))
        elif cmd == "find-dump" and len(args) == 1:
            print(find_dump(Path(args[0])))
        elif cmd == "prefix" and len(args) == 1:
            print(detect_prefix(Path(args[0])))
        elif cmd == "upload-code" and args == ["-"]:
            for name in upload_code(sys.stdin.buffer):
                print(name)
        elif cmd == "home" and len(args) == 2:
            print(dump_home(Path(args[0]), args[1]))
        elif cmd == "old-paths" and len(args) == 1:
            for root, count in sorted(old_paths(Path(args[0])).items()):
                print(f"{root}\t{count}")
        elif cmd == "env" and len(args) == 2:
            ensure_env(Path(args[0]), args[1])
        elif cmd == "wp-config" and len(args) == 5:
            env, db_name, prefix, url, root = args
            values = ensure_env(Path(env), db_name)
            root_path = Path(root)
            text = render_wp_config(values, db_name=db_name, prefix=prefix, url=url,
                                    wp_cache=(root_path / "wp-content/advanced-cache.php").is_file())
            target = root_path / "wp-config.php"
            target.write_text(text, encoding="utf-8")
            target.chmod(0o640)
        elif cmd == "dropped-defines" and len(args) == 1:
            print("\n".join(dropped_defines(Path(args[0]))))
        elif cmd == "remnants" and len(args) in (1, 2) and args[1:] in ([], ["--delete"]):
            root = Path(args[0])
            for path in remnants(root):
                print(path.relative_to(root).as_posix())
                if args[1:] == ["--delete"]:
                    shutil.rmtree(path) if path.is_dir() and not path.is_symlink() else path.unlink()
        else:
            print(__doc__, file=sys.stderr)
            return 1
    except RestoreError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
