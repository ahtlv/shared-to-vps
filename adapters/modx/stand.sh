#!/bin/sh
# Стенд адаптера MODX: настоящее ядро MODX, настоящая база, архив в форме
# хостинга (докрут под префиксом, дамп рядом) и разворачивание по всем его
# обещаниям.
#
#   adapters/modx/stand.sh            из корня репозитория
#
# Нужны докер, общая сеть stand-edge и сеть наружу: ядро MODX качается с
# официального адреса и сверяется с зафиксированной суммой.
#
# Что доказывается:
#   - чужая сумма архива и неразрешимая цепочка редиректов: отказ до любых
#     изменений, сайт отвечает;
#   - два прогона подряд дают одно и то же, и третий с --force тоже, и
#     прогон, убитый после импорта, при повторе доводит дело до конца;
#   - установщик, остатки хостинга и кэш старой площадки в том не попали;
#   - конфиг приведён к реквизитам .env одним шагом: рассинхрон роняет
#     приёмку, смена пароля в .env и повтор разворачивания её чинят;
#   - медиа-источник с ведущим слэшем исправлен в сериализованных свойствах,
#     в теле страницы нет //assets/;
#   - редиректы: самопереход выброшен, цепочка в один прыжок, повтор ключа
#     не мешает веб-серверу стартовать, обычное правило на месте;
#   - приёмка сравнивает тела: без q каждая страница отвечает 200 и рисует
#     главную, и приёмка это ловит; путь из декодированного адреса подменяет
#     страницу, и приёмка это ловит;
#   - без запретов адаптера PHP в assets/ исполняется, с ними нет, а в
#     компонентах исполняется;
#   - бэкап ядра проходит, и из его набора сайт разворачивается тем же
#     restore.sh; сторож видит подсаженное в assets/.
set -u
cd "$(dirname "$0")/../.."
root=$PWD
work=adapters/modx/.stand
fails=0
fail() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }
pass() { printf 'PASS  %s\n' "$1"; }
show() { sed 's/^/      | /' "$1" >&2; }

command -v docker >/dev/null 2>&1 || { echo 'docker не найден' >&2; exit 2; }
docker network inspect stand-edge >/dev/null 2>&1 || { echo 'нет сети stand-edge: docker network create stand-edge' >&2; exit 2; }

slug=modxstand
runner=$slug-runner
web=$slug-nginx
app=$slug-php-fpm
db=$slug-mariadb
vol=${slug}_site_data
fixture_vol=$slug-fixture
image=$slug-php-fpm:local
modx_version=3.1.2
modx_sha256=9d1f6cb3bfb1dd1282d7087bb258ce7ef0e5e40da71070dc719d6fcdf917f2c8
old_root=/home/oldhost/public_html
site_host=example.test

rm -rf "$work"; mkdir -p "$work"
# Стек и фикстура видны подставному хосту по тому же абсолютному пути, что и
# докеру: иначе compose изнутри разрешил бы относительные бинды в путь,
# которого у демона нет.
abs_work=$root/$work
stack_dir=$abs_work/stack
sed "s/^slug:.*/slug: $slug/; s|^stack_dir:.*|stack_dir: $stack_dir|; s/^edge_network:.*/edge_network: stand-edge/" \
    tests/fixtures/example-site.yaml >"$work/profile.yaml"
./bin/render --profile "$work/profile.yaml" --out "$work/stack" >/dev/null || exit 1
grep -qx "host=$site_host" "$work/stack/smoke/smoke.conf" || { echo "профиль-фикстура не на $site_host" >&2; exit 1; }
mkdir "$work/stack/adapter"
cp adapters/modx/*.sh adapters/modx/*.py adapters/modx/*.php adapters/modx/nginx.conf "$work/stack/adapter/"
rm -f "$work/stack/adapter/stand.sh" "$work/stack/adapter/test_adapter.py" "$work/stack/adapter/stand-fixture.php"

cleanup() {
    docker rm -f "$runner" >/dev/null 2>&1 || true
    docker volume rm "$fixture_vol" $slug-backups >/dev/null 2>&1 || true
    (cd "$work/stack" && docker compose down -v >/dev/null 2>&1) || true
    rm -rf "$work"
}
trap cleanup EXIT

(cd "$work/stack" && docker compose up -d --build >/dev/null 2>&1) || { fail 'стек не поднялся'; exit 1; }
docker build -q -t shared-to-vps-stand-runner - <tests/stand/runner.Dockerfile >/dev/null || { fail 'образ хоста не собрался'; exit 1; }
docker run -d --name "$runner" --network stand-edge -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$abs_work:$abs_work" -v $slug-backups:/var/backups/$slug -w "$stack_dir" \
    shared-to-vps-stand-runner sleep infinity >/dev/null || { fail 'подставной хост не запустился'; exit 1; }
host() { docker exec -i "$runner" sh -c "$1"; }
sql() { docker exec -i -u mysql "$db" mariadb -N -B "$@"; }
i=0; until [ -n "$(docker ps -q --filter name=^$app\$ --filter health=healthy)" ]; do
    i=$((i + 1)); [ "$i" -lt 60 ] || { fail 'приложение не стало здоровым'; exit 1; }; sleep 2; done

# --- фикстура: сайт на старой площадке и его архив ------------------------------
echo '--- фикстура'
curl -fsSL -o "$work/modx.zip" "https://modx.s3.amazonaws.com/releases/$modx_version/modx-$modx_version-pl.zip" \
    || { fail 'ядро MODX не скачалось'; exit 1; }
python3 -c "import hashlib,sys; sys.exit(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest() != sys.argv[2])" \
    "$work/modx.zip" "$modx_sha256" || { fail 'сумма ядра MODX не совпала с зафиксированной'; exit 1; }
fx() { # fx СЕТЬ КОМАНДА: sh в контейнере приложения, докрут фикстуры по старому пути
    docker run --rm -i --network "$1" --user 82:82 -v "$fixture_vol:$old_root" -v "$abs_work:/fx" -w "$old_root" \
        --entrypoint sh "$image" -c "$2"
}
docker volume create "$fixture_vol" >/dev/null
fx_pass=stand-fixture-$(date +%s)
sql <<SQL
CREATE DATABASE fixture_src;
CREATE USER 'fixture'@'%' IDENTIFIED BY '$fx_pass';
GRANT ALL ON fixture_src.* TO 'fixture'@'%';
SQL
cat >"$work/setup.xml" <<EOF
<modx>
<database_type>mysql</database_type><database_server>mariadb</database_server><database>fixture_src</database>
<database_user>fixture</database_user><database_password>$fx_pass</database_password>
<database_connection_charset>utf8mb4</database_connection_charset><database_charset>utf8mb4</database_charset>
<database_collation>utf8mb4_unicode_ci</database_collation><table_prefix>mdx_</table_prefix><https_port>443</https_port>
<http_host>$site_host</http_host><inplace>0</inplace><unpacked>0</unpacked><language>en</language>
<cmsadmin>admin</cmsadmin><cmspassword>stand-admin-pass-1</cmspassword><cmsadminemail>admin@example.test</cmsadminemail>
<core_path>$old_root/core/</core_path><context_mgr_path>$old_root/manager/</context_mgr_path><context_mgr_url>/manager/</context_mgr_url>
<context_connectors_path>$old_root/connectors/</context_connectors_path><context_connectors_url>/connectors/</context_connectors_url>
<context_web_path>$old_root/</context_web_path><context_web_url>/</context_web_url><remove_setup_directory>0</remove_setup_directory>
</modx>
EOF
{
    # От root и с chown в том же контейнере: пустой том докер при каждом
    # монтировании заново отдаёт владельцу точки монтирования из образа, и
    # chown отдельным запуском не держится.
    docker run --rm --network none -v "$fixture_vol:$old_root" -v "$abs_work:/fx" --entrypoint sh "$image" -c "
        php -r '\$z = new ZipArchive; exit(\$z->open(\"/fx/modx.zip\") === true && \$z->extractTo(\"/tmp/x\") ? 0 : 1);' \
        && cp -R /tmp/x/modx-$modx_version-pl/. $old_root/ && chown -R 82:82 $old_root" \
        && fx ${slug}_internal 'php setup/index.php --installmode=new --config=/fx/setup.xml' \
        && fx ${slug}_internal "php -- $old_root" <adapters/modx/stand-fixture.php
} >"$work/fx.log" 2>&1 || { fail 'MODX фикстуры не встал'; tail -n 20 "$work/fx.log" >&2; exit 1; }
# .htaccess: то, что лежит в поставке MODX, и редиректы со старой структуры с
# бомбами из кейса: самопереход, цепочка, повтор ключа, обычное правило.
fx none "cp ht.access .htaccess && cat >>.htaccess <<'EOF'

RewriteCond %{HTTP_HOST} ^www\\.(.*)\$ [NC]
RewriteRule ^(.*)\$ https://%1/\$1 [R=301,L]
RewriteRule ^katalog/\$ https://$site_host/katalog/ [R=301,L]
RewriteRule ^old-a/\$ /old-b/ [R=301,L]
RewriteRule ^old-b/\$ /katalog/ [R=301,L]
RewriteRule ^sklad/\$ /katalog/ [R=301,L]
RewriteRule ^sklad/\$ /katalog/ [R=301,L]
RewriteRule ^team/\$ /kontakty.html [R=301,L]
EOF
    printf 'memory_limit=-1\n' >php.ini
    printf '; hosting\n' >.user.ini
    printf 'PHP Warning: x\n' >error_log
    printf 'PHP Warning: y\n' >assets/error_log
    printf 'User-agent: *\nDisallow: /manager/\n' >robots.txt
    chmod 700 manager"
docker exec -u mysql "$db" mariadb-dump --skip-dump-date fixture_src >"$work/fx.sql"
# Фикстура обязана нести то, что разворачивание чинит: иначе починка
# «прошла» бы на пустом месте.
if grep -qF 's:15:\"/assets/images/\"' "$work/fx.sql" && grep -qF "s:40:\\\"$old_root/assets/images/\\\"" "$work/fx.sql" \
    && grep -qF "'site_url','http://old.example.test/'" "$work/fx.sql" && grep -qF 'stolen-manager-session' "$work/fx.sql" \
    && fx none 'test -d setup && test -n "$(ls core/cache)" && grep -qF /home/oldhost core/config/config.inc.php'; then
    pass 'фикстура: старый путь в конфиге и сериализованных свойствах, //-источник, старый адрес, сессия, установщик, кэш'
else
    fail 'фикстура не несёт того, что должно чиниться'; grep -F -e media_sources -e site_url "$work/fx.sql" | cut -c1-300 >&2
fi
# Архив в форме хостинга: докрут под префиксом, дамп рядом с ним.
docker run --rm -v "$fixture_vol:/src:ro" -v "$abs_work:/fx" --entrypoint sh "$image" -c "set -e
    mkdir -p /tmp/a/data/www /tmp/a/data/db
    cp -R /src /tmp/a/data/www/$site_host
    cp /fx/fx.sql /tmp/a/data/db/site.sql
    tar -C /tmp/a -czf /fx/stand_archive.tar.gz data" || { fail 'архив фикстуры не собран'; exit 1; }
sql -e "DROP DATABASE fixture_src; DROP USER 'fixture'@'%'"
docker volume rm "$fixture_vol" >/dev/null
archive=$abs_work/stand_archive.tar.gz
sum=$(host "sha256sum $archive | cut -d' ' -f1")
[ -n "$sum" ] && pass "архив фикстуры собран: MODX $modx_version под data/www/, дамп в data/db/" || { fail 'архив не собран'; exit 1; }

restore() { host "./adapter/restore.sh --archive $archive $*" >"$work/restore.out" 2>&1; }
# Снимок состояния: файлы тома с суммами и содержимое каждой таблицы.
snapshot() {
    docker run --rm -v "$vol:/s:ro" --entrypoint sh "$image" -c 'cd /s && find . -type f -exec sha256sum {} + | sort -k2' >"$1"
    { printf 'TABLES '; sql -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$slug'"
      sql $slug -e "SELECT CONCAT('CHECKSUM TABLE ', GROUP_CONCAT(CONCAT('\`', TABLE_NAME, '\`') ORDER BY TABLE_NAME SEPARATOR ', ')) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$slug'" | sql $slug
    } >>"$1"
}
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
marker() { docker run --rm -v "$vol:/s:ro" --entrypoint cat "$image" /s/.shared-to-vps-restore 2>/dev/null; }
listing() { docker run --rm -v "$vol:/s:ro" --entrypoint ls "$image" -a /s | tr '\n' ' '; }
get() { # get PATH: код, адрес перехода и тело, как их видит обратный прокси
    docker exec "$app" curl -sS -o /tmp/stand-body -w '%{http_code} %{redirect_url}' --max-time 30 -H "Host: $site_host" "http://$web$1"
}

# --- 1. отказы до любых изменений -----------------------------------------------
echo '--- отказы'
before=$(listing)
restore --sha256 0000000000000000000000000000000000000000000000000000000000000000; code=$?
[ "$code" -eq 1 ] && grep -q 'не тот снимок' "$work/restore.out" && [ "$before" = "$(listing)" ] && running "$web" \
    && pass 'чужая сумма архива: отказ, том не тронут, сайт отвечает' \
    || { fail "чужая сумма: код $code"; show "$work/restore.out"; }
printf 'RewriteRule ^a/$ /b/ [R=301,L]\nRewriteRule ^b/$ /a/ [R=301,L]\n' >"$work/cycle.htaccess"
restore --sha256 "$sum" --htaccess "$abs_work/cycle.htaccess"; code=$?
[ "$code" -eq 1 ] && grep -q 'НЕРАЗРЕШИМАЯ ЦЕПОЧКА: /a/ -> /b/ -> /a/' "$work/restore.out" && [ "$before" = "$(listing)" ] && running "$web" \
    && pass 'неразрешимая цепочка редиректов: отказ до сноса, том цел, сайт отвечает' \
    || { fail "цепочка по кругу: код $code"; show "$work/restore.out"; }
# Правило, которое генератор переводит, но которое совпадает с location ядра:
# веб-сервер с ним не стартует, и узнать это надо до сноса тома.
printf 'RewriteRule ^healthz$ /katalog/ [R=301,L]\n' >"$work/clash.htaccess"
restore --sha256 "$sum" --htaccess "$abs_work/clash.htaccess"; code=$?
[ "$code" -eq 1 ] && grep -q 'duplicate location "/healthz"' "$work/restore.out" && grep -q 'том не тронут' "$work/restore.out" \
    && [ "$before" = "$(listing)" ] && running "$web" \
    && pass 'редирект, совпавший с location ядра: nginx -t до сноса, отказ, том цел, сайт отвечает' \
    || { fail "совпадение с location ядра: код $code"; show "$work/restore.out"; }

# --- 2. первый прогон и повторы ---------------------------------------------------
echo '--- разворачивание'
restore --sha256 "$sum"; code=$?
if [ "$code" -eq 0 ]; then pass 'первый прогон развернул снимок'
else fail "первый прогон: код $code"; show "$work/restore.out"; fi
grep -q "^корень старой площадки: $old_root\$" "$work/restore.out" && pass 'корень старой площадки прочитан из конфига снимка' \
    || fail 'корень старой площадки не назван'
grep -q 'перенесено: 4 (точных 4, .*выброшено самопереходов: 1; схлопнуто цепочек: 1; устранено повторов ключа: 1; условных на хост и схему: 1.*потеряно: 0' "$work/restore.out" \
    && pass 'генератор: самопереход выброшен, цепочка схлопнута, повтор устранён, условное на хост оставлено прокси' \
    || { fail 'сводка генератора не та'; grep -F 'перенесено' "$work/restore.out" >&2; }
snapshot "$work/s1"

restore --sha256 "$sum"; code=$?
snapshot "$work/s2"
[ "$code" -eq 0 ] && grep -q 'уже развёрнуто' "$work/restore.out" && cmp -s "$work/s1" "$work/s2" \
    && pass 'второй прогон подряд: тот же результат, файлы с суммами и таблицы совпали' \
    || { fail "второй прогон: код $code"; show "$work/restore.out"; diff "$work/s1" "$work/s2" | head -n 20 >&2; }

restore --sha256 "$sum" --force; code=$?
snapshot "$work/s3"
[ "$code" -eq 0 ] && cmp -s "$work/s1" "$work/s3" \
    && pass 'полное разворачивание заново даёт тот же результат, включая конфиг и таблицы' \
    || { fail "повтор с --force: код $code"; diff "$work/s1" "$work/s3" | head -n 20 >&2; }

host "touch /tmp/hold; rm -f /tmp/hold.reached
      MODX_RESTORE_HOLD_FILE=/tmp/hold ./adapter/restore.sh --archive $archive --sha256 $sum --force >/tmp/killed.out 2>&1 & pid=\$!
      i=0; while [ ! -e /tmp/hold.reached ] && [ \$i -lt 300 ]; do sleep 1; i=\$((i + 1)); done
      kill -9 \$pid; wait \$pid 2>/dev/null; rm -f /tmp/hold
      flock -w 30 $stack_dir/.restore.lock true"
if [ -z "$(marker)" ] && ! running "$web" && [ -n "$(ls -d "$work"/stack/.restore-stage.* 2>/dev/null)" ]; then
    pass 'обрыв после импорта: метки нет, сайт остановлен, половина не отвечает'
else
    fail 'обрыв не оставил ожидаемого состояния'; host 'cat /tmp/killed.out' | sed 's/^/      | /' >&2
fi
restore --sha256 "$sum"; code=$?
snapshot "$work/s4"
[ "$code" -eq 0 ] && ! grep -q 'уже развёрнуто' "$work/restore.out" && cmp -s "$work/s1" "$work/s4" && running "$web" \
    && pass 'повтор после обрыва довёл дело до конца: результат как у чистого прогона' \
    || { fail "повтор после обрыва: код $code"; show "$work/restore.out"; diff "$work/s1" "$work/s4" | head -n 20 >&2; }
[ -z "$(ls -d "$work"/stack/.restore-stage.* 2>/dev/null)" ] && pass 'промежуточный каталог оборванного прогона убран' \
    || fail 'промежуточный каталог с дампом остался в стеке'

# --- 3. что оказалось в томе и базе -------------------------------------------------
echo '--- результат'
leftovers=$(grep -E ' \./(setup/|php\.ini|\.user\.ini|error_log|assets/error_log|core/cache/.)' "$work/s1")
[ -z "$leftovers" ] && pass 'установщик, остатки хостинга и кэш старой площадки в том не попали' || fail "в томе: $(printf '%s' "$leftovers" | head -n 3)"
docker exec "$app" stat -c '%a' /var/www/html/manager | grep -qx 755 && pass 'режим 0700 из архива не перенесён' || fail 'режим каталога из архива перенесён'
docker exec "$app" cat /var/www/html/core/config/config.inc.php >"$work/config"
db_user=$(sed -n 's/^MODX_DB_USER=//p' "$work/stack/.env")
if grep -qF "\$database_server = 'mariadb';" "$work/config" && grep -qF "\$database_user = '$db_user';" "$work/config" \
    && grep -qF "\$database_password = require __DIR__ . '/db-password.inc.php';" "$work/config" \
    && grep -qF "\$modx_core_path= '/var/www/html/core/';" "$work/config" && ! grep -qF -e /home/oldhost -e fixture "$work/config" \
    && docker exec "$app" grep -qF "'/var/www/html/core/'" /var/www/html/config.core.php; then
    pass 'конфиг: реквизиты из .env стека, пароль отдельным файлом, пути нового докрута'
else
    fail 'конфиг не приведён'; grep -E 'database_|modx_core' "$work/config" >&2
fi
props=$(sql $slug -e "SELECT properties FROM mdx_media_sources WHERE name = 'Images'")
case $props in
    *'s:14:"assets/images/"'*'s:28:"/var/www/html/assets/images/"'* | *'s:28:"/var/www/html/assets/images/"'*'s:14:"assets/images/"'*)
        pass 'медиа-источник: ведущий слэш снят, путь переписан, длины сериализованных строк верны' ;;
    *) fail "медиа-источник: $props" ;;
esac
[ "$(sql $slug -e "SELECT value FROM mdx_system_settings WHERE \`key\` = 'site_url'")" = "https://$site_host/" ] \
    && pass 'адрес сайта в настройках переписан на новый' || fail 'site_url в настройках старый'
[ "$(sql $slug -e 'SELECT COUNT(*) FROM mdx_session')" = 0 ] && pass 'сессии старой площадки удалены' || fail 'сессии старой площадки остались'
grep -q '^marker=assets/$' "$work/stack/smoke/smoke.conf" && grep -qx 'page=/katalog/' "$work/stack/smoke/smoke.conf" \
    && grep -qx 'page=/kontakty.html' "$work/stack/smoke/smoke.conf" && ! grep -q '^page=$' "$work/stack/smoke/smoke.conf" \
    && pass 'смоук: маркер и две страницы на разных шаблонах заполнены адаптером' \
    || { fail 'смоук не заполнен'; show "$work/stack/smoke/smoke.conf"; }
[ -f "$work/stack/smoke/robots.txt.reference" ] && pass 'эталон robots.txt взят из снимка' || fail 'эталона robots.txt нет'
[ "$(grep -c '^exclude=core/config/db-password.inc.php$' "$work/stack/backup.conf")" -eq 1 ] \
    && pass 'строки адаптера в конфигах не дублируются' || fail 'строки адаптера задублированы'

# --- 4. редиректы вживую ----------------------------------------------------------------
echo '--- редиректы'
[ "$(get /sklad/)" = "301 https://$site_host/katalog/" ] && pass 'обычное правило: /sklad/ → 301 /katalog/' || fail "/sklad/: $(get /sklad/)"
[ "$(get /old-a/)" = "301 https://$site_host/katalog/" ] && pass 'цепочка /old-a/ → /old-b/ → /katalog/ отдаёт один прыжок' || fail "/old-a/: $(get /old-a/)"
[ "$(get '/team/?utm=1')" = "301 https://$site_host/kontakty.html?utm=1" ] && pass 'строка запроса переносится, как у Apache' || fail "/team/?utm=1: $(get '/team/?utm=1')"
[ "$(get /katalog/)" = '200 ' ] && pass 'самопереход /katalog/ выброшен: страница отвечает, а не редиректит по кругу' || fail "/katalog/: $(get /katalog/)"

# --- 5. внутренняя приёмка ----------------------------------------------------------------
echo '--- приёмка'
verify_args="--user admin:sudo --user editor --published 4 --page '/katalog/ stand-katalog-body' \
    --page '/kontakty.html stand-kontakty-body' --rows site_templates=2 --old-path $old_root"
vrun() { host "./adapter/verify.sh $verify_args $*" >"$work/verify.out" 2>&1; }
vrun; code=$?
[ "$code" -eq 0 ] && pass 'внутренняя приёмка зелёная на чистом развёртывании' || { fail "приёмка: код $code"; show "$work/verify.out"; }
get /katalog/ >/dev/null; docker exec "$app" grep -qF 'src="/assets/images/x.png"' /tmp/stand-body \
    && pass 'картинка через исправленный источник: /assets/images/x.png, а не //assets/' || fail 'адрес картинки не тот'
vrun --page "'/katalog/ no-such-text'"; code=$?
[ "$code" -eq 1 ] && grep -q 'в теле нет эталона «no-such-text»' "$work/verify.out" && pass 'чужой эталон текста роняет приёмку' \
    || { fail "чужой эталон: код $code"; show "$work/verify.out"; }

conf=$work/stack/nginx/adapter/modx.conf
reload() { docker exec "$web" nginx -s reload >/dev/null 2>&1; sleep 1; }
# Без q: так выглядел сайт после оборванного восстановления в кейсе.
grep -v '^set \$front_query' adapters/modx/nginx.conf >"$conf"; reload
[ "$(get /katalog/)" = '200 ' ] && vrun; code=$?
[ "$code" -eq 1 ] && grep -q '/katalog/: 200, но тело совпадает с главной' "$work/verify.out" \
    && pass 'без q каждая страница 200 и рисует главную: коды зелёные, приёмка по телам красная' \
    || { fail "без q: код $code"; show "$work/verify.out"; }
# Путь из декодированного адреса: закодированный q подменяет страницу.
sed 's/if (\$request_uri ~/if ($uri ~/' adapters/modx/nginx.conf >"$conf"; reload
vrun; code=$?
[ "$code" -eq 1 ] && grep -q '/katalog%26q%3Dkontakty.html отдал страницу /kontakty.html' "$work/verify.out" \
    && pass 'путь из декодированного адреса: /katalog%26q%3Dkontakty.html рисует чужую страницу, приёмка это ловит' \
    || { fail "декодированный путь: код $code"; show "$work/verify.out"; }
# q первым, как ставил прежний сервер: q из строки запроса перебивает путь.
sed 's/^set \$front_query .*/set $front_query "q=$modx_path\&$args";/' adapters/modx/nginx.conf >"$conf"; reload
vrun; code=$?
[ "$code" -eq 1 ] && grep -q '/katalog/?q=kontakty.html отдал страницу /kontakty.html' "$work/verify.out" \
    && pass 'q первым: /katalog/?q=kontakty.html рисует чужую страницу, приёмка это ловит' \
    || { fail "q первым: код $code"; show "$work/verify.out"; }
cat adapters/modx/nginx.conf >"$conf"; reload

# Медиа-источник обратно со слэшем: 200 и зелёные коды, а картинка сломана.
sql $slug -e "UPDATE mdx_media_sources SET properties = REPLACE(properties, 's:14:\"assets/images/\"', 's:15:\"/assets/images/\"') WHERE name = 'Images'"
docker exec "$app" sh -c 'rm -rf /var/www/html/core/cache/*'
vrun; code=$?
[ "$code" -eq 1 ] && grep -q 'адреса //assets/ в теле' "$work/verify.out" && grep -q 'медиа-источники соберут //адрес' "$work/verify.out" \
    && pass 'источник со слэшем: приёмка находит //assets/ и в теле, и в свойствах' \
    || { fail "источник со слэшем: код $code"; show "$work/verify.out"; }

# Рассинхрон пароля и конфига: так сайт ложился целиком на ровном месте.
docker exec "$app" sh -c "printf '<?php\nreturn \"wrong\";\n' >/var/www/html/core/config/db-password.inc.php"
vrun; code=$?
[ "$code" -eq 1 ] && grep -q 'конфиг сайта не подключается к базе' "$work/verify.out" \
    && pass 'пароль в конфиге разошёлся с базой: приёмка красная' || { fail "рассинхрон: код $code"; show "$work/verify.out"; }
# Смена пароля это правка .env и тот же прогон: конфиг и пользователь базы
# получают новый пароль вместе, отдельного шага нет.
sed -i.bak "s/^MODX_DB_PASSWORD=.*/MODX_DB_PASSWORD=rotated-$(date +%s)-password/" "$work/stack/.env" && rm -f "$work/stack/.env.bak"
restore --sha256 "$sum" --force; code=$?
vrun; vcode=$?
[ "$code" -eq 0 ] && [ "$vcode" -eq 0 ] && pass 'новый пароль в .env и повтор разворачивания: конфиг и база сошлись, источник починен, приёмка зелёная' \
    || { fail "смена пароля: restore $code, verify $vcode"; show "$work/restore.out"; show "$work/verify.out"; }

# --- 6. запреты -----------------------------------------------------------------------
echo '--- запреты'
tracer="./scripts/verify-tracer.sh --uploads assets/images --allow assets/components --deny /core/config/config.inc.php --deny /core/verify-tracer-probe.php --deny /setup/index.php"
mv "$conf" "$work/modx.conf.off"; reload
host "$tracer" >"$work/tracer.out" 2>&1; code=$?
[ "$code" -eq 1 ] && grep -q 'FAIL  /assets/images/verify-tracer-probe.php ИСПОЛНИЛСЯ' "$work/tracer.out" \
    && grep -q 'FAIL  /core/verify-tracer-probe.php ИСПОЛНИЛСЯ' "$work/tracer.out" \
    && pass 'без запретов адаптера PHP в assets/images и в core/ исполняется: запреты нужны' \
    || { fail "без запретов адаптера трассер: код $code"; show "$work/tracer.out"; }
mv "$work/modx.conf.off" "$conf"; reload
host "$tracer" >"$work/tracer.out" 2>&1 && pass 'с запретами адаптера трассер зелёный' || { fail 'с запретами трассер красный'; show "$work/tracer.out"; }

# --- 7. бэкап ядра и разворачивание из собственного набора ----------------------------
echo '--- бэкап и сторож'
host './scripts/backup.sh' >"$work/backup.out" 2>&1; code=$?
[ "$code" -eq 0 ] && pass 'бэкап ядра прошёл: файл пароля исключён, конфиг с ключами сайта в наборе' \
    || { fail "бэкап: код $code"; show "$work/backup.out"; }
set_dir=$(host "ls -d /var/backups/$slug/*/ | tail -n 1" | sed 's|/$||')
if host "tar -tzf $set_dir/site-files.tar.gz | grep -qx './core/config/config.inc.php' && ! tar -tzf $set_dir/site-files.tar.gz | grep -q db-password"; then
    fsum=$(host "sha256sum $set_dir/site-files.tar.gz | cut -d' ' -f1"); dsum=$(host "sha256sum $set_dir/database.sql.gz | cut -d' ' -f1")
    host "./adapter/restore.sh --archive $set_dir/site-files.tar.gz --sha256 $fsum --dump $set_dir/database.sql.gz --dump-sha256 $dsum" \
        >"$work/restore.out" 2>&1; code=$?
    vrun; vcode=$?
    [ "$code" -eq 0 ] && [ "$vcode" -eq 0 ] && pass 'из собственного набора бэкапа сайт развёрнут тем же restore.sh, приёмка зелёная' \
        || { fail "разворачивание из бэкапа: restore $code, verify $vcode"; show "$work/restore.out"; show "$work/verify.out"; }
else
    fail "набор бэкапа не тот: $set_dir"
fi

sed -i.bak "s|^robots_url=.*|robots_url=http://$web/robots.txt|" "$work/stack/watchdog.conf" && rm -f "$work/stack/watchdog.conf.bak"
host 'python3 scripts/watchdog-baseline.py' >"$work/wd.out" 2>&1 && host 'python3 scripts/watchdog-check.py' >>"$work/wd.out" 2>&1 \
    && pass 'сторож по запросам адаптера снял эталон и зелёный' || { fail 'сторож'; show "$work/wd.out"; }
docker exec "$app" sh -c "printf '<?php' >/var/www/html/assets/images/x.php"
host 'python3 scripts/watchdog-check.py' >"$work/wd.out" 2>&1; code=$?
[ "$code" -eq 1 ] && grep -q 'assets/images/x.php' "$work/wd.out" && pass 'сторож видит подсаженное в assets/images' \
    || { fail "сторож не увидел: код $code"; show "$work/wd.out"; }

[ "$fails" -eq 0 ] || { echo "стенд MODX: $fails находок" >&2; exit 1; }
echo 'стенд MODX: разворачивание, приёмка по телам, редиректы и запреты подтверждены'
