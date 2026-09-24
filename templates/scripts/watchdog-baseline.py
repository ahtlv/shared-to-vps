#!/usr/bin/env python3
"""Снять эталон сторожа целостности.

    python3 scripts/watchdog-baseline.py            первый раз, после приёмки
    python3 scripts/watchdog-baseline.py --force    переснять после принятого изменения

Эталон снимается ПОСЛЕ приёмки, по принятому состоянию докрута. Снятый
раньше, он превращает каждый перенесённый файл в находку, и сторожа
выключают на второй день. По той же причине существующий эталон без --force
не перезаписывается: переснятие это решение «изменение принято», а не способ
заглушить находку. Необъяснённую находку сначала разбирают.

Код 0: эталон записан. Код 2: эталон уже есть, настройки неполны или
снимок не удался.
"""

from __future__ import annotations

import argparse
import json
import sys

from watchdog_common import Config, ConfigError, append_log, now_iso, snapshot, write_private


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--force", action="store_true", help="заменить существующий эталон")
    args = parser.parse_args()
    try:
        cfg = Config()
        if cfg.baseline_path.exists() and not args.force:
            raise ConfigError(f"эталон уже есть: {cfg.baseline_path}; --force только после принятого изменения")
        state = snapshot(cfg)
    except (ConfigError, RuntimeError, OSError) as exc:
        print(f"эталон не снят: {exc}", file=sys.stderr)
        return 2

    state["captured_at"] = now_iso()
    write_private(cfg.baseline_path, json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    summary = (f"эталон снят: файлов {len(state['files'])}, пользователей {state['users']}, "
               f"опубликованных объектов {state['objects']}, robots.txt код {state['robots']['status']}")
    append_log(cfg, summary)
    print(summary)
    print(f"записан в {cfg.baseline_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
