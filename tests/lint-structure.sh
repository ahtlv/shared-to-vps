#!/bin/sh
# Проверяет то, что делает скилл работоспособным, а не его прозу:
# валидность frontmatter, длину маршрутизатора, наличие ворот у каждой фазы,
# отсутствие битых внутренних ссылок.
set -u
cd "$(dirname "$0")/.." || exit 1
fails=0
fail() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }
pass() { printf 'PASS  %s\n' "$1"; }

# --- frontmatter маршрутизатора ---
if [ "$(head -1 SKILL.md)" = '---' ]; then pass 'SKILL.md начинается с frontmatter'
else fail 'SKILL.md не начинается с ---'; fi

if grep -q '^name: shared-to-vps$' SKILL.md; then pass 'имя скилла в нижнем регистре'
else fail 'во frontmatter нет строки "name: shared-to-vps"'; fi

if grep -q '^description: .\{80,\}' SKILL.md; then pass 'описание с триггерами непустое'
else fail 'description отсутствует или короче 80 символов'; fi

# --- длина маршрутизатора ---
lines=$(grep -c '' SKILL.md)
if [ "$lines" -le 150 ]; then pass "SKILL.md $lines строк, лимит 150"
else fail "SKILL.md разросся до $lines строк, лимит 150"; fi

# --- обязательные разделы фаз ---
# Счётчик ведётся отдельный: общий уже мог вырасти на проверках выше, и
# `[ "$fails" -eq 0 ] && pass` соврал бы про фазы из-за чужого нарушения.
sections_fails=0
phase_pages=$(ls references/[0-7]0-*.md 2>/dev/null || true)
if [ -z "$phase_pages" ]; then
    fail 'страниц фаз не найдено'
    sections_fails=1
else
    for f in $phase_pages; do
        for section in '## Зачем эта фаза' '## Порядок' '## Ворота' '## Чего не делать'; do
            grep -qxF "$section" "$f" || {
                fail "$f: нет раздела «${section}»"
                sections_fails=$((sections_fails + 1))
            }
        done
    done
fi
[ "$sections_fails" -eq 0 ] && pass 'у всех фаз есть обязательные разделы'

# --- внутренние ссылки ---
# Список битых ссылок собирается в файл, а не в переменную: конвейер запускает
# `while` в подоболочке, и увеличенный там счётчик до кода возврата не доедет.
broken=$(mktemp)
for src in SKILL.md README.md references/*.md cases/*.md; do
    [ -e "$src" ] || continue
    grep -o '](\([a-zA-Z0-9_./-]*\.md\)\(#[^)]*\)\{0,1\})' "$src" 2>/dev/null \
      | sed 's/^](//; s/)$//; s/#.*$//' \
      | sort -u > "$broken.links"
    while IFS= read -r link; do
        [ -n "$link" ] || continue
        if [ ! -f "$(dirname "$src")/$link" ]; then
            printf '%s: битая ссылка на %s\n' "$src" "$link" >> "$broken"
        fi
    done < "$broken.links"
done
if [ -s "$broken" ]; then
    while IFS= read -r line; do fail "$line"; done < "$broken"
fi
rm -f "$broken" "$broken.links"

if [ "$fails" -gt 0 ]; then echo "структура: $fails нарушений" >&2; exit 1; fi
echo 'структура: в порядке'
