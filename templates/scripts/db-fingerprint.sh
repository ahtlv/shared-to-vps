#!/bin/sh
# Отпечаток содержимого базы: сумма дампа каждой таблицы, а не число строк.
#
#   scripts/db-fingerprint.sh >before.txt           из каталога стека, от root
#   scripts/db-fingerprint.sh --compare before.txt   после повтора разворачивания
#   scripts/db-fingerprint.sh --db other_schema      схема не из backup.conf
#
# Счётчик строк не видит правку внутри строки: повтор разворачивания, который
# переписал время правки настроек или метку запуска крона, даёт те же числа и
# другие данные. Здесь каждая таблица выгружается в стабильном порядке (по
# первичному ключу, по строке на запись, без даты дампа) и хэшируется целиком.
#
# Вывод: строка на таблицу, «имя  сумма  строк». Число строк для человека,
# сравнение идёт по сумме.
#
# Код 0: отпечаток снят или совпал с сохранённым. Код 1: таблицы разошлись,
# их список в stderr. Код 2: база недоступна или аргументы неверны.
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
stack=$(cd "$script_dir/.." && pwd)
conf=${BACKUP_CONF:-$stack/backup.conf}
db_container={{SLUG}}-mariadb

db_name=''
compare=''
while [ "$#" -gt 0 ]; do
    case $1 in
        --db) [ "$#" -ge 2 ] || { echo '--db без значения' >&2; exit 2; }; db_name=$2; shift 2 ;;
        --compare) [ "$#" -ge 2 ] || { echo '--compare без значения' >&2; exit 2; }; compare=$2; shift 2 ;;
        -h | --help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$db_name" ] && [ -f "$conf" ]; then
    db_name=$(sed -n 's/^[[:space:]]*db_name[[:space:]]*=[[:space:]]*//p' "$conf" | sed 's/[[:space:]]*$//' | tail -n 1)
fi
case $db_name in ''|*[!A-Za-z0-9_]*) echo "имя схемы пусто или не из [A-Za-z0-9_]: '$db_name'" >&2; exit 2 ;; esac
if [ -n "$compare" ] && [ ! -s "$compare" ]; then
    echo "сохранённого отпечатка нет или он пуст: $compare" >&2
    exit 2
fi

# Админ базы по сокету, без пароля: см. mariadb/initdb в стеке.
db() { docker exec -u mysql "$db_container" "$@"; }

tables=$(db mariadb -N -B -e "SELECT table_name FROM information_schema.tables
    WHERE table_schema = '$db_name' AND table_type = 'BASE TABLE' ORDER BY table_name" 2>/dev/null) \
    || { echo "база недоступна: контейнер $db_container, схема $db_name" >&2; exit 2; }
[ -n "$tables" ] || { echo "в схеме $db_name нет таблиц: отпечаток пустой базы ничего не доказывает" >&2; exit 2; }

current=$(mktemp)
dump=$(mktemp)
trap 'rm -f "$current" "$dump"' EXIT

for t in $tables; do
    # --compact убирает комментарии и дату, --skip-extended-insert даёт строку
    # на запись, --order-by-primary делает порядок одинаковым между прогонами.
    # AUTO_INCREMENT в CREATE TABLE тоже входит в сумму: повтор, который
    # вставил и удалил строку, этим и виден.
    # Через файл, а не трубой: у трубы код последней команды, и упавший дамп
    # дал бы сумму пустого вывода.
    db mariadb-dump --single-transaction --skip-lock-tables --compact \
        --skip-extended-insert --order-by-primary --hex-blob "$db_name" "$t" >"$dump" \
        || { echo "таблица $t не выгрузилась" >&2; exit 2; }
    sum=$(sha256sum <"$dump" | cut -d' ' -f1)
    rows=$(db mariadb -N -B -e "SELECT COUNT(*) FROM \`$db_name\`.\`$t\`")
    printf '%s  %s  %s\n' "$t" "$sum" "$rows" >>"$current"
done

if [ -z "$compare" ]; then
    cat "$current"
    exit 0
fi

# Сравнение по имени и сумме: пропавшая, новая и изменённая таблица видны
# одинаково.
diff_out=$(awk 'NR == FNR { saved[$1] = $2; next }
    { seen[$1] = 1; if (!($1 in saved)) print "новая: " $1; else if (saved[$1] != $2) print "изменена: " $1 }
    END { for (t in saved) if (!(t in seen)) print "пропала: " t }' "$compare" "$current" | sort)
if [ -z "$diff_out" ]; then
    echo "отпечаток совпал: таблиц $(wc -l <"$current" | tr -d ' ')"
    exit 0
fi
printf '%s\n' "$diff_out" >&2
echo "отпечаток разошёлся: таблиц $(printf '%s\n' "$diff_out" | wc -l | tr -d ' ')" >&2
exit 1
