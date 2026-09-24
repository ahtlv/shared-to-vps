#!/usr/bin/env python3
"""Редиректы из .htaccess старой площадки в запреты-и-правила nginx адаптера.

    htaccess-to-nginx.py IN OUT --host example.test [--host ...]

IN это .htaccess из снимка, OUT файл для nginx/adapter/ стека. --host это
адрес сайта: абсолютная цель на него становится путём на этом же сайте, цель
на чужой адрес остаётся внешним редиректом.

Правила переносятся генератором, а не копированием. На прежнем веб-сервере
правило, ведущее само на себя, гасилось флагом остановки; здесь это
бесконечный редирект. Повтор ключа там молча перекрывался первым правилом;
здесь два одинаковых location не дают веб-серверу запуститься вовсе. Цепочка
A → B → C стоила посетителю и роботу лишнего прыжка.

Что делает: выбрасывает самопереходы, схлопывает цепочки в один прыжок,
оставляет из повторов первое правило (так отвечал Apache), переносит обычные
правила точными, префиксными или регулярными location. Условные правила на
имя хоста и схему (www, https) не переносит: это работа обратного прокси.
Внутренние перезаписи без флага R (дружественные адреса) не переносит: их
делает адаптер в nginx.conf.

Location, а не map: map живёт на уровне http, а адаптер подключается внутрь
server. Точные location к тому же сравниваются с декодированным путём, как и
RewriteRule в .htaccess.

Код 0: файл записан, ни одно обычное правило не потеряно. Код 1: есть
неразрешимая цепочка или правило, которое не переводится; они перечислены, а
OUT не записывается, чтобы веб-сервер не получил половину правил. Код 2:
аргументы.
"""

from __future__ import annotations

import os
import re
import shlex
import sys
from dataclasses import dataclass, field
from pathlib import Path

# Условия, которые решает обратный прокси: имя хоста и схема.
PROXY_CONDITIONS = {"HTTP_HOST", "HTTPS", "SERVER_PORT", "REQUEST_SCHEME", "HTTP:X-FORWARDED-PROTO"}
# Точка не в списке: в правилах со старой структуры каждая точка это точка в
# имени файла, и перенос её буквально сужает правило, а не расширяет.
METACHARACTERS = set("*+?()[]{}|^$\\")
# Символы, которые в строке nginx в кавычках означали бы не то, что написано.
UNSAFE = set('"{};\n\r\t ') | {"'"}


@dataclass
class Rule:
    kind: str  # exact, prefix, regex
    match: str  # путь от корня; для regex готовое выражение
    target: str  # путь от корня или абсолютный адрес чужого сайта
    query: str | None
    code: int
    qsa: bool
    nc: bool
    line: str

    @property
    def key(self) -> tuple[str, str, bool]:
        return (self.kind, self.match, self.nc)

    @property
    def internal(self) -> bool:
        return self.target.startswith("/")


@dataclass
class Result:
    config: str = ""
    exact: int = 0
    prefix: int = 0
    regex: int = 0
    self_loops: list[str] = field(default_factory=list)
    chains: list[str] = field(default_factory=list)
    cycles: list[str] = field(default_factory=list)
    duplicates: int = 0
    conflicts: list[str] = field(default_factory=list)
    proxy_conditional: list[str] = field(default_factory=list)
    not_redirects: int = 0
    lost: list[str] = field(default_factory=list)

    @property
    def exit_code(self) -> int:
        return 1 if self.lost or self.cycles else 0

    def summary(self) -> str:
        return (
            f"перенесено: {self.exact + self.prefix + self.regex} "
            f"(точных {self.exact}, префиксов {self.prefix}, регулярных {self.regex}); "
            f"выброшено самопереходов: {len(self.self_loops)}; схлопнуто цепочек: {len(self.chains)}; "
            f"устранено повторов ключа: {self.duplicates + len(self.conflicts)}; "
            f"условных на хост и схему: {len(self.proxy_conditional)} (решает обратный прокси); "
            f"не редиректов: {self.not_redirects}; неразрешимых цепочек: {len(self.cycles)}; "
            f"потеряно: {len(self.lost)}"
        )


class Untranslatable(Exception):
    pass


def _flags(token: str) -> dict[str, str]:
    if not (token.startswith("[") and token.endswith("]")):
        raise Untranslatable("флаги не в квадратных скобках")
    flags = {}
    for part in token[1:-1].split(","):
        name, _, value = part.strip().partition("=")
        flags[name.strip().upper()] = value.strip()
    return flags


def _unescape_literal(body: str) -> str | None:
    """Путь без метасимволов или None, если это настоящее выражение."""
    out = []
    i = 0
    while i < len(body):
        ch = body[i]
        if ch == "\\" and i + 1 < len(body) and not body[i + 1].isalnum():
            out.append(body[i + 1])
            i += 2
            continue
        if ch in METACHARACTERS:
            return None
        out.append(ch)
        i += 1
    return "".join(out)


def _split_target(target: str, hosts: set[str], base: str) -> tuple[str, str | None]:
    path, sep, query = target.partition("?")
    match = re.match(r"^https?://([^/]+)(/.*)?$", path, re.IGNORECASE)
    if match:
        host = match.group(1).lower()
        if host in hosts:
            path = match.group(2) or "/"
    elif not path.startswith("/"):
        # RewriteBase подставляется в относительную цель, а не в шаблон.
        path = base + path
    return path, (query if sep else None)


def parse_rule(tokens: list[str], base: str, hosts: set[str], line: str) -> Rule:
    if len(tokens) != 4:
        raise Untranslatable("ожидалось: RewriteRule ШАБЛОН ЦЕЛЬ [ФЛАГИ]")
    _, pattern, target, flag_token = tokens
    flags = _flags(flag_token)
    nc = "NC" in flags or "NOCASE" in flags
    code = int(flags.get("R") or 302)
    if target == "-":
        raise Untranslatable("редирект без цели")
    if not pattern.startswith("^"):
        raise Untranslatable("шаблон без якоря ^ совпадает в середине пути")
    body = pattern[1:]
    anchored = body.endswith("$") and not body.endswith("\\$")
    if anchored:
        body = body[:-1]
    if "$" in body.replace("\\$", ""):
        raise Untranslatable("$ посреди шаблона")
    if set(body) & UNSAFE or set(target) & UNSAFE:
        raise Untranslatable("кавычки, пробелы или фигурные скобки в правиле")
    literal = _unescape_literal(body)
    if literal == "" and not anchored:
        # location ^~ "/" совпал бы с location / ядра, и веб-сервер не
        # стартовал бы. Переезд всего сайта на другой адрес делает прокси.
        raise Untranslatable("редирект всего сайта это работа обратного прокси")
    path, query = _split_target(target, hosts, base)
    # Шаблон в .htaccess корня отсчитывается от корня, RewriteBase на него не влияет.
    if literal is not None and not nc:
        if re.search(r"\$", target):
            raise Untranslatable("$ в цели буквального правила")
        return Rule("exact" if anchored else "prefix", "/" + literal, path, query, code,
                    "QSA" in flags, nc, line)
    if literal is not None:
        body = re.escape(literal)
    if re.search(r"\$(?![0-9])", target):
        raise Untranslatable("переменная в цели")
    regex = "^/" + body + ("$" if anchored else "")
    return Rule("regex", regex, path, query, code, "QSA" in flags, nc, line)


def _lookup(path: str, exact: dict[str, Rule], prefixes: list[Rule]) -> Rule | None:
    if path in exact:
        return exact[path]
    # Из префиксов nginx выбирает самый длинный совпавший, так же и здесь.
    for rule in prefixes:
        if path.startswith(rule.match):
            return rule
    return None


def _is_self_loop(rule: Rule) -> bool:
    if not rule.internal or rule.query is not None:
        return False
    if rule.kind == "exact":
        return rule.target == rule.match
    if rule.kind == "prefix":
        return rule.target.startswith(rule.match)
    return False


def convert(text: str, hosts: set[str]) -> Result:
    hosts = {h.lower() for h in hosts} | {"www." + h.lower() for h in hosts}
    result = Result()
    base = "/"
    conditions: list[str] = []
    rules: list[Rule] = []

    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            tokens = shlex.split(line, posix=False)
        except ValueError:
            tokens = line.split()
        # Шаблоны и цели в кавычках: так пишет .htaccess из поставки MODX.
        tokens = [t[1:-1] if len(t) >= 2 and t[0] == t[-1] == '"' else t for t in tokens]
        directive = tokens[0].lower()
        if directive == "rewritebase" and len(tokens) > 1:
            base = tokens[1] if tokens[1].endswith("/") else tokens[1] + "/"
            continue
        if directive == "rewritecond":
            conditions.append(tokens[1] if len(tokens) > 1 else "")
            continue
        if directive in {"redirect", "redirectmatch", "redirectpermanent"}:
            # Семантика mod_alias другая: префикс с дописыванием хвоста.
            result.lost.append(f"{line}  # mod_alias переносится руками")
            continue
        if directive != "rewriterule":
            continue
        conds, conditions = conditions, []
        # Флаги ищутся в любом токене, а не только в последнем: мусор после них
        # иначе молча превратил бы редирект в «не редирект».
        flag_token = next((t for t in tokens[3:] if t.startswith("[") and t.endswith("]")), "")
        try:
            flags = _flags(flag_token) if flag_token else {}
        except Untranslatable:
            flags = {}
        if "R" not in flags and "REDIRECT" not in flags:
            result.not_redirects += 1
            continue
        if conds:
            variables = {re.sub(r"^%\{([^}]*)\}$", r"\1", c).upper() for c in conds}
            if variables <= PROXY_CONDITIONS:
                result.proxy_conditional.append(line)
            else:
                result.lost.append(f"{line}  # условие {', '.join(sorted(variables))} переносится руками")
            continue
        if "REDIRECT" in flags:
            flags["R"] = flags.pop("REDIRECT")
            tokens[tokens.index(flag_token)] = "[" + ",".join(f"{k}={v}" if v else k for k, v in flags.items()) + "]"
        try:
            rules.append(parse_rule(tokens, base, hosts, line))
        except (Untranslatable, ValueError) as error:
            result.lost.append(f"{line}  # {error}")

    # Повторы: первое правило побеждает, как отвечал Apache.
    kept: dict[tuple[str, str, bool], Rule] = {}
    for rule in rules:
        first = kept.get(rule.key)
        if first is None:
            kept[rule.key] = rule
        elif (first.target, first.query, first.code) == (rule.target, rule.query, rule.code):
            result.duplicates += 1
        else:
            result.conflicts.append(f"{rule.match}: {first.target}, повтор {rule.target} не срабатывал")

    live: list[Rule] = []
    for rule in kept.values():
        if _is_self_loop(rule):
            result.self_loops.append(rule.match)
        else:
            live.append(rule)

    exact = {r.match: r for r in live if r.kind == "exact"}
    prefixes = sorted((r for r in live if r.kind == "prefix"), key=lambda r: -len(r.match))

    final: list[Rule] = []
    for rule in live:
        if rule.kind == "regex":
            final.append(rule)
            continue
        hops = [rule.match]
        codes = [rule.code]
        target, query, current = rule.target, rule.query, rule
        cycle = False
        while current.internal and query is None:
            nxt = _lookup(target, exact, prefixes)
            if nxt is None:
                break
            if nxt.match in hops or target in hops:
                hops.append(target)
                cycle = True
                break
            hops.append(target)
            codes.append(nxt.code)
            target, query, current = nxt.target, nxt.query, nxt
        if cycle:
            result.cycles.append(" -> ".join(hops))
            continue
        if len(hops) > 1:
            result.chains.append(" -> ".join(hops + [target]))
        # Постоянный один прыжок, только если постоянным был каждый: иначе
        # поисковик навсегда склеит адрес с временной целью.
        code = rule.code if all(c in (301, 308) for c in codes) else 302
        final.append(Rule(rule.kind, rule.match, target, query, code, current.qsa, rule.nc, rule.line))

    result.config = render(final, result)
    return result


def _destination(rule: Rule) -> str:
    base = ("https://$host" + rule.target) if rule.internal else rule.target
    if rule.query is None:
        return base + "$is_args$args"
    return f"{base}?{rule.query}" + ("&$args" if rule.qsa else "")


def render(rules: list[Rule], result: Result) -> str:
    exact = sorted((r for r in rules if r.kind == "exact"), key=lambda r: r.match)
    prefix = sorted((r for r in rules if r.kind == "prefix"), key=lambda r: r.match)
    # Порядок регулярных значим: nginx берёт первое совпавшее, как и Apache.
    regex = [r for r in rules if r.kind == "regex"]
    result.exact, result.prefix, result.regex = len(exact), len(prefix), len(regex)
    lines = [
        "# Сгенерировано htaccess-to-nginx.py из .htaccess снимка. Руками не править:",
        "# повторный прогон restore.sh перепишет файл.",
        f"# {result.summary()}",
        "",
    ]
    for rule in exact:
        lines.append(f'location = "{rule.match}" {{ return {rule.code} "{_destination(rule)}"; }}')
    for rule in prefix:
        lines.append(f'location ^~ "{rule.match}" {{ return {rule.code} "{_destination(rule)}"; }}')
    for rule in regex:
        op = "~*" if rule.nc else "~"
        # В строке nginx в кавычках обратный слэш экранирует сам себя.
        pattern = rule.match.replace("\\", "\\\\")
        lines.append(f'location {op} "{pattern}" {{ return {rule.code} "{_destination(rule)}"; }}')
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    hosts: list[str] = []
    paths: list[str] = []
    args = iter(argv)
    for arg in args:
        if arg == "--host":
            value = next(args, None)
            if not value:
                print(__doc__, file=sys.stderr)
                return 2
            hosts.append(value)
        elif arg in {"-h", "--help"}:
            print(__doc__)
            return 0
        else:
            paths.append(arg)
    if len(paths) != 2 or not hosts:
        print(__doc__, file=sys.stderr)
        return 2
    source, out = Path(paths[0]), Path(paths[1])
    result = convert(source.read_text(encoding="utf-8", errors="replace"), set(hosts))

    for path in result.self_loops:
        print(f"  выброшен самопереход: {path}", file=sys.stderr)
    for note in result.chains:
        print(f"  схлопнута цепочка: {note}", file=sys.stderr)
    for note in result.conflicts:
        print(f"  повтор ключа с другой целью, взято первое: {note}", file=sys.stderr)
    for line in result.proxy_conditional:
        print(f"  условное на хост или схему, не переносится: {line}", file=sys.stderr)
    for note in result.cycles:
        print(f"  НЕРАЗРЕШИМАЯ ЦЕПОЧКА: {note}", file=sys.stderr)
    for line in result.lost:
        print(f"  НЕ ПЕРЕВОДИТСЯ: {line}", file=sys.stderr)
    print(result.summary())
    if result.exit_code:
        return result.exit_code
    tmp = out.with_name(out.name + ".new")
    tmp.write_text(result.config, encoding="utf-8")
    os.chmod(tmp, 0o644)
    os.replace(tmp, out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
