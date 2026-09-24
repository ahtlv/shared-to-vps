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
url="https://$host"

web=$slug-nginx
app=$slug-php-fpm
db_container=$slug-mariadb
site_volume=${slug}_site_data
internal_net=${slug}_internal
app_image=$slug-php-fpm:local
wpcli_image=$slug-wp-cli:local
marker_name=.shared-to-vps-restore
docroot=/var/www/html

# Фиксированный релиз с проверкой суммы: плавающий latest сделал бы один и тот
# же снимок разворачиваемым по-разному в разные дни.
wpcli_version=2.12.0
wpcli_sha256=ce34ddd838f7351d6759068d09793f26755463b4a4610a5a5c0a97b68220d85c

# Админ базы по сокету, без пароля: см. mariadb/initdb стека.
sql() { docker exec -i -u mysql "$db_container" mariadb -N -B "$@"; }

# Образ с инструментом командной строки WordPress поверх образа приложения.
# Отдельный, а не слой в работающем контейнере: в процессе, который исполняет
# код сайта, административный инструмент не нужен.
build_wpcli() {
    docker image inspect "$app_image" >/dev/null 2>&1 || die "нет образа $app_image: поднимите стек"
    docker build -q -t "$wpcli_image" - >/dev/null <<EOF || die 'образ инструмента командной строки не собрался'
FROM $app_image
RUN curl -fsSL https://github.com/wp-cli/wp-cli/releases/download/v$wpcli_version/wp-cli-$wpcli_version.phar -o /usr/local/bin/wp \\
 && echo "$wpcli_sha256  /usr/local/bin/wp" | sha256sum -c - \\
 && chmod 755 /usr/local/bin/wp
EOF
}

# wp АРГУМЕНТЫ: одноразовый контейнер во внутренней сети стека, докрут только
# на чтение, от пользователя приложения. Плагины и темы не грузятся: чинить
# базу надо и тогда, когда плагин из снимка падает при загрузке.
#
# Крон выключен. Каждая загрузка WordPress, в том числе инструментом, пускает
# просроченные задачи и пишет в базу метку времени запуска. Два одинаковых
# прогона разворачивания давали тогда разные таблицы, в зависимости от того,
# прошла ли минута с прошлой загрузки.
wp() {
    # Без -i: внутри цикла `while read` такой контейнер съел бы его stdin.
    docker run --rm --network "$internal_net" --user 82:82 -e HOME=/tmp -e WP_CLI_CACHE_DIR=/tmp/wp-cli \
        -v "$site_volume:$docroot:ro" --entrypoint wp "$wpcli_image" \
        --path="$docroot" --skip-plugins --skip-themes --exec='define("DISABLE_WP_CRON", true);' "$@"
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

# Остатки установщика архива внутри тома, по тем же правилам, что у помощника.
remnants_find="cd $docroot && { find . -maxdepth 1 \\( -name dup-installer -o -name installer.php \
-o -name php.ini -o -name .user.ini -o -name wp-snapshots -o -name '*installer-backup.php' \
-o -name '*_installer.php' -o -name 'dup-installer-bootlog__*' -o -name '*_archive.zip' -o -name '*_archive.daf' \\) -print; \
for p in wp-content/backups-dup-pro wp-content/backups-dup-lite wp-content/debug.log; do [ ! -e \$p ] || echo ./\$p; done; \
find . -name error_log -print; }"

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
