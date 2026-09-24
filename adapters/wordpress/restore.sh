#!/bin/sh
# Разворачивание WordPress из принятого снимка в поднятый стек. Идемпотентно.
#
#   adapter/restore.sh --archive FILE --sha256 SUM [опции]      из каталога стека, от root
#
#   --archive FILE       zip плагина бэкапа или tar.gz файлов сайта
#   --sha256 SUM         сумма архива, зафиксированная при проверке снимка
#   --dump FILE          дамп базы, если в архиве его нет или их несколько;
#   --dump-sha256 SUM    тогда обязательно с суммой
#   --old-path PATH      корень старой площадки, повторяемый. Найденные в дампе
#                        корни перед /wp-content/ добавляются сами и печатаются
#   --old-url URL        адрес старой площадки, если он отличается от нового
#   --force              развернуть заново, даже если этот снимок уже стоит
#
# Порядок: сумма, распаковка с проверкой путей во временный каталог, удаление
# установщика и его остатков, новый конфиг из реквизитов .env стека, остановка
# веб-сервера и приложения, замена тома целиком, пересоздание схемы и импорт,
# правка путей в том числе внутри сериализованных значений, проверка, что
# следов старой площадки в базе нет, запуск, метка в докруте. Метка пишется
# последней: пока её нет, снимок не считается развёрнутым.
#
# Штатный веб-установщик архива не используется. Он рассчитан на панель
# хостинга, тянет свою логику правки путей и сам остаётся в докруте
# исполняемым кодом с полными правами. Сюда он не попадает вовсе.
#
# ОБОРВАННЫЙ ПРОГОН ПЕРЕЗАПУСКАЕТСЯ ЦЕЛИКОМ, той же командой. Руками поверх
# него ничего не докручивается: состояние после обрыва по кодам ответа
# выглядит исправным, а на деле это половина сайта. После замены тома и до
# метки веб-сервер и приложение остановлены, чтобы половина не отвечала
# посетителям. Повтор той же командой без метки разворачивает всё заново.
#
# WP_RESTORE_HOLD_FILE нужен только стенду: пока такой файл есть, прогон ждёт
# сразу после импорта, чтобы стенд мог его оборвать.
#
# Код 0: развёрнуто или уже было развёрнуто. Код 1: отказ. Код 2: аргументы.
set -eu
umask 077

usage() { sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0" >&2; exit 2; }

archive='' sum='' dump='' dump_sum='' old_url='' force=0 old_paths=''
while [ "$#" -gt 0 ]; do
    case $1 in
        --archive) [ "$#" -ge 2 ] || usage; archive=$2; shift 2 ;;
        --sha256) [ "$#" -ge 2 ] || usage; sum=$2; shift 2 ;;
        --dump) [ "$#" -ge 2 ] || usage; dump=$2; shift 2 ;;
        --dump-sha256) [ "$#" -ge 2 ] || usage; dump_sum=$2; shift 2 ;;
        --old-path) [ "$#" -ge 2 ] || usage; old_paths="$old_paths
${2%/}"; shift 2 ;;
        --old-url) [ "$#" -ge 2 ] || usage; old_url=${2%/}; shift 2 ;;
        --force) force=1; shift ;;
        -h | --help) usage ;;
        *) echo "неизвестный аргумент: $1" >&2; usage ;;
    esac
done
[ -n "$archive" ] && [ -n "$sum" ] || usage
[ -z "$dump" ] && [ -z "$dump_sum" ] || { [ -n "$dump" ] && [ -n "$dump_sum" ]; } || { echo '--dump и --dump-sha256 только вместе' >&2; exit 2; }

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
cd "$stack"

[ "$(id -u)" -eq 0 ] || die 'запускать от root: .env стека и тома принадлежат root'
for tool in docker python3 sha256sum flock tar gzip sed grep; do
    command -v "$tool" >/dev/null 2>&1 || die "нет $tool"
done
exec 9>"$stack/.restore.lock"
flock -n 9 || die 'другое разворачивание уже идёт'
# Промежуточный каталог прогона, убитого до своей уборки, несёт распакованный
# сайт и дамп базы. Под замком он точно ничей.
rm -rf -- "$stack"/.restore-stage.*

[ -f "$archive" ] || die "архив не найден: $archive"
echo "--- снимок"
actual=$(sha256sum "$archive" | cut -d' ' -f1)
[ "$actual" = "$sum" ] || die "сумма архива $actual, а зафиксирована $sum: это не тот снимок"
echo "архив: сумма совпала"
if [ -n "$dump" ]; then
    [ -f "$dump" ] || die "дамп не найден: $dump"
    actual=$(sha256sum "$dump" | cut -d' ' -f1)
    [ "$actual" = "$dump_sum" ] || die "сумма дампа $actual, а зафиксирована $dump_sum"
    echo "дамп: сумма совпала"
fi

# Метка описывает не только архив, но и то, как его разворачивали: другой
# --old-url с тем же архивом это другой результат.
expected_marker=$(printf 'archive=%s\ndump=%s\nurl=%s\nold_url=%s\nold_path=%s\n' \
    "$sum" "${dump_sum:-inside}" "$url" "$old_url" "$(printf '%s' "$old_paths" | sed '/^$/d' | sort | tr '\n' ' ')")

install_nginx() {
    mkdir -p "$stack/nginx/adapter"
    cat "$adapter_dir/nginx.conf" >"$stack/nginx/adapter/wordpress.conf"
    chmod 644 "$stack/nginx/adapter/wordpress.conf"
}

# set_single FILE KEY VALUE: одиночный ключ. Пустая строка шаблона заменяется,
# заполненную человеком адаптер не трогает.
set_single() {
    if grep -q "^$2=..*" "$1"; then return 0; fi
    if grep -q "^$2=\$" "$1"; then
        esc=$(printf '%s' "$3" | sed 's/[\&|]/\\&/g')
        sed "s|^$2=\$|$2=$esc|" "$1" >"$1.new" && cat "$1.new" >"$1" && rm -f "$1.new"
    else
        printf '%s=%s\n' "$2" "$3" >>"$1"
    fi
}
# add_line FILE LINE: повторяемый ключ или «последний побеждает»: дописать, если
# точно такой строки ещё нет.
add_line() { grep -qxF -- "$2" "$1" || printf '%s\n' "$2" >>"$1"; }

# Своё для ядра: бэкап, сторож, смоук. Дописывается, а не переписывается, и
# повтор ничего не дублирует.
configure_stack() {
    prefix=$1
    for line in 'exclude=wp-config.php' 'exclude=wp-content/cache' 'expect=index.php' \
        'expect=wp-includes/version.php' 'expect=wp-content'; do
        add_line "$stack/backup.conf" "$line"
    done
    for line in "users_sql=SELECT COUNT(*) FROM ${prefix}users" \
        "objects_sql=SELECT COUNT(*) FROM ${prefix}posts WHERE post_status = 'publish' AND post_type IN ('page', 'post')" \
        'uploads=wp-content/uploads' 'exclude=wp-content/cache/' 'exclude=wp-content/upgrade/'; do
        add_line "$stack/watchdog.conf" "$line"
    done
    set_single "$stack/smoke/smoke.conf" marker '/wp-content/'
    if ! grep -q '^page=..*' "$stack/smoke/smoke.conf"; then
        pages=$(smoke_pages)
        if [ "$(printf '%s\n' "$pages" | grep -c .)" -ge 2 ]; then
            grep -v '^page=$' "$stack/smoke/smoke.conf" >"$stack/smoke/smoke.conf.new"
            printf '%s\n' "$pages" | sed 's/^/page=/' >>"$stack/smoke/smoke.conf.new"
            cat "$stack/smoke/smoke.conf.new" >"$stack/smoke/smoke.conf"
            rm -f "$stack/smoke/smoke.conf.new"
        else
            echo 'смоук: двух опубликованных страниц разного типа не нашлось, page= заполнить руками'
        fi
    fi
    grep -q '^form_url=..*' "$stack/smoke/smoke.conf" \
        || echo 'смоук: форма у каждого сайта своя, form_url= и поля заполнить руками (или form_url=none)'
    grep -q '^expect=..*' "$stack/smoke/smoke.conf" \
        || echo 'смоук: expect= выписать из слепка старой площадки, «/путь текст» (или expect=none, если слепка нет)'
}

# Опубликованная страница, не главная, и последняя запись: разные типы, чтобы
# копия одного шаблона не прошла за два разных адреса.
smoke_pages() {
    {
        wp post list --post_type=page --post_status=publish --orderby=ID --order=ASC --field=url 2>/dev/null \
            | grep -vx "$url/\?" | head -n 1
        wp post list --post_type=post --post_status=publish --orderby=date --order=DESC --posts_per_page=1 --field=url 2>/dev/null
    } | sed "s|^$url||" | grep '^/' || true
}

read_marker() { in_volume_ro "cat $docroot/$marker_name 2>/dev/null" 2>/dev/null || true; }

# --- уже развёрнуто ---------------------------------------------------------
if [ "$force" -eq 0 ] && [ "$(read_marker)" = "$expected_marker" ]; then
    echo '--- этот снимок уже развёрнут, проверяю, что он на месте'
    prefix=$(in_volume_ro "cat $docroot/wp-config.php" 2>/dev/null | sed -n "s/^\$table_prefix = '\(.*\)';\$/\1/p")
    [ -n "$prefix" ] || die 'метка есть, а конфига нет: повторите с --force'
    [ -z "$(in_volume_ro "$remnants_find")" ] || die 'метка есть, но в докруте остатки установщика: повторите с --force'
    [ "$(sql -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$db_name' AND TABLE_NAME = '${prefix}options'")" = 1 ] \
        || die "метка есть, а в базе нет ${prefix}options: повторите с --force"
    install_nginx
    docker compose up -d >/dev/null 2>&1 || die 'стек не поднялся'
    wait_healthy
    docker exec "$web" nginx -s reload >/dev/null
    build_wpcli
    configure_stack "$prefix"
    echo 'уже развёрнуто: файлы и база не менялись'
    exit 0
fi

# --- подготовка во временном каталоге ---------------------------------------
stage=$(mktemp -d "$stack/.restore-stage.XXXXXX")
touched=0
done_ok=0
cleanup() {
    rm -rf -- "$stage"
    [ "$done_ok" -eq 1 ] && return 0
    if [ "$touched" -eq 1 ]; then
        docker compose stop "$web" php-fpm >/dev/null 2>&1 || true
        echo 'разворачивание оборвано после замены тома: веб-сервер и приложение оставлены остановленными.' >&2
        echo 'перезапустите ту же команду целиком, руками не докручивайте.' >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

echo '--- распаковка'
mkdir "$stage/docroot"
python3 "$helper" extract "$archive" "$stage/docroot" >"$stage/count" || die 'архив отвергнут'
echo "файлов: $(cat "$stage/count")"
[ -f "$stage/docroot/index.php" ] || die 'в снимке нет index.php'
[ -f "$stage/docroot/wp-includes/version.php" ] || die 'в снимке нет ядра WordPress'
[ -d "$stage/docroot/wp-content" ] || die 'в снимке нет wp-content'

if [ -z "$dump" ]; then
    found=$(python3 "$helper" find-dump "$stage/docroot") || die 'дамп не найден'
    case $found in *.gz) dump=$stage/dump.sql.gz ;; *) dump=$stage/dump.sql ;; esac
    mv "$found" "$dump"
    echo "дамп из снимка: ${found#"$stage/docroot/"}"
fi
prefix=$(python3 "$helper" prefix "$dump") || die 'префикс таблиц не определён'
echo "префикс таблиц: $prefix"

# Все корни старой площадки: названные и найденные. Найденный, но не
# переписанный путь это след старой площадки в рабочей базе.
python3 "$helper" old-paths "$dump" >"$stage/found-paths"
{ printf '%s\n' "$old_paths"; cut -f1 "$stage/found-paths"; } | sed '/^$/d' | sort -u >"$stage/old-paths"
# Корень, который сам префикс нового, замена испортила бы: /var/www даёт
# /var/www/html/html, а поиск следов потом вечно находит /var/www в новом.
while IFS= read -r old; do
    case $docroot/ in "$old"/*) die "корень старой площадки $old это префикс нового $docroot: автоматическая замена его испортит, нужен ручной разбор" ;; esac
done <"$stage/old-paths"
if [ -s "$stage/old-paths" ]; then
    echo 'корни старой площадки, будут заменены на /var/www/html:'
    sed 's/^/  /' "$stage/old-paths"
else
    echo 'корней старой площадки в дампе не найдено'
fi

# Адрес сверяется до сноса тома: опечатка в аргументе не должна класть сайт.
db_home=$(python3 "$helper" home "$dump" "$prefix") || die 'адрес сайта в дампе не найден'
if [ "$db_home" != "$url" ]; then
    [ -n "$old_url" ] || die "в базе адрес $db_home, а сайт будет $url: передайте --old-url $db_home"
    [ "$old_url" = "$db_home" ] || die "в базе адрес $db_home, а --old-url $old_url: замена по нему ничего бы не нашла"
fi

if [ -f "$stage/docroot/wp-config.php" ]; then
    dropped=$(python3 "$helper" dropped-defines "$stage/docroot/wp-config.php")
    [ -z "$dropped" ] || { echo 'конфиг снимка не переносится; его константы, которых нет в новом:'; printf '%s\n' "$dropped" | sed 's/^/  /'; }
fi

echo '--- установщик и остатки: в докрут не попадут'
# Код возврата левой части конвейера в POSIX sh теряется, поэтому через файл.
python3 "$helper" remnants "$stage/docroot" --delete >"$stage/remnants" || die 'остатки не убраны'
sed 's/^/  /' "$stage/remnants"
# Корень: ни одного дампа. Найденный уже вынут, чужой здесь это утечка базы.
if find "$stage/docroot" -maxdepth 1 -type f \( -name '*.sql' -o -name '*.sql.gz' \) | grep -q .; then
    die 'в корне снимка остался дамп базы: передайте его --dump или уберите из архива'
fi

if [ -f "$stage/docroot/robots.txt" ] && [ ! -f "$stack/smoke/robots.txt.reference" ]; then
    cp "$stage/docroot/robots.txt" "$stack/smoke/robots.txt.reference"
    chmod 644 "$stack/smoke/robots.txt.reference"
    echo 'эталон robots.txt для смоука взят из снимка'
fi

python3 "$helper" wp-config "$stack/.env" "$db_name" "$prefix" "$url" "$stage/docroot" || die 'конфиг не сгенерирован'
db_user=$(sed -n 's/^WP_DB_USER=//p' "$stack/.env" | tail -n 1)
case $db_user in ''|*[!A-Za-z0-9_]*) die "WP_DB_USER в .env пуст или не из [A-Za-z0-9_]" ;; esac
mkdir -p "$stage/docroot/wp-content/uploads"

build_wpcli
install_nginx

# --- замена тома и базы -----------------------------------------------------
echo '--- замена тома'
docker compose up -d mariadb >/dev/null 2>&1 || die 'база не поднялась'
docker compose stop "$web" php-fpm >/dev/null 2>&1 || die 'не остановить веб-сервер и приложение'
touched=1
# Метка живёт в томе и исчезает первой, вместе со всем остальным.
{ tar -C "$stage/docroot" -cf - . || : >"$stage/pipe-failed"; } | in_volume -i "set -e
    find $docroot -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    tar -xf - -C $docroot
    chown -R 82:82 $docroot
    find $docroot -type d -exec chmod 755 {} +
    find $docroot -type f -exec chmod 644 {} +
    chmod 640 $docroot/wp-config.php" || die 'том не заменён'
[ ! -e "$stage/pipe-failed" ] || die 'архив докрута оборвался по дороге в том'

echo '--- база'
i=0
until [ -n "$(docker ps -q --filter "name=^$db_container\$" --filter health=healthy)" ]; do
    i=$((i + 1)); [ "$i" -lt 60 ] || die "$db_container не стал здоровым"; sleep 2
done
esc_pass=$(sed -n 's/^WP_DB_PASSWORD=//p' "$stack/.env" | tail -n 1 | sed "s/\\\\/\\\\\\\\/g; s/'/''/g")
# Через stdin, а не аргументом: пароль не должен светиться в списке процессов.
sql <<SQL || die 'схема и пользователь не созданы'
DROP DATABASE IF EXISTS \`$db_name\`;
CREATE DATABASE \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$db_user'@'%' IDENTIFIED BY '$esc_pass';
ALTER USER '$db_user'@'%' IDENTIFIED BY '$esc_pass';
GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'%';
SQL
{
    case $dump in
        *.gz) gzip -dc "$dump" ;;
        *) cat "$dump" ;;
    esac || : >"$stage/pipe-failed"
} | docker exec -i -u mysql "$db_container" mariadb --binary-mode=1 "$db_name" || die 'дамп не импортировался'
[ ! -e "$stage/pipe-failed" ] || die 'дамп не прочитан целиком'
echo "таблиц: $(sql -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$db_name'")"

if [ -n "${WP_RESTORE_HOLD_FILE:-}" ]; then
    : >"$WP_RESTORE_HOLD_FILE.reached"
    while [ -e "$WP_RESTORE_HOLD_FILE" ]; do sleep 1; done
fi

echo '--- пути и адрес'
wp core is-installed || die 'WordPress не видит установку в импортированной базе'

# replace OLD NEW: как есть и в JSON-виде со слэшем через обратный. Точный
# режим разбирает сериализованные значения и правит длины строк, иначе PHP
# при чтении такой строки молча отдаёт false вместо настроек.
replace() {
    for pair in "$1|$2" "$(printf '%s' "$1" | sed 's|/|\\/|g')|$(printf '%s' "$2" | sed 's|/|\\/|g')"; do
        wp search-replace "${pair%%|*}" "${pair#*|}" --all-tables-with-prefix --precise --report-changed-only --format=count >/dev/null \
            || die "замена не прошла: ${pair%%|*}"
    done
}
while IFS= read -r old; do
    [ -n "$old" ] && replace "$old" "$docroot"
done <"$stage/old-paths"
[ -z "$old_url" ] || replace "$old_url" "$url"
sql "$db_name" -e "UPDATE \`${prefix}options\` SET option_value = '$url' WHERE option_name IN ('home', 'siteurl')"

# Проверка независимо от инструмента замены: свежий дамп и поиск следов в нём.
docker exec -u mysql "$db_container" mariadb-dump --single-transaction --skip-extended-insert "$db_name" >"$stage/after.sql" \
    || die 'проверочный дамп не снят'
python3 "$helper" old-paths "$stage/after.sql" >"$stage/left"
[ ! -s "$stage/left" ] || { cat "$stage/left" >&2; die 'в базе остались пути старой площадки'; }
while IFS= read -r old; do
    [ -n "$old" ] || continue
    for form in "$old" "$(printf '%s' "$old" | sed 's|/|\\\\/|g')"; do
        ! grep -qF -- "$form" "$stage/after.sql" || die "в базе остался след старой площадки: $old"
    done
done <"$stage/old-paths"
if [ -n "$old_url" ]; then
    for form in "$old_url" "$(printf '%s' "$old_url" | sed 's|/|\\\\/|g')"; do
        ! grep -qF -- "$form" "$stage/after.sql" || die "в базе остался адрес старой площадки: $old_url"
    done
fi
echo 'следов старой площадки в базе нет'

echo '--- запуск'
docker compose up -d >/dev/null 2>&1 || die 'стек не поднялся'
wait_healthy
docker exec "$web" nginx -t >/dev/null 2>&1 || die 'конфиг веб-сервера с запретами адаптера не проходит проверку'
docker exec "$web" nginx -s reload >/dev/null

printf '%s\n' "$expected_marker" | in_volume -i "cat >$docroot/$marker_name && chown 82:82 $docroot/$marker_name && chmod 640 $docroot/$marker_name" \
    || die 'метка не записана'
done_ok=1

configure_stack "$prefix"

echo '--- эталон для приёмки'
echo "пользователей: $(sql "$db_name" -e "SELECT COUNT(*) FROM \`${prefix}users\`")"
echo "опубликовано страниц и записей: $(sql "$db_name" -e "SELECT COUNT(*) FROM \`${prefix}posts\` WHERE post_status = 'publish' AND post_type IN ('page', 'post')")"
echo "таблиц: $(sql -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$db_name'")"
echo 'развёрнуто. Дальше: второй прогон той же командой, затем adapter/verify.sh'
