#!/bin/sh
# Рендер обязан падать до записи результата, а не выдавать конфиг с мусором.
set -u
cd "$(dirname "$0")/.."
fails=0
fail() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }
pass() { printf 'PASS  %s\n' "$1"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 1. Полный профиль: рендер проходит, заглушек не осталось.
if ./bin/render --profile tests/fixtures/example-site.yaml --out "$work/full" >/dev/null 2>&1; then
    if grep -rq '{{' "$work/full"; then fail 'в результате остались заглушки'
    else pass 'полный профиль рендерится без остатка заглушек'; fi
else
    fail 'рендер упал на полном профиле'
fi

# 2. Неполный профиль: отказ с именем поля, код 2, каталог результата не создан.
incomplete="$work/incomplete.yaml"
grep -v '^domain:' tests/fixtures/example-site.yaml > "$incomplete"
out=$(./bin/render --profile "$incomplete" --out "$work/partial" 2>&1); code=$?
if [ "$code" -eq 2 ] && printf '%s' "$out" | grep -q 'domain'; then
    pass 'неполный профиль отвергнут с именем поля'
else
    fail "неполный профиль: код $code, вывод: $out"
fi
if [ -d "$work/partial" ] && [ -n "$(ls -A "$work/partial" 2>/dev/null)" ]; then
    fail 'при отказе рендер всё равно записал файлы'
else
    pass 'при отказе результат не записан'
fi

# 3. Второй стек с тем же слагом в том же каталоге: конфликт, код 3.
./bin/render --profile tests/fixtures/example-site.yaml --out "$work/full" >/dev/null 2>&1
out=$(./bin/render --profile tests/fixtures/example-site.yaml --out "$work/full" 2>&1); code=$?
if [ "$code" -eq 3 ] && printf '%s' "$out" | grep -qi 'слаг\|slug'; then
    pass 'повторный рендер того же слага отвергнут как конфликт'
else
    fail "конфликт слага: код $code, вывод: $out"
fi

# 4. Другой слаг рядом: имена контейнеров, сетей и томов не совпадают.
./bin/render --profile tests/fixtures/example-site-2.yaml --out "$work/second" >/dev/null 2>&1
if [ "$(grep -h 'container_name:' "$work/full/compose.yml" | sort)" \
   = "$(grep -h 'container_name:' "$work/second/compose.yml" | sort)" ]; then
    fail 'два разных слага дали одинаковые имена контейнеров'
else
    pass 'разные слаги дают разные имена контейнеров'
fi

[ "$fails" -eq 0 ] || { echo "рендер: $fails нарушений" >&2; exit 1; }
echo 'рендер: в порядке'
