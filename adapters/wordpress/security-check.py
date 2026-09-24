#!/usr/bin/env python3
"""Проверка чистоты WordPress по двум источникам: снимок до разворачивания и живой том после.

    security-check.py --source archive ARCHIVE.zip --user admin:administrator ...
    docker exec -u mysql SLUG-mariadb mariadb-dump --single-transaction DB \\
        | security-check.py --source volume SLUG_site_data --dump - --user ...
    security-check.py --source dir /распакованный/докрут --dump dump.sql --user ...

Один инструмент на оба конца намеренно: снимок, признанный чистым этим
скриптом, и том, развёрнутый из него, проверяются одними и теми же правилами,
и расхождение между ними видно сразу, а не после второго разового набора
команд.

Что проверяется:
  1. Ядро (wp-admin, wp-includes, корневые файлы) побайтово против внешнего
     манифеста версии с api.wordpress.org. Лишний .php в каталогах ядра тоже
     находка. Манифест без сети: --core-manifest FILE (JSON путь -> md5).
  2. Сигнатуры исполняемого кода в плагинах, темах и mu-plugins. Комментарии
     и строковые литералы выбрасываются до поиска: иначе шум из докблоков
     прячет настоящую находку. Проверенные глазами ложные срабатывания
     перечисляются в --site-conf строками benign=ПУТЬ|СИГНАТУРА, узко.
  3. Каталог загрузок: любой PHP, кроме штатных заглушек без кода.
  4. Корень: PHP вне ядра, незнакомые каталоги, известные признаки
     заражения из --site-conf (ioc_md5=, ioc_domain=).
  5. Установщик архива: в снимке это устройство архива и печатается
     предупреждением, в развёрнутом томе (--source volume или --deployed)
     это находка.
  6. Пользователи из дампа против --user ЛОГИН[:РОЛЬ]. Без --user проверка не
     проходит: сравнивать не с чем, а молчаливый зелёный хуже красного.
  7. Опасные строки в дампе: eval(, base64_decode(, gzinflate(, shell_exec(,
     str_rot13( и домены из ioc_domain=.

Ничего не меняет. Том читается свежим контейнером без сети, только на чтение.

Код 0: находок нет. Код 1: есть находки. Код 2: проверку провести нельзя.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path
from typing import TextIO

_spec = importlib.util.spec_from_file_location("restore_helper", Path(__file__).resolve().parent / "restore_helper.py")
helper = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(helper)

SIGNATURES = ("eval(", "assert(", "create_function(", "gzinflate(", "str_rot13(",
              "system(", "shell_exec(", "passthru(", "popen(", "proc_open(")
DUMP_SIGNATURES = ("eval(", "base64_decode(", "gzinflate(", "shell_exec(", "str_rot13(")
# Всё, что законно лежит в корне кроме файлов ядра из манифеста.
ROOT_KNOWN = {"wp-admin", "wp-includes", "wp-content", "wp-config.php", ".htaccess", "robots.txt",
              "favicon.ico", "llms.txt", "ads.txt", ".well-known", ".shared-to-vps-restore"}
MARKER = ".shared-to-vps-restore"


class CheckError(Exception):
    """Проверку провести нельзя: код 2."""


class Report:
    def __init__(self) -> None:
        self.ok: list[str] = []
        self.findings: list[str] = []

    def good(self, msg: str) -> None:
        self.ok.append(msg)

    def bad(self, msg: str) -> None:
        self.findings.append(msg)


class SiteConf:
    """Узкие исключения и признаки конкретной площадки. Живут вне репозитория."""

    def __init__(self, path: Path | None) -> None:
        self.benign: set[tuple[str, str]] = set()
        self.benign_sql: set[str] = set()
        self.ioc_md5: set[str] = set()
        self.ioc_domain: set[str] = set()
        self.root_entry: set[str] = set()
        if path is None:
            return
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip() or line.lstrip().startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key, value = key.strip(), value.strip()
            if key == "benign":
                file, sep, pattern = value.partition("|")
                if not sep:
                    raise CheckError(f"benign без сигнатуры, нужно ПУТЬ|СИГНАТУРА: {value}")
                self.benign.add((file, pattern))
            elif key in ("benign_sql", "ioc_md5", "ioc_domain", "root_entry"):
                getattr(self, key).add(value.lower() if key != "root_entry" else value)
            else:
                raise CheckError(f"неизвестный ключ в {path}: {key}")


# --- источники --------------------------------------------------------------

def from_volume(volume: str, dest: Path, image: str) -> list[str]:
    """Скопировать том в dest через tar из свежего контейнера. Ссылки не создаются, а возвращаются."""
    links: list[str] = []
    with tempfile.TemporaryFile() as err:
        proc = subprocess.Popen(
            ["docker", "run", "--rm", "--network", "none", "--entrypoint", "tar",
             "-v", f"{volume}:/src:ro", image, "-C", "/src", "-cf", "-", "."],
            stdout=subprocess.PIPE, stderr=err)
        assert proc.stdout is not None
        try:
            with tarfile.open(fileobj=proc.stdout, mode="r|") as archive:
                for member in archive:
                    name = member.name[2:] if member.name.startswith("./") else member.name
                    if not name or name == ".":
                        continue
                    rel = helper._check_name(name)
                    target = dest / rel
                    if member.isdir():
                        target.mkdir(parents=True, exist_ok=True)
                    elif member.isfile():
                        target.parent.mkdir(parents=True, exist_ok=True)
                        handle = archive.extractfile(member)
                        assert handle is not None
                        with open(target, "wb") as out:
                            out.write(handle.read())
                    else:
                        links.append(rel)
        except (tarfile.TarError, helper.RestoreError) as exc:
            proc.kill()
            proc.wait()
            err.seek(0)
            raise CheckError(f"том {volume} не читается: {exc}; {err.read().decode(errors='replace').strip()}") from exc
        finally:
            proc.stdout.close()
        if proc.wait() != 0:
            err.seek(0)
            raise CheckError(f"том {volume} не читается: {err.read().decode(errors='replace').strip()}")
    return links


def wp_root(path: Path) -> Path:
    if (path / "wp-includes/version.php").is_file():
        return path
    raise CheckError(f"{path} не похож на корень WordPress: нет wp-includes/version.php")


def wp_version(root: Path) -> tuple[str, str]:
    text = (root / "wp-includes/version.php").read_text(encoding="utf-8", errors="replace")
    version = re.search(r"\$wp_version\s*=\s*'([^']+)'", text)
    if not version:
        raise CheckError("версия ядра не читается из wp-includes/version.php")
    # Локализованная сборка пишет свою локаль в version.php. Сверка русской
    # сборки с английским манифестом показала бы изменённые файлы там, где их нет.
    package = re.search(r"\$wp_local_package\s*=\s*'([^']+)'", text)
    return version.group(1), package.group(1) if package else "en_US"


def fetch_manifest(version: str, locale: str) -> dict[str, str]:
    query = urllib.parse.urlencode({"version": version, "locale": locale})
    try:
        with urllib.request.urlopen(f"https://api.wordpress.org/core/checksums/1.0/?{query}", timeout=30) as resp:
            data = json.load(resp)
    except OSError as exc:
        raise CheckError(f"манифест ядра {version}/{locale} не получен: {exc}; передайте --core-manifest") from exc
    checksums = data.get("checksums")
    if not isinstance(checksums, dict) or not checksums:
        raise CheckError(f"для {version}/{locale} манифеста ядра нет; передайте --core-manifest")
    return checksums


def md5(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


# --- проверки ---------------------------------------------------------------

def check_core(report: Report, root: Path, manifest: dict[str, str], version: str, locale: str) -> set[str]:
    # wp-content из манифеста не сверяется: штатные темы и плагины обновляются
    # отдельно от ядра, и расхождение там это версия, а не взлом.
    core = {p: h for p, h in manifest.items() if p.startswith(("wp-admin/", "wp-includes/")) or "/" not in p}
    missing, changed = [], []
    for rel, expected in sorted(core.items()):
        path = root / rel
        if not path.is_file():
            missing.append(rel)
        elif md5(path) != expected:
            changed.append(rel)
    extra = sorted(
        p.relative_to(root).as_posix()
        for d in ("wp-admin", "wp-includes") if (root / d).is_dir()
        for p in (root / d).rglob("*")
        if p.is_file() and p.suffix.lower().startswith(".php") and p.relative_to(root).as_posix() not in core
    )
    if changed:
        report.bad(f"ядро {version}: изменены {changed[:20]}")
    if missing:
        report.bad(f"ядро {version}: отсутствуют {missing[:20]}")
    if extra:
        report.bad(f"ядро {version}: лишние PHP в каталогах ядра {extra[:20]}")
    if not (changed or missing or extra):
        report.good(f"ядро {version} ({locale}): {len(core)} файлов совпали с манифестом, лишних PHP нет")
    return {p for p in core if "/" not in p}


def strip_code(code: str) -> str:
    """Оставить от файла только исполняемый PHP, сохранив длину.

    Сигнатура в докблоке («operating system (which…»), в строке перевода или в
    HTML вокруг кода это не вызов. Выбрасываются комментарии, строковые
    литералы и всё вне <?php … ?>. Разбор посимвольный: «//» внутри «http://»
    часть строки, «?>» закрывает однострочный комментарий и возвращает в HTML,
    апостроф в HTML строку не открывает, а «#[» это атрибут, не комментарий.
    """
    out, i, n, state = [], 0, len(code), "html"
    while i < n:
        ch, nxt = code[i], code[i + 1] if i + 1 < n else ""
        if state == "html":
            opener = 5 if code.startswith("<?php", i) else 3 if code.startswith("<?=", i) else 0
            if opener:
                state = None
                out.append(" " * opener)
                i += opener
            else:
                out.append("\n" if ch == "\n" else " ")
                i += 1
            continue
        if state in (None, "//") and ch == "?" and nxt == ">":
            state = "html"
            out.append("  ")
            i += 2
            continue
        if state is None:
            if ch == "/" and nxt == "/" or ch == "#" and nxt != "[":
                state = "//"
            elif ch == "/" and nxt == "*":
                state = "/*"
                out.append("  ")
                i += 2
                continue
            elif ch in "'\"":
                state = ch
            else:
                out.append(ch)
                i += 1
                continue
            out.append(" ")
            i += 1
            continue
        if state == "//":
            if ch == "\n":
                state = None
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if state == "/*":
            if ch == "*" and nxt == "/":
                state = None
                out.append("  ")
                i += 2
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if ch == "\\" and nxt:
            out.append("  ")
            i += 2
            continue
        if ch == state:
            state = None
        out.append("\n" if ch == "\n" else " ")
        i += 1
    return "".join(out)


def signature_hits(text: str) -> list[str]:
    code = strip_code(text.lower())
    hits = []
    for sig in SIGNATURES:
        name = re.escape(sig[:-1])
        # Не часть имени (filesystem(), не метод (->system(, ::system(), не
        # объявление (function assert().
        for m in re.finditer(rf"(?<![a-z0-9_\\$])(?<!->)(?<!::){name}\s*\(", code):
            if not re.search(r"\bfunction\s+$", code[max(0, m.start() - 40):m.start()]):
                hits.append(sig)
                break
    return hits


def check_signatures(report: Report, root: Path, conf: SiteConf) -> None:
    # Весь wp-content, кроме загрузок: у тех своя, более строгая проверка. Не
    # только плагины и темы: drop-in вроде db.php или advanced-cache.php лежит
    # прямо в wp-content и грузится на каждом запросе.
    hits, scanned = [], 0
    base = root / "wp-content"
    if base.is_dir():
        for path in base.rglob("*.php"):
            if not path.is_file() or path.relative_to(base).parts[0] == "uploads":
                continue
            scanned += 1
            rel = path.relative_to(root).as_posix()
            text = path.read_text(encoding="utf-8", errors="ignore")
            hits += [(rel, sig) for sig in signature_hits(text)]
    new = sorted(set(hits) - conf.benign)
    if new:
        report.bad(f"сигнатуры исполняемого кода вне списка проверенных ({scanned} PHP): {new[:20]}")
    else:
        report.good(f"сигнатуры: {scanned} PHP, проверенных ложных {len(set(hits))}, новых нет")


def check_uploads(report: Report, root: Path) -> None:
    uploads = root / "wp-content/uploads"
    bad = []
    if uploads.is_dir():
        for path in uploads.rglob("*"):
            if path.is_file() and re.search(r"\.(?:php[0-9]?|phtml|phar)$", path.name, re.IGNORECASE):
                if not helper.is_upload_stub(path.read_bytes()):
                    bad.append(path.relative_to(root).as_posix())
    if bad:
        report.bad(f"исполняемый код в загрузках: {sorted(bad)[:20]}")
    else:
        report.good("в загрузках нет PHP, кроме заглушек без кода")


def check_root(report: Report, root: Path, core_root: set[str], conf: SiteConf, deployed: bool) -> None:
    remnants = {p.relative_to(root).as_posix() for p in helper.remnants(root)}
    installer = {r for r in remnants if r != "wp-config.php"}
    if installer:
        if deployed:
            report.bad(f"установщик и остатки в развёрнутом докруте: {sorted(installer)}")
        else:
            report.good(f"снимок несёт установщик {sorted(installer)}: это устройство архива, в докрут он не попадёт")
    # Разрешается только сам остаток в корне. Лог ошибок бывает на любой
    # глубине, и его каталог от этого своим не становится.
    allowed = core_root | ROOT_KNOWN | conf.root_entry | {r for r in remnants if "/" not in r}
    stray_php, stray_dirs = [], []
    for entry in root.iterdir():
        if entry.name in allowed:
            continue
        if entry.is_dir():
            stray_dirs.append(entry.name)
        elif entry.suffix.lower().startswith(".php"):
            stray_php.append(entry.name)
    if stray_php:
        report.bad(f"PHP в корне вне ядра: {sorted(stray_php)}")
    if stray_dirs:
        report.bad(f"незнакомые каталоги в корне (свои перечислить в root_entry=): {sorted(stray_dirs)}")
    if not (stray_php or stray_dirs):
        report.good("корень: вне ядра ни PHP, ни незнакомых каталогов")

    iocs = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        if conf.ioc_md5 and path.suffix.lower() in (".php", ".ini", ".js") and md5(path) in conf.ioc_md5:
            iocs.append(f"{rel}: известный md5")
        if conf.ioc_domain and path.suffix.lower() in (".php", ".js", ".html", ".txt", ".ini", ".json"):
            text = path.read_text(encoding="utf-8", errors="ignore").lower()
            iocs += [f"{rel}: {d}" for d in conf.ioc_domain if d in text]
    if iocs:
        report.bad(f"известные признаки заражения: {sorted(iocs)[:20]}")
    elif conf.ioc_md5 or conf.ioc_domain:
        report.good(f"известных признаков заражения нет ({len(conf.ioc_md5)} md5, {len(conf.ioc_domain)} доменов)")


def insert_values(sql: str, table: str) -> str:
    """Тела VALUES одной таблицы. Конец оператора: точка с запятой в конце строки."""
    pattern = re.compile(rf"^INSERT(?:\s+IGNORE)?\s+INTO\s+`{re.escape(table)}`(?:\s*\([^)]*\))?\s+VALUES\s*(.*?);\s*$",
                         re.IGNORECASE | re.MULTILINE | re.DOTALL)
    return "\n".join(pattern.findall(sql))


def users_from_sql(sql: str, prefix: str) -> dict[str, list[str]]:
    """Логины и роли из дампа без импорта.

    Кавычки зависят от того, кто снимал дамп: mysqldump пишет строки в
    одинарных, а плагин бэкапа бывает пишет каждое значение, даже число, в
    двойных. Парсер одной формы на чужом дампе молча не находит никого.
    """
    ids: dict[str, str] = {}
    for q in ("'", '"'):
        e = re.escape(q)
        for m in re.finditer(rf"\(\s*{e}?(\d+){e}?\s*,\s*{e}((?:\\.|(?!{e}).)*){e}\s*,", insert_values(sql, prefix + "users")):
            ids.setdefault(m.group(1), m.group(2))
    roles: dict[str, list[str]] = {}
    meta = insert_values(sql, prefix + "usermeta")
    for q in ("'", '"'):
        e = re.escape(q)
        pattern = rf"\(\s*{e}?\d+{e}?\s*,\s*{e}?(\d+){e}?\s*,\s*{e}{re.escape(prefix)}capabilities{e}\s*,\s*{e}((?:\\.|(?!{e}).)*){e}"
        for m in re.finditer(pattern, meta):
            roles.setdefault(m.group(1), re.findall(r's:\d+:\\*"([a-z_]+)\\*";b:1', m.group(2)))
    return {login: roles.get(uid, []) for uid, login in ids.items()}


def check_users(report: Report, users: dict[str, list[str]], expected: list[str]) -> None:
    if not users:
        report.bad("пользователи из дампа не извлечены: проверить нечего")
        return
    actual = ", ".join(f"{u}:{'/'.join(r) or '-'}" for u, r in sorted(users.items()))
    if not expected:
        report.bad(f"эталон пользователей не задан (--user ЛОГИН[:РОЛЬ]); в дампе: {actual}")
        return
    want: dict[str, str | None] = {}
    for item in expected:
        login, _, role = item.partition(":")
        want[login] = role or None
    extra = sorted(set(users) - set(want))
    missing = sorted(set(want) - set(users))
    wrong = sorted(f"{u}: {'/'.join(users[u])}, ожидалось {r}" for u, r in want.items()
                   if u in users and r is not None and r not in users[u])
    if extra:
        report.bad(f"лишние пользователи: {extra}")
    if missing:
        report.bad(f"нет ожидаемых пользователей: {missing}")
    if wrong:
        report.bad(f"роли не совпали: {wrong}")
    if not (extra or missing or wrong):
        report.good(f"пользователи совпали с эталоном: {actual}")


def check_dump(report: Report, sql: str, conf: SiteConf, expected_users: list[str]) -> None:
    try:
        prefix = helper.detect_prefix_text(sql)
    except helper.RestoreError as exc:
        report.bad(f"дамп: {exc}")
        return
    check_users(report, users_from_sql(sql, prefix), expected_users)
    low = sql.lower()
    hits = sorted({s for s in DUMP_SIGNATURES + tuple(conf.ioc_domain) if s in low} - conf.benign_sql)
    if hits:
        report.bad(f"дамп: опасные строки {hits}")
    else:
        report.good("дамп: опасных строк и известных доменов нет")


# --- запуск -----------------------------------------------------------------

def run(args: argparse.Namespace, work: Path) -> Report:
    conf = SiteConf(args.site_conf)
    report = Report()
    deployed = args.deployed or args.source == "volume"
    dump: Path | None = None
    sql: str | None = sys.stdin.read() if args.dump == "-" else None

    if args.source == "archive":
        helper.safe_extract(Path(args.path), work)
        root = wp_root(work)
        if args.dump is None:
            dump = helper.find_dump(root)
    elif args.source == "volume":
        image = args.helper_image or args.path.removesuffix("_site_data") + "-php-fpm:local"
        links = from_volume(args.path, work, image)
        if links:
            report.bad(f"ссылки в томе: {links[:20]}")
        root = wp_root(work)
    else:
        root = wp_root(Path(args.path))
    report.good(f"источник: {args.source} {args.path}")

    if args.dump not in (None, "-"):
        dump = Path(args.dump)
    if sql is None and dump is not None:
        with helper.open_text(dump) as fh:
            sql = fh.read()

    version, locale = wp_version(root)
    manifest = json.loads(Path(args.core_manifest).read_text()) if args.core_manifest else fetch_manifest(version, locale)
    core_root = check_core(report, root, manifest, version, locale)
    check_signatures(report, root, conf)
    check_uploads(report, root)
    check_root(report, root, core_root, conf, deployed)
    if sql is None:
        report.bad("дамп не передан (--dump): пользователи и база не проверены")
    else:
        check_dump(report, sql, conf, args.user)
    return report


def main(argv: list[str] | None = None, stdout: TextIO = sys.stdout) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", choices=("archive", "volume", "dir"), required=True)
    parser.add_argument("path", help="архив, имя тома или каталог")
    parser.add_argument("--dump", help="дамп .sql или .sql.gz, '-' для stdin; в архиве ищется сам")
    parser.add_argument("--user", action="append", default=[], help="ожидаемый пользователь ЛОГИН[:РОЛЬ], повторяемый")
    parser.add_argument("--site-conf", type=Path, help="исключения и признаки площадки")
    parser.add_argument("--core-manifest", help="манифест ядра JSON вместо запроса к api.wordpress.org")
    parser.add_argument("--deployed", action="store_true", help="источник это развёрнутый докрут: установщик в нём находка")
    parser.add_argument("--helper-image", help="образ для чтения тома; по умолчанию образ приложения стека")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    try:
        with tempfile.TemporaryDirectory(prefix="wp-security-") as tmp:
            report = run(args, Path(tmp))
    except (CheckError, helper.RestoreError, OSError) as exc:
        if args.json:
            print(json.dumps({"clean": False, "error": str(exc), "ok": [], "findings": []}, ensure_ascii=False), file=stdout)
        else:
            print(f"проверку провести нельзя: {exc}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps({"clean": not report.findings, "ok": report.ok, "findings": report.findings},
                         ensure_ascii=False, indent=2), file=stdout)
    else:
        for msg in report.ok:
            print(f"PASS  {msg}", file=stdout)
        for msg in report.findings:
            print(f"FAIL  {msg}", file=stdout)
        print("находок нет" if not report.findings else f"находок: {len(report.findings)}", file=stdout)
    return 1 if report.findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
