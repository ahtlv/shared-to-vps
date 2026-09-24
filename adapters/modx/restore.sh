#!/bin/sh
# Разворачивание MODX из принятого снимка в поднятый стек. Идемпотентно.
#
#   adapter/restore.sh --archive FILE --sha256 SUM [опции]      из каталога стека, от root
#
#   --archive FILE       zip или tar.gz с докрутом. Префикс хостинга вроде
#                        data/www/имя/ допустим: докрут находится сам
#   --sha256 SUM         сумма архива, зафиксированная при проверке снимка
#   --dump FILE          дамп базы, если в архиве его нет или их несколько;
#   --dump-sha256 SUM    тогда обязательно с суммой
#   --htaccess FILE      исправленная копия .htaccess для генератора редиректов,
#                        если правила из снимка без потерь не переводятся
#   --force              развернуть заново, даже если этот снимок уже стоит
#
# Порядок: сумма, распаковка с проверкой путей во временный каталог, перевод
# редиректов генератором, удаление установщика, остатков хостинга и кэша,
# конфиг из реквизитов .env стека, остановка веб-сервера и приложения, замена
# тома целиком, пересоздание схемы и пользователя базы с тем же паролем,
# импорт, пути и медиа-источники в базе, проверка, что следов старой площадки
# в настройках нет, сброс кэша, запуск, метка в докруте. Метка пишется
# последней: пока её нет, снимок не считается развёрнутым.
#
# Пароль базы пишется в конфиг и в базу одним прогоном из одного источника,
# .env стека. Отдельного шага «поправить конфиг» нет, поэтому его нельзя
# забыть: рассинхрон пароля и конфига уже давал отказ всего сайта.
#
# ОБОРВАННЫЙ ПРОГОН ПЕРЕЗАПУСКАЕТСЯ ЦЕЛИКОМ, той же командой. Руками поверх
# него ничего не докручивается: после обрыва сайт отвечал 200 на каждый адрес
# и рисовал главную, и ручные правки это не лечили. После замены тома и до
# метки веб-сервер и приложение остановлены.
#
# MODX_RESTORE_HOLD_FILE нужен только стенду: пока такой файл есть, прогон ждёт
# сразу после импорта, чтобы стенд мог его оборвать.
#
# Код 0: развёрнуто или уже было развёрнуто. Код 1: отказ. Код 2: аргументы.
set -eu
umask 077

usage() { sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0" >&2; exit 2; }

archive='' sum='' dump='' dump_sum='' htaccess='' force=0
while [ "$#" -gt 0 ]; do
    case $1 in
        --archive) [ "$#" -ge 2 ] || usage; archive=$2; shift 2 ;;
        --sha256) [ "$#" -ge 2 ] || usage; sum=$2; shift 2 ;;
        --dump) [ "$#" -ge 2 ] || usage; dump=$2; shift 2 ;;
        --dump-sha256) [ "$#" -ge 2 ] || usage; dump_sum=$2; shift 2 ;;
        --htaccess) [ "$#" -ge 2 ] || usage; htaccess=$2; shift 2 ;;
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
[ -z "$htaccess" ] || [ -f "$htaccess" ] || die "нет файла $htaccess"
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

# Метка описывает не только архив, но и то, как его разворачивали.
htaccess_sum=$([ -z "$htaccess" ] && echo inside || sha256sum "$htaccess" | cut -d' ' -f1)
expected_marker=$(printf 'archive=%s\ndump=%s\nhost=%s\nhtaccess=%s\n' "$sum" "${dump_sum:-inside}" "$host" "$htaccess_sum")

install_nginx() {
    mkdir -p "$stack/nginx/adapter"
    cat "$adapter_dir/nginx.conf" >"$stack/nginx/adapter/modx.conf"
    cat "$1" >"$stack/nginx/adapter/modx-redirects.conf"
    chmod 644 "$stack/nginx/adapter/modx.conf" "$stack/nginx/adapter/modx-redirects.conf"
}

# redirects SRC OUT: редиректы из .htaccess. Нет файла, нет и правил.
redirects() {
    if [ -s "$1" ]; then
        python3 "$adapter_dir/htaccess-to-nginx.py" "$1" "$2" --host "$host" \
            || die 'редиректы из .htaccess не переводятся без потерь: правила перечислены выше. Исправьте копию .htaccess и передайте её --htaccess'
    else
        : >"$2.empty"
        python3 "$adapter_dir/htaccess-to-nginx.py" "$2.empty" "$2" --host "$host" >/dev/null
        rm -f "$2.empty"
        echo 'редиректов нет: в снимке нет .htaccess'
    fi
}

# nginx_preflight REDIRECTS: конфиг веб-сервера с новыми файлами адаптера
# проверяется до сноса тома, отдельным контейнером того же образа. Правило
# редиректа, совпавшее с location ядра, иначе уронило бы веб-сервер уже
# после замены тома.
nginx_preflight() {
    pre=$stage/nginx-preflight
    rm -rf "$pre"; mkdir -p "$pre/adapter"
    for f in "$stack"/nginx/adapter/*.conf; do
        case ${f##*/} in modx.conf | modx-redirects.conf) ;; *) [ ! -f "$f" ] || cp "$f" "$pre/adapter/" ;; esac
    done
    cp "$adapter_dir/nginx.conf" "$pre/adapter/modx.conf"
    cp "$1" "$pre/adapter/modx-redirects.conf"
    chmod -R a+rX "$pre"
    web_image=$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(nginx:[^[:space:]]*\).*/\1/p' "$stack/compose.yml" | head -n 1)
    [ -n "$web_image" ] || die 'образ веб-сервера в compose.yml не найден'
    docker run --rm --network none --add-host php-fpm:127.0.0.1 \
        -v "$stack/nginx/00-tuning.conf:/etc/nginx/conf.d/00-tuning.conf:ro" \
        -v "$stack/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro" \
        -v "$pre/adapter:/etc/nginx/adapter:ro" "$web_image" nginx -t >"$pre/out" 2>&1 \
        || { sed 's/^/  /' "$pre/out" >&2; die 'конфиг веб-сервера с правилами адаптера не проходит проверку: том не тронут'; }
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
add_line() { grep -qxF -- "$2" "$1" || printf '%s\n' "$2" >>"$1"; }

# Своё для ядра: бэкап, сторож, смоук. Дописывается, а не переписывается.
configure_stack() {
    prefix=$1
    for line in 'exclude=core/config/db-password.inc.php' 'exclude=core/cache' \
        'expect=index.php' 'expect=config.core.php' 'expect=core/config/config.inc.php'; do
        add_line "$stack/backup.conf" "$line"
    done
    for line in "users_sql=SELECT COUNT(*) FROM ${prefix}users" \
        "objects_sql=SELECT COUNT(*) FROM ${prefix}site_content WHERE published = 1 AND deleted = 0" \
        'uploads=assets/images' 'exclude=core/cache/' 'exclude=assets/components/phpthumbof/cache/'; do
        add_line "$stack/watchdog.conf" "$line"
    done
    set_single "$stack/smoke/smoke.conf" marker 'assets/'
    if ! grep -q '^page=..*' "$stack/smoke/smoke.conf"; then
        pages=$(sample_pages "$prefix" 2 | cut -f1)
        if [ "$(printf '%s\n' "$pages" | grep -c .)" -ge 2 ]; then
            grep -v '^page=$' "$stack/smoke/smoke.conf" >"$stack/smoke/smoke.conf.new"
            printf '%s\n' "$pages" | sed 's/^/page=/' >>"$stack/smoke/smoke.conf.new"
            cat "$stack/smoke/smoke.conf.new" >"$stack/smoke/smoke.conf"
            rm -f "$stack/smoke/smoke.conf.new"
        else
            echo 'смоук: двух опубликованных страниц с разными шаблонами не нашлось, page= заполнить руками'
        fi
    fi
    grep -q '^form_url=..*' "$stack/smoke/smoke.conf" \
        || echo 'смоук: форма у каждого сайта своя, form_url= и поля заполнить руками (или form_url=none)'
    grep -q '^expect=..*' "$stack/smoke/smoke.conf" \
        || echo 'смоук: expect= выписать из слепка старой площадки, «/путь текст» (или expect=none, если слепка нет)'
}

read_marker() { in_volume_ro "cat $docroot/$marker_name 2>/dev/null" 2>/dev/null || true; }

. "$adapter_dir/pages.sh"

# --- уже развёрнуто ---------------------------------------------------------
if [ "$force" -eq 0 ] && [ "$(read_marker)" = "$expected_marker" ]; then
    echo '--- этот снимок уже развёрнут, проверяю, что он на месте'
    prefix=$(read_prefix)
    [ -n "$prefix" ] || die 'метка есть, а конфига нет: повторите с --force'
    [ -z "$(in_volume_ro "$remnants_find")" ] || die 'метка есть, но в докруте установщик или остатки хостинга: повторите с --force'
    [ "$(sql -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$db_name' AND TABLE_NAME = '${prefix}site_content'")" = 1 ] \
        || die "метка есть, а в базе нет ${prefix}site_content: повторите с --force"
    modx_php paths >/dev/null || die 'метка есть, а конфиг не подключается к базе: повторите с --force'
    stage=$(mktemp -d "$stack/.restore-stage.XXXXXX")
    trap 'rm -rf -- "$stage"' EXIT
    if [ -n "$htaccess" ]; then cp "$htaccess" "$stage/htaccess"
    else in_volume_ro "cat $docroot/.htaccess 2>/dev/null || true" >"$stage/htaccess"; fi
    redirects "$stage/htaccess" "$stage/redirects.conf" >/dev/null
    nginx_preflight "$stage/redirects.conf"
    install_nginx "$stage/redirects.conf"
    docker compose up -d >/dev/null 2>&1 || die 'стек не поднялся'
    wait_healthy
    docker exec "$web" nginx -t >/dev/null 2>&1 || die 'конфиг веб-сервера с правилами адаптера не проходит проверку'
    docker exec "$web" nginx -s reload >/dev/null
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
mkdir "$stage/unpacked"
python3 "$helper" extract "$archive" "$stage/unpacked" >"$stage/count" || die 'архив отвергнут'
echo "файлов: $(cat "$stage/count")"
site=$(python3 "$helper" find-root "$stage/unpacked") || die 'докрут не найден'
echo "докрут в архиве: ${site#"$stage/unpacked"}/"
if [ -z "$dump" ]; then
    found=$(python3 "$helper" find-dump "$stage/unpacked" "$site") || die 'дамп не найден'
    case $found in *.gz) dump=$stage/dump.sql.gz ;; *) dump=$stage/dump.sql ;; esac
    # Из докрута вынимается: дамп в корне сайта это утечка всей базы.
    mv "$found" "$dump"
    echo "дамп из снимка: ${found#"$stage/unpacked/"}"
fi
mv "$site" "$stage/docroot"

info=$(python3 "$helper" config "$stage/docroot") || die 'конфиг снимка не прочитан'
old_root=$(printf '%s' "$info" | cut -f1)
prefix=$(printf '%s' "$info" | cut -f2)
echo "префикс таблиц: $prefix"
echo "корень старой площадки: $old_root"
# Корень, который сам префикс нового, замена испортила бы: /var/www даёт
# /var/www/html/html.
case $docroot/ in "$old_root"/?*) die "корень старой площадки $old_root это префикс нового $docroot: автоматическая замена его испортит" ;; esac

echo '--- редиректы со старой структуры'
if [ -n "$htaccess" ]; then cp "$htaccess" "$stage/htaccess"
elif [ -f "$stage/docroot/.htaccess" ]; then cp "$stage/docroot/.htaccess" "$stage/htaccess"
else : >"$stage/htaccess"; fi
redirects "$stage/htaccess" "$stage/redirects.conf"
nginx_preflight "$stage/redirects.conf"
echo 'конфиг веб-сервера с правилами адаптера проходит проверку'

echo '--- установщик, остатки хостинга и кэш: в докрут не попадут'
python3 "$helper" remnants "$stage/docroot" --delete >"$stage/remnants" || die 'остатки не убраны'
sed 's/^/  /' "$stage/remnants"
if find "$stage/docroot" -maxdepth 1 -type f \( -name '*.sql' -o -name '*.sql.gz' \) | grep -q .; then
    die 'в корне снимка остался дамп базы: передайте его --dump или уберите из архива'
fi
mkdir -p "$stage/docroot/core/cache"
# Метка из набора бэкапа описывает чужой прогон. Своя пишется последней.
rm -f "$stage/docroot/$marker_name"

if [ -f "$stage/docroot/robots.txt" ] && [ ! -f "$stack/smoke/robots.txt.reference" ]; then
    cp "$stage/docroot/robots.txt" "$stack/smoke/robots.txt.reference"
    chmod 644 "$stack/smoke/robots.txt.reference"
    echo 'эталон robots.txt для смоука взят из снимка'
fi

python3 "$helper" write-config "$stack/.env" "$db_name" "$stage/docroot" "$old_root" || die 'конфиг не приведён к реквизитам стека'
echo 'конфиг: реквизиты базы из .env стека, пути нового докрута'
# Тем же разбором .env, что писал конфиг: два разных разбора однажды дадут
# конфигу и базе разные пароли.
db_user=$(python3 "$helper" env-get "$stack/.env" MODX_DB_USER) || die 'MODX_DB_USER в .env не прочитан'
case $db_user in ''|*[!A-Za-z0-9_]*) die "MODX_DB_USER в .env пуст или не из [A-Za-z0-9_]" ;; esac

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
    chmod 640 $docroot/core/config/config.inc.php $docroot/core/config/db-password.inc.php" || die 'том не заменён'
[ ! -e "$stage/pipe-failed" ] || die 'архив докрута оборвался по дороге в том'

echo '--- база'
i=0
until [ -n "$(docker ps -q --filter "name=^$db_container\$" --filter health=healthy)" ]; do
    i=$((i + 1)); [ "$i" -lt 60 ] || die "$db_container не стал здоровым"; sleep 2
done
db_pass=$(python3 "$helper" env-get "$stack/.env" MODX_DB_PASSWORD) || die 'MODX_DB_PASSWORD в .env не прочитан'
[ -n "$db_pass" ] || die 'MODX_DB_PASSWORD в .env пуст'
esc_pass=$(printf '%s' "$db_pass" | sed "s/\\\\/\\\\\\\\/g; s/'/''/g")
# Тот же пароль, что только что записан в конфиг, из того же .env. Через
# stdin, а не аргументом: пароль не должен светиться в списке процессов.
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

if [ -n "${MODX_RESTORE_HOLD_FILE:-}" ]; then
    : >"$MODX_RESTORE_HOLD_FILE.reached"
    while [ -e "$MODX_RESTORE_HOLD_FILE" ]; do sleep 1; done
fi

echo '--- пути, адрес и медиа-источники'
# Первый вызов с реквизитами из конфига: если конфиг и база разошлись, отказ
# здесь, до запуска, а не 500 на всём сайте после.
modx_php fix "$old_root" "https://$host/" >"$stage/fix" 2>&1 || { cat "$stage/fix" >&2; die 'правка базы не прошла'; }
sed 's/^/  /' "$stage/fix"

# Проверка независимо от правки: свежий дамп и поиск старого корня в нём.
docker exec -u mysql "$db_container" mariadb-dump --single-transaction --skip-extended-insert "$db_name" >"$stage/after.sql" \
    || die 'проверочный дамп не снят'
# Из собственного бэкапа старый корень и есть новый: искать нечего.
: >"$stage/left"
if [ "$old_root" != "$docroot" ]; then
    # В JSON слэш экранирован, а дамп экранирует ещё и обратный слэш: \\/.
    json_root=$(printf '%s/' "$old_root" | sed 's|/|\\\\/|g')
    grep -F -e "$old_root/" -e "$json_root" "$stage/after.sql" | sed -n 's/^INSERT INTO `\([^`]*\)`.*/\1/p' | sort | uniq -c >"$stage/left" || true
fi
if [ -s "$stage/left" ]; then
    echo 'следы старой площадки в таблицах (строк):'
    sed 's/^/  /' "$stage/left"
    # По настройкам и медиа-источникам сайт работает, и след там это поломка.
    # В журналах и пакетах установки это история, её видно человеку.
    ! grep -Eq " ${prefix}(system_settings|context_setting|user_settings|media_sources)\$" "$stage/left" \
        || die 'в настройках или медиа-источниках остался путь старой площадки'
else
    echo 'следов старой площадки в базе нет'
fi

echo '--- кэш'
# После правок в базе, а не до: иначе первый запрос соберёт кэш из того, что
# было в базе на момент прошлого запуска, и настройки получателей форм и
# медиа-источников останутся старыми при исправленной базе.
clear_cache || die 'кэш не сброшен'
echo 'кэш настроек, контекстов и ресурсов сброшен'

echo '--- запуск'
install_nginx "$stage/redirects.conf"
docker compose up -d >/dev/null 2>&1 || die 'стек не поднялся'
wait_healthy
docker exec "$web" nginx -t >/dev/null 2>&1 || die 'конфиг веб-сервера с правилами адаптера не проходит проверку'
docker exec "$web" nginx -s reload >/dev/null

printf '%s\n' "$expected_marker" | in_volume -i "cat >$docroot/$marker_name && chown 82:82 $docroot/$marker_name && chmod 640 $docroot/$marker_name" \
    || die 'метка не записана'
done_ok=1

configure_stack "$prefix"

echo '--- эталон для приёмки'
echo "пользователей: $(sql "$db_name" -e "SELECT COUNT(*) FROM \`${prefix}users\`")"
echo "опубликовано ресурсов: $(sql "$db_name" -e "SELECT COUNT(*) FROM \`${prefix}site_content\` WHERE published = 1 AND deleted = 0")"
echo "таблиц: $(sql -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$db_name'")"
echo 'развёрнуто. Дальше: второй прогон той же командой, затем adapter/verify.sh'
