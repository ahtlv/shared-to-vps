#!/bin/sh
# Набор бэкапа: архив докрута, сжатый дамп базы, контрольные суммы и
# инструкция восстановления, в каталоге YYYY-MM-DD-{{SLUG}}.
#
#   scripts/backup.sh          из каталога отрендеренного стека, от root
#
# Набор становится набором только после двух реальных проверок: архив
# распакован в отдельный каталог и совпал по составу с исходником, дамп
# импортирован во временную схему. До этого всё лежит в скрытом
# промежуточном каталоге, и ничего с датой не видно. Публикация одним
# переименованием в пределах одной файловой системы: оборванный прогон
# оставляет только промежуточный каталог, который набором не считается.
#
# Ротация считает завершённые наборы (каталоги с SHA256SUMS), упорядоченные по
# дате в имени. Время изменения не участвует: сбитые часы, повторный прогон и
# ручное копирование меняют mtime, а не то, какой набор новее.
#
# Настройки в backup.conf рядом со стеком. Для однозначных ключей побеждает
# последняя строка. BACKUP_HOLD_FILE нужен только стенду: пока такой файл
# существует, прогон ждёт перед публикацией, чтобы стенд мог его оборвать.
#
# Код 0: набор проверен и опубликован, или проверенный набор за сегодня уже
# был. Код 1: набора нет, причина в stderr.
set -eu
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
stack=$(cd "$script_dir/.." && pwd)
conf=${BACKUP_CONF:-$stack/backup.conf}

slug={{SLUG}}
db_container={{SLUG}}-mariadb
site_volume={{SLUG}}_site_data
# Образ приложения уже есть на сервере и несёт tar: том читается свежим
# контейнером без сети и только на чтение, а не через работающее приложение.
helper_image={{SLUG}}-php-fpm:local

fail() { echo "бэкап не собран: $*" >&2; exit 1; }

[ -f "$conf" ] || fail "нет файла настроек: $conf"
# Пробелы вокруг ключа и значения срезаются, как в парсере сторожа.
conf_all() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$conf" | sed 's/[[:space:]]*$//'; }
conf_get() { conf_all "$1" | tail -n 1; }

db_name=$(conf_get db_name)
keep=$(conf_get keep)
backup_dir=$(conf_get backup_dir)
secrets_file=$(conf_get secrets_file)

case $db_name in ''|*[!A-Za-z0-9_]*) fail "db_name пуст или не из [A-Za-z0-9_]: $db_name" ;; esac
case $keep in ''|*[!0-9]*|0) fail "keep должен быть целым от единицы: $keep" ;; esac
case $backup_dir in /?*) ;; *) fail "backup_dir должен быть абсолютным путём: $backup_dir" ;; esac
[ -n "$secrets_file" ] || fail 'secrets_file не задан; отказ от проверки паролей только явный: secrets_file=none'

[ "$(id -u)" -eq 0 ] || fail 'запускать от root: каталог наборов закрыт для остальных'
for tool in docker tar gzip sha256sum flock find grep sort sed awk cmp du; do
    command -v "$tool" >/dev/null 2>&1 || fail "нет $tool"
done

mkdir -p "$backup_dir"
chmod 700 "$backup_dir"
exec 9>"$backup_dir/.backup.lock"
flock -n 9 || fail 'другой бэкап уже идёт'

# Админ базы по сокету, без пароля: см. mariadb/initdb в стеке.
db() { docker exec -u mysql "$db_container" "$@"; }
db_in() { docker exec -i -u mysql "$db_container" "$@"; }
sql() { db mariadb -N -B -e "$1"; }

[ -n "$(docker ps -q --filter "name=^$db_container\$" --filter health=healthy)" ] \
    || fail "$db_container не запущен или нездоров"
docker volume inspect "$site_volume" >/dev/null 2>&1 || fail "нет тома $site_volume"
docker image inspect "$helper_image" >/dev/null 2>&1 || fail "нет образа $helper_image"
[ -n "$(sql "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$db_name'")" ] \
    || fail "в базе нет схемы $db_name"
[ -f "$stack/BACKUP-RECOVERY.md" ] || fail 'нет BACKUP-RECOVERY.md: набор без инструкции не собирается'

# Уборка за прогонами, убитыми до своей уборки. Под замком никто другой ими
# не пользуется. Промежуточный каталог живёт сутки: его может захотеть увидеть
# человек, разбирающий, почему прогон оборвался.
for stale in $(sql "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME LIKE 'backup\\_check\\_%'"); do
    sql "DROP DATABASE \`$stale\`"
done
find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name '.staging-*' -mmin +1440 -exec rm -rf -- {} +

set_name=$(date -u +%F)-$slug
set_path=$backup_dir/$set_name
# Проверенный набор за сегодня уже есть: ручной прогон при настройке, потом
# таймер. Задача выполнена, и красный юнит здесь был бы ложной тревогой.
# Нужен свежий набор после правок сайта: удалить сегодняшний и повторить.
if [ -f "$set_path/SHA256SUMS" ]; then
    echo "набор за сегодня уже есть и проверен: $set_path; новый не собирается"
    exit 0
fi
[ ! -e "$set_path" ] || fail "$set_path существует, но это не набор: разберите руками"

stage=$backup_dir/.staging-$(date -u +%Y%m%dT%H%M%SZ)-$$
check_db=backup_check_$$
check_db_created=0
mkdir "$stage"
cleanup() {
    [ "$check_db_created" -eq 0 ] || sql "DROP DATABASE IF EXISTS \`$check_db\`" >/dev/null 2>&1 || true
    rm -rf -- "$stage"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# --- база ---
# Одна транзакция даёт согласованный снимок InnoDB без остановки сайта.
# Схема без CREATE DATABASE и USE: такой дамп импортируется в любую схему
# любой панели, а не только в одноимённую.
tables=$(sql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$db_name' AND TABLE_TYPE = 'BASE TABLE'")
[ "$tables" -gt 0 ] || fail "в схеме $db_name нет таблиц"
db mariadb-dump --single-transaction --quick --skip-lock-tables \
    --routines --events --triggers --hex-blob --default-character-set=utf8mb4 \
    "$db_name" >"$stage/database.sql"
[ -s "$stage/database.sql" ] || fail 'дамп пуст'
# DEFINER в триггерах, процедурах и представлениях требует при импорте права,
# которых у пользователя панели нет, и импорт обрывается на середине. Без
# DEFINER владельцем становится тот, кто импортирует.
sed -i 's/DEFINER=`[^`]*`@`[^`]*` \{0,1\}//g' "$stage/database.sql"

sql "CREATE DATABASE \`$check_db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
check_db_created=1
db_in mariadb --binary-mode=1 "$check_db" <"$stage/database.sql" || fail 'дамп не импортируется'
restored=$(sql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$check_db' AND TABLE_TYPE = 'BASE TABLE'")
[ "$restored" = "$tables" ] || fail "после импорта таблиц $restored, в исходной схеме $tables"
db mariadb-check --silent "$check_db" || fail 'импортированная схема не прошла mariadb-check'
sql "DROP DATABASE \`$check_db\`"
check_db_created=0

# --- файлы ---
# Том выгружается в дерево, из дерева убираются исключения, и архивируется уже
# оно. Потом дерево удаляется, архив распаковывается в отдельный каталог и
# обязан совпасть с деревом по составу: целый gzip ещё не значит, что из
# него встаёт докрут. На диске одновременно не больше двух копий сайта.
tree=$stage/tree
verify=$stage/verify
mkdir "$tree" "$verify"
# Код docker run в конвейере теряется, поэтому сбой отмечается файлом.
{ docker run --rm --network none --entrypoint tar -v "$site_volume:/site:ro" "$helper_image" \
    -C /site -cf - . || : >"$stage/.volume-failed"; } | tar -xf - -C "$tree" \
    || fail 'выгрузка тома не распаковывается'
[ ! -e "$stage/.volume-failed" ] || fail 'том сайта не читается'

{
    printf '%s\n' .env '.env.*' '*/.env' '*/.env.*' error_log '*/error_log'
    conf_all exclude
} | while IFS= read -r pattern; do
    case $pattern in
        '') continue ;;
        /*|*..*) echo "исключение должно быть относительным и без ..: $pattern" >&2; exit 1 ;;
    esac
    find "$tree" -path "$tree/$pattern" -prune -exec rm -rf -- {} +
done || fail 'исключения не применились'

[ -n "$(find "$tree" -type f -print -quit)" ] || fail 'в томе сайта нет ни одного файла'
(cd "$tree" && find . | LC_ALL=C sort) >"$stage/tree.lst"
tar -C "$tree" -czf "$stage/site-files.tar.gz" .
rm -rf -- "$tree"
gzip -t "$stage/site-files.tar.gz"
tar -xzf "$stage/site-files.tar.gz" -C "$verify" || fail 'архив не распаковывается'
(cd "$verify" && find . | LC_ALL=C sort) >"$stage/verify.lst"
cmp -s "$stage/tree.lst" "$stage/verify.lst" || fail 'распакованный архив не совпал с исходником по составу'
conf_all expect | while IFS= read -r path; do
    [ -z "$path" ] || [ -e "$verify/$path" ] || { echo "в архиве нет обязательного $path" >&2; exit 1; }
done || fail 'архив неполон'

# --- пароли ---
# Значения читаются из файла окружения прямо в grep и нигде не оседают: ни в
# переменной, ни во временном файле, ни в выводе. Печатается только, где
# нашлось. Берутся только ключи, похожие на секрет: имя базы и пользователя
# лежат в том же файле, но в дампе встречаются всегда, и бэкап падал бы
# каждую ночь.
secret_values() {
    grep -iE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z0-9_]*(PASS|SECRET|TOKEN|KEY|SALT|AUTH)[A-Za-z0-9_]*=' "$secrets_file" \
        | sed 's/^[^=]*=//' \
        | sed "s/^\"\(.*\)\"\$/\1/; s/^'\(.*\)'\$/\1/" \
        | awk 'length($0) >= 8'
}
if [ "$secrets_file" != none ]; then
    [ -f "$secrets_file" ] || fail "нет файла с паролями $secrets_file; отказ от проверки только явный: secrets_file=none"
    [ "$(secret_values | wc -l)" -gt 0 ] || fail "в $secrets_file нет ключей *PASS*, *SECRET*, *TOKEN*, *KEY*, *SALT*, *AUTH* со значением от восьми символов: проверять нечем"
    leaked=$(
        secret_values | grep -rlF -f - "$verify" | sed "s|^$verify/|  файл |" || true
        secret_values | grep -qF -f - "$stage/database.sql" && echo '  дамп базы' || true
    )
    [ -z "$leaked" ] || fail "в набор попал живой пароль (значение не печатается):
$leaked"
fi

rm -rf -- "$verify" "$stage/tree.lst" "$stage/verify.lst"
gzip -9 "$stage/database.sql"
gzip -t "$stage/database.sql.gz"
cp "$stack/BACKUP-RECOVERY.md" "$stage/RESTORE.md"
(
    cd "$stage"
    sha256sum site-files.tar.gz database.sql.gz RESTORE.md >SHA256SUMS
    sha256sum -c --quiet SHA256SUMS
) || fail 'контрольные суммы не сходятся сразу после записи'

if [ -n "${BACKUP_HOLD_FILE:-}" ]; then
    : >"$BACKUP_HOLD_FILE.reached"
    while [ -e "$BACKUP_HOLD_FILE" ]; do sleep 1; done
fi

# Публикация. Повторная проверка под тем же замком: если бы набор появился,
# mv положил бы промежуточный каталог внутрь него, а не на его место.
[ ! -e "$set_path" ] || fail "набор за сегодня уже есть: $set_path"
mv "$stage" "$set_path"
trap - EXIT INT TERM HUP

complete_sets() {
    for d in "$backup_dir"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-"$slug"; do
        [ -f "$d/SHA256SUMS" ] && basename "$d"
    done | LC_ALL=C sort
}
count=$(complete_sets | wc -l)
excess=$((count - keep))
if [ "$excess" -gt 0 ]; then
    # Только что опубликованный не удаляется никогда, даже если рядом лежит
    # набор с датой из будущего.
    complete_sets | grep -vxF "$set_name" | head -n "$excess" | while IFS= read -r old; do
        rm -rf -- "${backup_dir:?}/$old"
    done
fi

size=$(du -sk "$set_path" | awk '{print $1}')
echo "набор проверен и опубликован: $set_path ($size КБ, таблиц $tables, наборов $(complete_sets | wc -l | tr -d ' '))"
