#!/bin/sh
# Ищет строки, которых в публичном репозитории быть не должно: реальные домены,
# адреса, имена аккаунтов. Список приходит снаружи (из профиля площадки), в
# репозитории лежит только фикстура для самопроверки самого линтера.
#
# Историю смотрим наравне с рабочим деревом: строка, удалённая последним
# коммитом, остаётся в публичном репозитории навсегда.
set -u

forbidden=''
check_history=0

while [ "$#" -gt 0 ]; do
    case $1 in
        --forbidden) [ "$#" -ge 2 ] || { echo 'нужен путь после --forbidden' >&2; exit 2; }
                     forbidden=$2; shift 2 ;;
        --history)   check_history=1; shift ;;
        *)           echo "неизвестный аргумент: $1" >&2; exit 2 ;;
    esac
done

[ -n "$forbidden" ] || forbidden="${SHARED_TO_VPS_FORBIDDEN:-$HOME/.claude/shared-to-vps/forbidden.txt}"

if [ ! -f "$forbidden" ]; then
    echo "список запрещённых строк не найден: $forbidden" >&2
    echo 'создайте его в профиле площадки или передайте --forbidden' >&2
    exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
fails=0

while IFS= read -r needle; do
    case $needle in ''|'#'*) continue ;; esac

    # docs/plans исключён так же, как tests/fixtures: план дословно цитирует
    # фикстуру линтера для документации и никогда не публикуется (см.
    # PUBLIC.manifest), так что совпадение здесь не утечка.
    hits=$(git -C "$root" grep -n -F -i -- "$needle" -- . ':!tests/fixtures' ':!docs/plans' 2>/dev/null || true)
    if [ -n "$hits" ]; then
        printf 'FAIL  рабочее дерево содержит «%s»\n%s\n' "$needle" "$hits" >&2
        fails=$((fails + 1))
    fi

    if [ "$check_history" -eq 1 ]; then
        # -S ищет коммиты, в которых число вхождений строки изменилось: так
        # находится и добавление, и удаление.
        commits=$(git -C "$root" log --oneline -S"$needle" -- . ':!tests/fixtures' ':!docs/plans' 2>/dev/null || true)
        if [ -n "$commits" ]; then
            printf 'FAIL  история содержит «%s»\n%s\n' "$needle" "$commits" >&2
            fails=$((fails + 1))
        fi
    fi
done < "$forbidden"

if [ "$fails" -gt 0 ]; then
    echo "обезличивание: $fails находок" >&2
    exit 1
fi

echo 'обезличивание: чисто'
