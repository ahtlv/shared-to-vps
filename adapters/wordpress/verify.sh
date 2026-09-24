#!/bin/sh
# Внутренняя приёмка развёрнутого WordPress: то, что снаружи принципиально не видно.
#
#   adapter/verify.sh --user admin:administrator --user editor --published 26 \
#       --plugin forms-plugin --mu-plugins 17 [--old-path PATH] [--old-url URL]
#
#   --user LOGIN[:ROLE]  ожидаемый пользователь, повторяемый. Набор логинов
#                        обязан совпасть точно: лишний админ это находка
#   --published N        опубликованных страниц и записей
#   --plugin SLUG        обязательный плагин: лежит на диске и включён. Повторяемый
#   --mu-plugins N       PHP-файлов в mu-plugins, если сайт на них держится
#   --old-path PATH      корень старой площадки, повторяемый: его следов быть не должно
#   --old-url URL        адрес старой площадки: его следов быть не должно
#
# Эталонные числа передаются аргументами, а не зашиты: их печатает restore.sh
# в конце разворачивания, и сверяются они с тем, что видел человек на старой
# площадке. После первой легитимной публикации числа меняются, и это
# ожидаемо: приёмка делается один раз, до переключения.
#
# Проверяет: пользователей и роли, число опубликованного, обязательные
# плагины, целостность всех таблиц сайта, владельца и режимы докрута,
# отсутствие кода в загрузках сверх заглушек, отсутствие установщика и его
# остатков, эффективные пути глазами самого приложения, отсутствие следов
# старой площадки в базе и конфиге, запреты веб-сервера живыми пробниками,
# ответ главной мимо кэша.
#
# Код 0: всё сошлось. Код 1: есть находки, перечислены. Код 2: аргументы или
# стек не поднят.
set -u

usage() { sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0" >&2; exit 2; }

users='' published='' plugins='' mu='' old_paths='' old_url=''
while [ "$#" -gt 0 ]; do
    case $1 in
        --user) [ "$#" -ge 2 ] || usage; users="$users $2"; shift 2 ;;
        --published) [ "$#" -ge 2 ] || usage; published=$2; shift 2 ;;
        --plugin) [ "$#" -ge 2 ] || usage; plugins="$plugins $2"; shift 2 ;;
        --mu-plugins) [ "$#" -ge 2 ] || usage; mu=$2; shift 2 ;;
        --old-path) [ "$#" -ge 2 ] || usage; old_paths="$old_paths ${2%/}"; shift 2 ;;
        --old-url) [ "$#" -ge 2 ] || usage; old_url=${2%/}; shift 2 ;;
        -h | --help) usage ;;
        *) echo "неизвестный аргумент: $1" >&2; usage ;;
    esac
done
# Без эталона приёмка превращается в «что-то есть», поэтому оба обязательны.
[ -n "$users" ] && [ -n "$published" ] || { echo 'нужны --user и --published: без эталона сверять не с чем' >&2; exit 2; }
case $published in *[!0-9]*) usage ;; esac
case $mu in *[!0-9]*) usage ;; esac

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
cd "$stack"

fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

for c in "$web" "$app" "$db_container"; do
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || { echo "$c не запущен" >&2; exit 2; }
done
docker image inspect "$wpcli_image" >/dev/null 2>&1 || { echo "нет образа $wpcli_image: сначала restore.sh" >&2; exit 2; }

prefix=$(in_volume_ro "cat $docroot/wp-config.php" 2>/dev/null | sed -n "s/^\$table_prefix = '\(.*\)';\$/\1/p")
[ -n "$prefix" ] || { echo 'в докруте нет сгенерированного wp-config.php: сначала restore.sh' >&2; exit 2; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo '--- данные'
wp user list --fields=user_login,roles --format=csv >"$work/users.csv" 2>"$work/wp.err" \
    || { fail "список пользователей не получен: $(head -n 3 "$work/wp.err")"; : >"$work/users.csv"; }
sed '1d; s/"//g' "$work/users.csv" | sort >"$work/users"
cut -d, -f1 "$work/users" | sort >"$work/logins"
for u in $users; do printf '%s\n' "${u%%:*}"; done | sort >"$work/want"
if cmp -s "$work/logins" "$work/want"; then
    pass "пользователи: $(tr '\n' ' ' <"$work/logins")"
else
    fail "пользователи не совпали: лишние [$(comm -23 "$work/logins" "$work/want" | tr '\n' ' ')], нет [$(comm -13 "$work/logins" "$work/want" | tr '\n' ' ')]"
fi
for u in $users; do
    case $u in *:*) ;; *) continue ;; esac
    roles=$(grep "^${u%%:*}," "$work/users" | cut -d, -f2-)
    case ",$roles," in
        *",${u#*:},"*) pass "${u%%:*}: роль ${u#*:}" ;;
        *) fail "${u%%:*}: роли [$roles], ожидалась ${u#*:}" ;;
    esac
done

count=$(sql "$db_name" -e "SELECT COUNT(*) FROM \`${prefix}posts\` WHERE post_status = 'publish' AND post_type IN ('page', 'post')")
[ "$count" = "$published" ] && pass "опубликовано страниц и записей: $count" \
    || fail "опубликовано $count, эталон $published"

for p in $plugins; do
    if in_volume_ro "test -d $docroot/wp-content/plugins/$p" 2>/dev/null; then
        wp plugin is-active "$p" >/dev/null 2>&1 && pass "плагин $p на диске и включён" || fail "плагин $p на диске, но не включён"
    else
        fail "плагина $p нет на диске"
    fi
done
if [ -n "$mu" ]; then
    n=$(in_volume_ro "find $docroot/wp-content/mu-plugins -maxdepth 1 -type f -name '*.php' 2>/dev/null | wc -l" | tr -d ' ')
    [ "$n" = "$mu" ] && pass "mu-plugins: $n" || fail "mu-plugins: $n, эталон $mu"
fi

tables=$(sql -e "SELECT GROUP_CONCAT(CONCAT('\`', TABLE_NAME, '\`') SEPARATOR ', ') FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$db_name'")
if [ -z "$tables" ] || [ "$tables" = NULL ]; then
    fail "в схеме $db_name нет таблиц"
else
    sql "$db_name" -e "CHECK TABLE $tables" >"$work/check"
    bad=$(awk -F '\t' '$3 == "status" && $4 != "OK" || $3 == "error"' "$work/check")
    n=$(awk -F '\t' '$3 == "status"' "$work/check" | wc -l | tr -d ' ')
    [ -z "$bad" ] && [ "$n" -gt 0 ] && pass "целостность: $n таблиц прошли проверку" || fail "проверка таблиц: $bad"
fi

echo '--- докрут'
modes=$(in_volume_ro "cd $docroot && stat -c '%n %a %u:%g' . index.php wp-config.php wp-content wp-content/uploads")
expected_modes='. 755 82:82
index.php 644 82:82
wp-config.php 640 82:82
wp-content 755 82:82
wp-content/uploads 755 82:82'
[ "$modes" = "$expected_modes" ] && pass 'режимы ключевых путей: 755, 644, конфиг 640, владелец 82:82' \
    || fail "режимы ключевых путей: $(printf '%s' "$modes" | tr '\n' ';')"
other=$(in_volume_ro "find $docroot -xdev \\( ! -user 82 -o ! -group 82 \\) -print | head -n 5")
[ -z "$other" ] && pass 'весь докрут принадлежит пользователю приложения' || fail "чужой владелец: $other"
ww=$(in_volume_ro "find $docroot -xdev -perm -0002 ! -type l -print | head -n 5")
[ -z "$ww" ] && pass 'путей, открытых на запись всем, нет' || fail "открыто на запись всем: $ww"

in_volume_ro "tar -C $docroot/wp-content/uploads -cf - ." | python3 "$helper" upload-code - >"$work/upload-bad" \
    || fail 'каталог загрузок не прочитан'
if [ -s "$work/upload-bad" ]; then fail "код в загрузках: $(sed 's|^|wp-content/uploads/|' "$work/upload-bad" | tr '\n' ' ')"
else pass 'в загрузках кода нет, только заглушки'; fi

left=$(in_volume_ro "$remnants_find")
[ -z "$left" ] && pass 'установщика и его остатков в докруте нет' || fail "остатки установщика: $(printf '%s' "$left" | tr '\n' ' ')"
in_volume_ro "test -f $docroot/$marker_name" && pass 'метка разворачивания на месте' || fail 'метки разворачивания нет: прогон restore.sh не завершён'

echo '--- пути глазами приложения'
# Без объявления строгих типов: инструмент срезает открывающий тег, и
# объявление уходит в вычисление посреди файла, где оно запрещено.
wp eval '$u = wp_upload_dir(null, false);
foreach (["ABSPATH" => ABSPATH, "WP_CONTENT_DIR" => WP_CONTENT_DIR, "WP_PLUGIN_DIR" => WP_PLUGIN_DIR,
    "UPLOADS" => $u["basedir"], "UPLOADS_URL" => $u["baseurl"], "HOME" => get_option("home"),
    "SITEURL" => get_option("siteurl")] as $k => $v) { echo $k, "=", $v, "\n"; }' >"$work/paths" 2>"$work/wp.err"
expected_paths="ABSPATH=$docroot/
WP_CONTENT_DIR=$docroot/wp-content
WP_PLUGIN_DIR=$docroot/wp-content/plugins
UPLOADS=$docroot/wp-content/uploads
UPLOADS_URL=$url/wp-content/uploads
HOME=$url
SITEURL=$url"
if [ "$(cat "$work/paths")" = "$expected_paths" ]; then
    pass "эффективные пути и адрес: $docroot, $url"
else
    fail "эффективные пути: $(tr '\n' ' ' <"$work/paths") $(head -n 2 "$work/wp.err")"
fi

docker exec -u mysql "$db_container" mariadb-dump --single-transaction --skip-extended-insert "$db_name" >"$work/db.sql" 2>/dev/null \
    || fail 'дамп для поиска следов не снят'
python3 "$helper" old-paths "$work/db.sql" >"$work/left" || fail 'поиск путей в дампе не отработал'
in_volume_ro "cat $docroot/wp-config.php" >"$work/config"
traces=$(cut -f1 "$work/left" | tr '\n' ' ')
for old in $old_paths $old_url; do
    for form in "$old" "$(printf '%s' "$old" | sed 's|/|\\\\/|g')"; do
        grep -qF -- "$form" "$work/db.sql" "$work/config" && traces="$traces $old"
    done
done
[ -z "$(printf '%s' "$traces" | tr -d ' ')" ] && pass 'следов старой площадки в базе и конфиге нет' \
    || fail "следы старой площадки: $traces"

echo '--- запреты и ответ'
if "$stack/scripts/verify-tracer.sh" --uploads wp-content/uploads --deny /xmlrpc.php --deny /wp-config.php >"$work/tracer" 2>&1; then
    pass 'трассер: запреты ядра и WordPress подтверждены пробниками'
else
    fail 'трассер нашёл дыру'
    sed 's/^/      | /' "$work/tracer" >&2
fi
# Мимо любого кэша: уникальный параметр. Живой кэш держит 200 поверх мёртвого
# приложения, поэтому мерить надо то, что собрал PHP сейчас.
nocache="/?verify-nocache=$(date +%s)$$"
docker exec "$app" curl -sS -o /tmp/verify-home -w '%{http_code}' --max-time 60 -H "Host: $host" "http://$web$nocache" >"$work/code" 2>/dev/null
code=$(cat "$work/code")
if [ "$code" = 200 ] && ! docker exec "$app" grep -Eqi 'critical error|fatal error|error establishing a database connection' /tmp/verify-home; then
    pass "главная мимо кэша: 200 без ошибки приложения"
else
    fail "главная мимо кэша: ${code:-нет ответа}"
fi
docker exec "$app" rm -f /tmp/verify-home

echo
if [ "$fails" -eq 0 ]; then
    echo 'приёмка изнутри: всё сошлось'
    exit 0
fi
echo "приёмка изнутри: находок $fails" >&2
exit 1
