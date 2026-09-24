#!/bin/sh
# Внутренняя приёмка развёрнутого MODX: то, что снаружи принципиально не видно.
#
#   adapter/verify.sh --user admin:sudo --user editor --published 171 \
#       --page '/katalog/ Каталог' --page '/kontakty/ Телефон' \
#       [--rows ms2_products=108] [--old-path PATH]
#
#   --user LOGIN[:sudo]  ожидаемый пользователь менеджера, повторяемый. Набор
#                        логинов обязан совпасть точно: лишний админ это находка.
#                        :sudo требует полный доступ, его отсутствие тоже находка
#   --published N        опубликованных ресурсов
#   --page 'PATH TEXT'   эталон тела страницы: по адресу PATH отвечает 200 и в
#                        теле есть TEXT. Разделитель пробел: в адресе без
#                        дружественных ссылок есть знак равенства, а пробела
#                        в адресе нет. Повторяемый, хотя бы один обязателен
#   --rows TABLE=N       строк в таблице без префикса, повторяемый: каталог
#                        товаров, шаблоны, сниппеты, всё, что стоит сверить
#   --old-path PATH      корень старой площадки: его следов в настройках быть не должно
#
# Тела, а не только коды. После оборванного разворачивания каждый адрес
# отвечал 200 и рисовал главную, и по кодам это был исправный сайт. Поэтому
# каждая проверяемая страница сравнивается с главной, а эталонные страницы
# ещё и со своим текстом. Эталонные числа и тексты передаются аргументами:
# их печатает restore.sh и видит человек на старой площадке.
#
# Проверяет: пользователей, опубликованное, строки таблиц, целостность всех
# таблиц, владельца и режимы докрута, пароль вне конфига, отсутствие кода в
# assets/ вне компонентов, отсутствие установщика и остатков, эффективные
# пути и подключение конфига к базе, медиа-источники без двойного слэша,
# следы старой площадки в настройках, тела страниц против главной и
# эталонов, путь из сырого адреса запроса, редиректы со старой структуры в
# один прыжок, запреты трассером и исполнение PHP в компонентах.
#
# Код 0: всё сошлось. Код 1: есть находки, перечислены. Код 2: аргументы или
# стек не поднят.
set -u

usage() { sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0" >&2; exit 2; }

users='' published='' pages_ref='' rows='' old_paths=''
nl='
'
while [ "$#" -gt 0 ]; do
    case $1 in
        --user) [ "$#" -ge 2 ] || usage; users="$users $2"; shift 2 ;;
        --published) [ "$#" -ge 2 ] || usage; published=$2; shift 2 ;;
        --page) [ "$#" -ge 2 ] || usage; case $2 in "/"*" "?*) ;; *) usage ;; esac; pages_ref="$pages_ref$2$nl"; shift 2 ;;
        --rows) [ "$#" -ge 2 ] || usage; case $2 in *[!A-Za-z0-9_=]* | =* | *=) usage ;; esac; rows="$rows $2"; shift 2 ;;
        --old-path) [ "$#" -ge 2 ] || usage; old_paths="$old_paths ${2%/}"; shift 2 ;;
        -h | --help) usage ;;
        *) echo "неизвестный аргумент: $1" >&2; usage ;;
    esac
done
# Без эталона приёмка превращается в «что-то есть», поэтому все три обязательны.
[ -n "$users" ] && [ -n "$published" ] && [ -n "$pages_ref" ] \
    || { echo 'нужны --user, --published и --page: без эталона сверять не с чем' >&2; exit 2; }
case $published in *[!0-9]*) usage ;; esac

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
. "$adapter_dir/pages.sh"
cd "$stack"

fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

for c in "$web" "$app" "$db_container"; do
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || { echo "$c не запущен" >&2; exit 2; }
done
prefix=$(read_prefix)
[ -n "$prefix" ] || { echo 'в докруте нет конфига MODX: сначала restore.sh' >&2; exit 2; }
work=$(mktemp -d)
trap 'rm -rf "$work"; docker exec "$app" rm -rf /tmp/verify-modx >/dev/null 2>&1 || true' EXIT
q() { sql "$db_name" -e "$1"; }

echo '--- данные'
q "SELECT username, sudo FROM \`${prefix}users\` ORDER BY username" >"$work/users" || fail 'список пользователей не получен'
cut -f1 "$work/users" | sort >"$work/logins"
for u in $users; do printf '%s\n' "${u%%:*}"; done | sort >"$work/want"
if cmp -s "$work/logins" "$work/want"; then
    pass "пользователи: $(tr '\n' ' ' <"$work/logins")"
else
    fail "пользователи не совпали: лишние [$(comm -23 "$work/logins" "$work/want" | tr '\n' ' ')], нет [$(comm -13 "$work/logins" "$work/want" | tr '\n' ' ')]"
fi
for u in $users; do
    case $u in *:sudo) ;; *) continue ;; esac
    [ "$(awk -F '\t' -v l="${u%%:*}" '$1 == l {print $2}' "$work/users")" = 1 ] && pass "${u%%:*}: полный доступ" \
        || fail "${u%%:*}: полного доступа нет, а ожидался"
done

count=$(q "SELECT COUNT(*) FROM \`${prefix}site_content\` WHERE published = 1 AND deleted = 0")
[ "$count" = "$published" ] && pass "опубликовано ресурсов: $count" || fail "опубликовано $count, эталон $published"
for r in $rows; do
    n=$(q "SELECT COUNT(*) FROM \`${prefix}${r%%=*}\`" 2>/dev/null)
    [ "$n" = "${r#*=}" ] && pass "${prefix}${r%%=*}: $n строк" || fail "${prefix}${r%%=*}: ${n:-нет таблицы}, эталон ${r#*=}"
done

tables=$(sql -e "SELECT GROUP_CONCAT(CONCAT('\`', TABLE_NAME, '\`') SEPARATOR ', ') FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$db_name'")
if [ -z "$tables" ] || [ "$tables" = NULL ]; then
    fail "в схеме $db_name нет таблиц"
else
    q "CHECK TABLE $tables" >"$work/check"
    bad=$(awk -F '\t' '$3 == "status" && $4 != "OK" || $3 == "error"' "$work/check")
    n=$(awk -F '\t' '$3 == "status"' "$work/check" | wc -l | tr -d ' ')
    [ -z "$bad" ] && [ "$n" -gt 0 ] && pass "целостность: $n таблиц прошли проверку" || fail "проверка таблиц: $bad"
fi

echo '--- докрут'
modes=$(in_volume_ro "cd $docroot && stat -c '%n %a %u:%g' . index.php config.core.php core/config/config.inc.php core/config/db-password.inc.php assets")
expected_modes='. 755 82:82
index.php 644 82:82
config.core.php 644 82:82
core/config/config.inc.php 640 82:82
core/config/db-password.inc.php 640 82:82
assets 755 82:82'
[ "$modes" = "$expected_modes" ] && pass 'режимы ключевых путей: 755, 644, конфиг и пароль 640, владелец 82:82' \
    || fail "режимы ключевых путей: $(printf '%s' "$modes" | tr '\n' ';')"
other=$(in_volume_ro "find $docroot -xdev \\( ! -user 82 -o ! -group 82 \\) -print | head -n 5")
[ -z "$other" ] && pass 'весь докрут принадлежит пользователю приложения' || fail "чужой владелец: $other"
ww=$(in_volume_ro "find $docroot -xdev -perm -0002 ! -type l -print | head -n 5")
[ -z "$ww" ] && pass 'путей, открытых на запись всем, нет' || fail "открыто на запись всем: $ww"
in_volume_ro "grep -Eq \"^[[:space:]]*\\\$database_password[[:space:]]*=[[:space:]]*'\" $docroot/core/config/config.inc.php" \
    && fail 'пароль базы литералом в config.inc.php: бэкап его найдёт и упадёт' \
    || pass 'пароль базы в отдельном файле, конфиг без него'
code_in_assets=$(in_volume_ro "cd $docroot && find assets -path assets/components -prune -o -type f \\( -iname '*.php' -o -iname '*.php[0-9]' -o -iname '*.phtml' -o -iname '*.phar' \\) -print | head -n 5")
[ -z "$code_in_assets" ] && pass 'в assets/ вне компонентов кода нет' || fail "код в assets/ вне компонентов: $code_in_assets"
left=$(in_volume_ro "$remnants_find")
[ -z "$left" ] && pass 'установщика и остатков хостинга в докруте нет' || fail "остатки: $(printf '%s' "$left" | tr '\n' ' ')"
in_volume_ro "test -f $docroot/$marker_name" && pass 'метка разворачивания на месте' || fail 'метки разворачивания нет: прогон restore.sh не завершён'

echo '--- приложение'
modx_php paths >"$work/paths" 2>"$work/php.err"
expected_paths="MODX_CORE_PATH=$docroot/core/
MODX_PROCESSORS_PATH=$docroot/core/model/modx/processors/
MODX_CONNECTORS_PATH=$docroot/connectors/
MODX_MANAGER_PATH=$docroot/manager/
MODX_BASE_PATH=$docroot/
MODX_ASSETS_PATH=$docroot/assets/
DB=ok"
# MODX 3 держит процессоры в src/, и путь к ним у него свой; сверяется всё
# остальное, а процессоры только на то, что они в новом докруте.
got=$(sed "s|^MODX_PROCESSORS_PATH=$docroot/.*|MODX_PROCESSORS_PATH=$docroot/core/model/modx/processors/|" "$work/paths")
[ "$got" = "$expected_paths" ] && pass "эффективные пути в $docroot, конфиг подключается к базе" \
    || fail "пути и база: $(tr '\n' ' ' <"$work/paths") $(head -n 2 "$work/php.err")"
media=$(modx_php media 2>&1)
[ -z "$media" ] && pass 'медиа-источники без ведущего слэша в относительном адресе' || fail "медиа-источники соберут //адрес: $media"
for old in $old_paths; do
    n=$(q "SELECT (SELECT COUNT(*) FROM \`${prefix}system_settings\` WHERE value LIKE '%$old/%') + (SELECT COUNT(*) FROM \`${prefix}context_setting\` WHERE value LIKE '%$old/%') + (SELECT COUNT(*) FROM \`${prefix}media_sources\` WHERE properties LIKE '%$old/%')")
    [ "$n" = 0 ] && pass "следов $old в настройках и медиа-источниках нет" || fail "следов $old в настройках: $n"
    in_volume_ro "grep -rlF '$old/' $docroot/config.core.php $docroot/core/config $docroot/manager/config.core.php $docroot/connectors/config.core.php 2>/dev/null" >"$work/cfg"
    [ -s "$work/cfg" ] && fail "след $old в конфиге: $(tr '\n' ' ' <"$work/cfg")"
done

echo '--- страницы: тела, а не коды'
# Всё изнутри контейнера приложения к веб-серверу, с настоящим именем хоста:
# MODX выводит адрес сайта из него и кэширует, и запрос с чужим именем
# испортил бы кэш тем, что потом увидят посетители.
docker exec "$app" mkdir -p /tmp/verify-modx
fetch() { # fetch PATH NAME: код ответа, тело в /tmp/verify-modx/NAME
    docker exec "$app" curl -sS -o "/tmp/verify-modx/$2" -w '%{http_code}' --max-time 60 -H "Host: $host" "http://$web$1" 2>/dev/null
}
body_has() { docker exec "$app" grep -qF -- "$2" "/tmp/verify-modx/$1"; }
same() { docker exec "$app" cmp -s "/tmp/verify-modx/$1" "/tmp/verify-modx/$2"; }

code=$(fetch / home)
if [ "$code" = 200 ] && ! docker exec "$app" grep -Eqi 'fatal error|parse error|database error' /tmp/verify-modx/home; then
    pass 'главная: 200 без ошибки приложения'
else
    fail "главная: ${code:-нет ответа}"
fi

i=0
printf '%s' "$pages_ref" | while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    i=$((i + 1)); path=${ref%% *}; text=${ref#* }
    code=$(fetch "$path" "ref$i")
    if [ "$code" != 200 ]; then echo "FAIL  $path: $code, а не 200"
    elif [ "$path" != / ] && same "ref$i" home; then echo "FAIL  $path: 200, но тело совпадает с главной"
    elif ! body_has "ref$i" "$text"; then echo "FAIL  $path: 200, но в теле нет эталона «$text»"
    else echo "PASS  $path: 200, своё тело, эталон «$text» на месте"; fi
done >"$work/ref"
cat "$work/ref"
fails=$((fails + $(grep -c '^FAIL' "$work/ref")))

sample_pages "$prefix" 5 >"$work/sample"
[ -s "$work/sample" ] || fail 'опубликованных страниц для выборки нет'
n=0
while IFS="$(printf '\t')" read -r path id; do
    n=$((n + 1))
    code=$(fetch "$path" "p$n")
    if [ "$code" != 200 ]; then fail "$path (ресурс $id): $code"
    elif same "p$n" home; then fail "$path (ресурс $id): 200, но тело совпадает с главной: путь до MODX не доходит"
    else pass "$path (ресурс $id): 200, своё тело"; fi
done <"$work/sample"
# Только по телам, которые действительно получены: grep по отсутствующему
# файлу вернул бы «не найдено», и проверка была бы зелёной на пустом месте.
docker exec "$app" sh -c 'cd /tmp/verify-modx && ls home p[0-9]* ref[0-9]* 2>/dev/null' >"$work/bodies"
if [ ! -s "$work/bodies" ]; then
    fail 'ни одного тела страницы не получено, //assets/ проверить не на чем'
else
    docker exec -i "$app" sh -c "cd /tmp/verify-modx && grep -lE \"[\\\"'=(]//assets/\" \$(cat)" <"$work/bodies" >"$work/dbl"
    case $? in
        0) fail "адреса //assets/ в теле, браузер прочтёт assets как хост: $(tr '\n' ' ' <"$work/dbl")" ;;
        1) pass "адресов //assets/ в телах нет: $(wc -l <"$work/bodies" | tr -d ' ') страниц" ;;
        *) fail 'тела страниц не прочитаны' ;;
    esac
fi

# Путь из сырого адреса запроса. /A%26q%3DB из декодированного пути пришёл бы
# вторым q, и по адресу A ответила бы страница B.
if [ "$(wc -l <"$work/sample" | tr -d ' ')" -ge 2 ]; then
    a=$(sed -n 1p "$work/sample" | cut -f1); b=$(sed -n 2p "$work/sample" | cut -f1)
    case $a$b in
        /index.php*) pass 'дружественные адреса выключены: проба пути не нужна' ;;
        *)
            fetch "${a%/}%26q%3D${b#/}" smuggled >/dev/null
            same smuggled p2 && fail "${a%/}%26q%3D${b#/} отдал страницу $b: путь собран из декодированного адреса" \
                || pass 'закодированный q в пути не подменяет страницу: путь из сырого адреса'
            fetch "$a?q=${b#/}" override >/dev/null
            same override p2 && fail "$a?q=${b#/} отдал страницу $b: q из строки запроса перебивает путь" \
                || pass 'q из строки запроса не перебивает путь' ;;
    esac
fi

echo '--- редиректы со старой структуры'
redirects=$stack/nginx/adapter/modx-redirects.conf
if [ ! -f "$redirects" ]; then
    fail 'нет nginx/adapter/modx-redirects.conf: сначала restore.sh'
else
    # Точные правила целиком одним заходом в контейнер: каждое отвечает своим
    # кодом и адресом, а цель сама не редиректит, то есть прыжок один.
    sed -n 's|^location = "\([^"]*\)" { return \([0-9]*\) "\([^"]*\)"; }$|\1 \2 \3|p' "$redirects" \
        | sed "s|https://\$host|https://$host|; s|\\\$is_args\\\$args\$||; s|&\\\$args\$|\&|" >"$work/redirects"
    total=$(wc -l <"$work/redirects" | tr -d ' ')
    docker exec -i "$app" sh -c '
        while read -r from code to; do
            got=$(curl -sS -o /dev/null -w "%{http_code} %{redirect_url}" --max-time 10 -H "Host: $1" "http://$2$from")
            [ "$got" = "$code $to" ] || { echo "$from: ожидался $code $to, получен $got"; continue; }
            case $to in https://$1/*) ;; *) continue ;; esac
            next=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 -H "Host: $1" "http://$2${to#https://$1}")
            case $next in 30[1278]) echo "$from: цель $to сама редиректит ($next), прыжок не один" ;; esac
        done' sh "$host" "$web" <"$work/redirects" >"$work/redir-bad"
    if [ -s "$work/redir-bad" ]; then
        fail "редиректы: $(wc -l <"$work/redir-bad" | tr -d ' ') из $total"
        sed 's/^/      | /' "$work/redir-bad" >&2
    else
        pass "редиректы: $total точных, каждый в один прыжок"
    fi
fi

echo '--- запреты и компоненты'
# --allow это положительный контроль: в компонентах PHP обязан исполняться, его
# требуют формы, каталог и миниатюры. Запрет, накрывший assets/ целиком, ломает
# их молча, при зелёных запретах.
if "$stack/scripts/verify-tracer.sh" --uploads assets/images --allow assets/components \
    --deny /core/config/config.inc.php --deny /core/verify-tracer-probe.php --deny /setup/index.php \
    >"$work/tracer" 2>&1; then
    pass 'трассер: запреты ядра и MODX подтверждены, компоненты исполняются'
else
    fail 'трассер нашёл дыру или закрытые компоненты'
    sed 's/^/      | /' "$work/tracer" >&2
fi

echo
if [ "$fails" -eq 0 ]; then
    echo 'приёмка изнутри: всё сошлось'
    exit 0
fi
echo "приёмка изнутри: находок $fails" >&2
exit 1
