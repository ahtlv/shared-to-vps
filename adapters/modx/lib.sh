# Общее для restore.sh и verify.sh. Подключается точкой, сам не запускается.
#
# Адаптер лежит в каталоге adapter/ отрендеренного стека, рядом со scripts/
# ядра. Всё о площадке он берёт из стека, а не из своих аргументов: слаг из
# .rendered-slug, имя хоста из smoke/smoke.conf, схему базы из backup.conf.
# Так у стека один источник правды, и адаптер не может разойтись с ядром.

adapter_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
stack=$(cd "$adapter_dir/.." && pwd)
helper="$adapter_dir/restore_helper.py"

die() { echo "$*" >&2; exit 1; }

[ -f "$stack/.rendered-slug" ] || die "нет $stack/.rendered-slug: адаптер лежит не в каталоге отрендеренного стека"
slug=$(cat "$stack/.rendered-slug")

# conf_last FILE KEY: последнее значение ключа, как читают ядро и сторож.
conf_last() { sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | sed 's/[[:space:]]*$//' | tail -n 1; }

host=$(conf_last "$stack/smoke/smoke.conf" host)
db_name=$(conf_last "$stack/backup.conf" db_name)
[ -n "$host" ] || die 'в smoke/smoke.conf не задан host'
case $db_name in ''|*[!A-Za-z0-9_]*) die "db_name в backup.conf пуст или не из [A-Za-z0-9_]: $db_name" ;; esac

web=$slug-nginx
app=$slug-php-fpm
db_container=$slug-mariadb
site_volume=${slug}_site_data
internal_net=${slug}_internal
app_image=$slug-php-fpm:local
marker_name=.shared-to-vps-restore
docroot=/var/www/html

# Админ базы по сокету, без пароля: см. mariadb/initdb стека.
sql() { docker exec -i -u mysql "$db_container" mariadb -N -B "$@"; }

# modx_php КОМАНДА АРГУМЕНТЫ: modx.php в одноразовом контейнере приложения во
# внутренней сети стека, докрут только на чтение, от пользователя приложения.
# Реквизиты базы берутся из конфига сайта, а не из .env: так каждый вызов
# заодно доказывает, что конфиг и база согласованы.
modx_php() {
    docker run --rm -i --network "$internal_net" --user 82:82 -v "$site_volume:$docroot:ro" \
        --entrypoint php "$app_image" -- "$@" <"$adapter_dir/modx.php"
}

# in_volume [-i] КОМАНДА: sh в свежем контейнере без сети с томом сайта.
in_volume() {
    tty=''
    [ "${1:-}" = -i ] && { tty=-i; shift; }
    docker run --rm $tty --network none --user 0 -v "$site_volume:$docroot" --entrypoint sh "$app_image" -c "$1"
}

# in_volume_ro КОМАНДА: то же, но том только на чтение. Всё, что осматривает
# докрут, ходит сюда: в осматриваемом могут лежать имена и файлы, подложенные
# чужим, и root с томом на запись им не нужен.
in_volume_ro() {
    docker run --rm --network none --user 0 -v "$site_volume:$docroot:ro" --entrypoint sh "$app_image" -c "$1"
}

# Установщик и остатки хостинга внутри тома, по тем же правилам, что у помощника.
remnants_find="cd $docroot && { find . -maxdepth 1 \\( -name setup -o -name php.ini -o -name .user.ini -o -name .ftpquota \\) -print; \
find . \\( -name error_log -o -name .ftp-deploy-sync-state.json \\) -print; }"

# Кэш MODX: настройки, контексты, ресурсы, кэш расширений вроде хранилища
# настроек получателей форм. Всё собирается заново при первом запросе.
clear_cache() {
    in_volume "set -e; mkdir -p $docroot/core/cache; find $docroot/core/cache -mindepth 1 -maxdepth 1 -exec rm -rf {} +; chown 82:82 $docroot/core/cache"
}

wait_healthy() {
    i=0
    while [ "$i" -lt 60 ]; do
        a=$(docker inspect -f '{{.State.Health.Status}}' "$app" 2>/dev/null || true)
        w=$(docker inspect -f '{{.State.Health.Status}}' "$web" 2>/dev/null || true)
        [ "$a" = healthy ] && [ "$w" = healthy ] && return 0
        i=$((i + 1))
        sleep 2
    done
    die "стек не стал здоровым: $app=$a $web=$w"
}

# Имя таблицы с префиксом из конфига сайта.
read_prefix() {
    in_volume_ro "cat $docroot/core/config/config.inc.php" 2>/dev/null \
        | sed -n "s/^[[:space:]]*\$table_prefix[[:space:]]*=[[:space:]]*'\([A-Za-z0-9_]*\)'.*/\1/p" | head -n 1
}
