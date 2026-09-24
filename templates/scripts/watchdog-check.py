#!/usr/bin/env python3
"""Сверить живую площадку с эталоном сторожа целостности.

    python3 scripts/watchdog-check.py

Эталон снимается ПОСЛЕ приёмки (scripts/watchdog-baseline.py). Сверяются
файлы тома сайта по содержимому, число пользователей и опубликованных
объектов, публичный robots.txt побайтово. Смена одного времени изменения
находкой не считается: содержимое то же.

Каждый прогон пишется в журнал рядом с эталоном. Если в watchdog.conf задан
notify_command, итог уходит ему на stdin.

Код 0: совпадает с эталоном. Код 1: находки. Код 2: сторож не смог
проверить, и это тоже тревога, а не тишина.
"""

from __future__ import annotations

import subprocess
import sys

from watchdog_common import Config, ConfigError, append_log, load_baseline, snapshot

SHOWN = 50


def listed(title: str, paths: list[str]) -> str:
    head = ", ".join(paths[:SHOWN])
    tail = f" и ещё {len(paths) - SHOWN}" if len(paths) > SHOWN else ""
    return f"{title} ({len(paths)}): {head}{tail}"


def compare(baseline: dict, current: dict) -> list[str]:
    findings = []
    before, after = baseline["files"], current["files"]
    new = sorted(set(after) - set(before))
    removed = sorted(set(before) - set(after))
    changed = sorted(p for p in set(before) & set(after) if before[p] != after[p])
    if new:
        findings.append(listed("новые файлы", new))
    if changed:
        findings.append(listed("изменённые файлы", changed))
    if removed:
        findings.append(listed("пропавшие файлы", removed))
    if current["users"] != baseline["users"]:
        findings.append(f"число пользователей: было {baseline['users']}, стало {current['users']}")
    if current["objects"] != baseline["objects"]:
        findings.append(f"число опубликованных объектов: было {baseline['objects']}, стало {current['objects']}")
    b_robots, c_robots = baseline["robots"], current["robots"]
    if (b_robots["status"], b_robots["sha256"]) != (c_robots["status"], c_robots["sha256"]):
        findings.append(f"robots.txt отличается от эталона: код {b_robots['status']} -> {c_robots['status']}")
    return findings


def notify(cfg: Config, summary: str) -> None:
    if cfg.notify_command:
        subprocess.run(cfg.notify_command, shell=True, input=summary, text=True, check=True, timeout=120)


def main() -> int:
    cfg = None
    try:
        cfg = Config()
        baseline = load_baseline(cfg)
        current = snapshot(cfg)
    except (ConfigError, RuntimeError, OSError, KeyError, ValueError) as exc:
        summary = f"сторож не смог проверить: {exc}"
        print(summary, file=sys.stderr)
        if cfg is not None:
            try:
                append_log(cfg, summary)
                notify(cfg, summary)
            except Exception as extra:  # noqa: BLE001 — тревога уже поднята кодом 2
                print(f"вдобавок не записался журнал или уведомление: {extra}", file=sys.stderr)
        return 2

    findings = compare(baseline, current)
    if findings:
        summary = f"НАХОДКИ ({len(findings)}) против эталона от {baseline.get('captured_at', '?')}:\n" \
            + "\n".join(f"  - {f}" for f in findings)
    else:
        unchecked = [name for name, sql in (("пользователи", cfg.users_sql), ("объекты", cfg.objects_sql)) if not sql]
        note = f"; не проверяются: {', '.join(unchecked)}" if unchecked else ""
        summary = f"чисто: {len(current['files'])} файлов, счётчики и robots.txt совпадают с эталоном{note}"
    print(summary)
    try:
        append_log(cfg, summary.replace("\n", " "))
        notify(cfg, summary)
    except Exception as exc:  # noqa: BLE001
        print(f"не записался журнал или уведомление: {exc}", file=sys.stderr)
        return 2
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
