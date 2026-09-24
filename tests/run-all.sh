#!/bin/sh
# Все проверки репозитория. Прогоняет каждую и падает в конце, а не на первой:
# оборвавшись на середине, агрегатор скрывает состояние остальных линтеров.
# Ненаписанный линтер это тоже нарушение, а не повод промолчать.
set -u
cd "$(dirname "$0")/.." || exit 1
fails=0

run() {
    script=$1; shift
    if [ ! -x "$script" ]; then
        echo "MISSING  $script не найден" >&2
        fails=$((fails + 1))
        return
    fi
    "$script" "$@" || fails=$((fails + 1))
}

# Линтер аллоулиста принадлежит рабочему репозиторию и наружу не уезжает
# намеренно (см. PUBLIC.manifest). В публичной сборке его отсутствие это
# ожидаемое состояние, а не непройденная проверка.
run_if_present() {
    script=$1; shift
    if [ -x "$script" ]; then "$script" "$@" || fails=$((fails + 1))
    else echo "skip  $script: только в рабочем репозитории"; fi
}

run_py() {
    python3 "$1" >/dev/null 2>&1 && echo "PASS  $1" || { echo "FAIL  $1: python3 $1" >&2; fails=$((fails + 1)); }
}

run ./tests/lint-anon.sh "$@"
run ./tests/lint-structure.sh
run ./tests/lint-gotchas.sh
run_if_present ./tests/lint-unpublished.sh
run ./tests/render_test.sh
# Самотест смоука: подставной сайт на localhost, без сети и докера.
run ./templates/smoke/selftest/run.sh
# Адаптеры: юниты без докера. Стенды адаптеров на докере запускаются отдельно.
run_py adapters/wordpress/test_adapter.py
run_py adapters/modx/test_adapter.py

[ "$fails" -eq 0 ] || { echo "проверки: $fails не прошли" >&2; exit 1; }
echo 'все линтеры зелёные'
