#!/bin/sh
# Стенд адаптера WordPress: настоящее ядро, настоящая база, архив в формате
# плагина бэкапа с установщиком внутри, и разворачивание по всем его обещаниям.
#
#   adapters/wordpress/stand.sh            из корня репозитория
#
# Нужны докер, общая сеть stand-edge и сеть наружу: ядро WordPress, его
# манифест и инструмент командной строки качаются с официальных адресов.
#
# Что доказывается:
#   - чужая сумма архива: отказ до любых изменений;
#   - два прогона подряд дают одно и то же, и третий с --force тоже:
#     файлы с суммами и содержимое таблиц совпадают;
#   - прогон, убитый после импорта, при повторе доводит дело до конца;
#   - установщик и его остатки в том не попали;
#   - пути старой площадки переписаны везде, включая сериализованные значения
#     и JSON, адрес тоже;
#   - внутренняя приёмка зелёная на чистом и красная на подсаженном;
#   - проверка безопасности зелёная по архиву и по тому, красная на коде в
#     загрузках;
#   - без запретов адаптера PHP в загрузках исполняется, с ними нет;
#   - бэкап и сторож ядра проходят со строками, которые дописал адаптер.
set -u
cd "$(dirname "$0")/../.."
root=$PWD
work=adapters/wordpress/.stand
fails=0
fail() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }
pass() { printf 'PASS  %s\n' "$1"; }
show() { sed 's/^/      | /' "$1" >&2; }

command -v docker >/dev/null 2>&1 || { echo 'docker не найден' >&2; exit 2; }
docker network inspect stand-edge >/dev/null 2>&1 || { echo 'нет сети stand-edge: docker network create stand-edge' >&2; exit 2; }

slug=wpstand
runner=$slug-runner
web=$slug-nginx
app=$slug-php-fpm
db=$slug-mariadb
vol=${slug}_site_data
fixture_vol=$slug-fixture
wp_version=6.8.2
old_root=/home/oldhost/public_html
old_url=http://staging.example.test

rm -rf "$work"; mkdir -p "$work"
# Стек виден подставному хосту по тому же абсолютному пути, что и докеру.
# Иначе compose изнутри разрешил бы относительные бинды ./nginx/... в путь,
# которого у демона нет, и пересоздал бы веб-сервер с пустыми каталогами.
stack_dir=$root/$work/stack
sed "s/^slug:.*/slug: $slug/; s|^stack_dir:.*|stack_dir: $stack_dir|; s/^edge_network:.*/edge_network: stand-edge/" \
    tests/fixtures/example-site.yaml >"$work/profile.yaml"
./bin/render --profile "$work/profile.yaml" --out "$work/stack" >/dev/null || exit 1
mkdir "$work/stack/adapter"
cp adapters/wordpress/*.sh adapters/wordpress/*.py adapters/wordpress/*.conf "$work/stack/adapter/"
rm -f "$work/stack/adapter/stand.sh" "$work/stack/adapter/test_adapter.py"

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
    -v "$stack_dir:$stack_dir" -v $slug-backups:/var/backups/$slug -w "$stack_dir" \
    shared-to-vps-stand-runner sleep infinity >/dev/null || { fail 'подставной хост не запустился'; exit 1; }
host() { docker exec -i "$runner" sh -c "$1"; }
sql() { docker exec -i -u mysql "$db" mariadb -N -B "$@"; }
i=0; until [ -n "$(docker ps -q --filter name=^$app\$ --filter health=healthy)" ]; do
    i=$((i + 1)); [ "$i" -lt 60 ] || { fail 'приложение не стало здоровым'; exit 1; }; sleep 2; done

# --- фикстура: сайт на старой площадке и его архив ------------------------------
echo '--- фикстура'
host 'cd adapter && . ./lib.sh && build_wpcli' || { fail 'инструмент командной строки не собрался'; exit 1; }
fx() { # fx СЕТЬ АРГУМЕНТЫ-WP: инструмент над томом фикстуры
    net=$1; shift
    docker run --rm --network "$net" --user 82:82 -e HOME=/tmp -v "$fixture_vol:/var/www/html" \
        --entrypoint wp $slug-wp-cli:local --path=/var/www/html "$@"
}
docker volume create "$fixture_vol" >/dev/null
docker run --rm -v "$fixture_vol:/var/www/html" --entrypoint chown $slug-php-fpm:local 82:82 /var/www/html
fx_pass=stand-fixture-$(date +%s)
sql <<SQL
CREATE DATABASE fixture_src;
CREATE USER 'fixture'@'%' IDENTIFIED BY '$fx_pass';
GRANT ALL ON fixture_src.* TO 'fixture'@'%';
SQL
{
    fx ${slug}_egress core download --version=$wp_version --locale=en_US \
        && fx ${slug}_internal config create --dbname=fixture_src --dbuser=fixture --dbpass="$fx_pass" --dbhost=mariadb \
            --dbprefix=wpx_ --skip-check \
        && fx ${slug}_internal config set WP_MEMORY_LIMIT 256M --type=constant
} >"$work/fx.log" 2>&1 || { fail 'ядро фикстуры не скачалось'; show "$work/fx.log"; exit 1; }
{
    fx ${slug}_internal core install --url=$old_url --title=Stand --admin_user=admin \
        --admin_password=stand-admin-pass --admin_email=admin@example.test --skip-email
    fx ${slug}_internal user create editor editor@example.test --role=editor --user_pass=stand-editor-pass
    fx ${slug}_internal rewrite structure '/%postname%/'
    fx ${slug}_internal post create --post_type=page --post_status=publish --post_title=About --post_name=about \
        --post_content="<img src=\"$old_url/wp-content/uploads/a.jpg\">"
    fx ${slug}_internal plugin activate akismet
    fx ${slug}_internal option update upload_path "$old_root/wp-content/uploads"
    fx ${slug}_internal option update stand_paths "{\"dir\":\"$old_root/wp-content/cache\",\"n\":1}" --format=json
    json_root=$(printf '%s' "$old_root" | sed 's|/|\\/|g')
    fx ${slug}_internal post meta add 1 stand_json "{\"p\":\"${json_root}\\/wp-content\\/x\"}"
    # Блокировку крона снять последней: без неё первая же загрузка WordPress
    # при разворачивании запустит просроченные задачи и запишет в базу время.
    # Так невоспроизводимость ловится каждым прогоном, а не при удачном тайминге.
    fx ${slug}_internal transient delete doing_cron
} >>"$work/fx.log" 2>&1 || { fail 'фикстура не наполнилась'; show "$work/fx.log"; exit 1; }
docker run --rm -v "$fixture_vol:/s" --entrypoint sh $slug-php-fpm:local -c '
    set -e; cd /s
    mkdir -p wp-content/mu-plugins wp-content/uploads/forms wp-content/backups-dup-pro dup-installer/dup_descriptors_x/db_dumps
    printf "<?php\n// mu-plugin стенда\n" >wp-content/mu-plugins/stand.php
    printf "<?php\n// Silence is golden.\n" >wp-content/uploads/forms/index.php
    printf "User-agent: *\nDisallow: /wp-admin/\n" >robots.txt
    printf "<?php // installer\n" >dup-installer/main.installer.php
    printf "<?php // installer backup\n" >20260101_stand_installer-backup.php
    printf "memory_limit=-1\n" >php.ini
    printf "; hosting\n" >.user.ini
    printf "PHP Warning: x\n" >error_log
    printf "old" >wp-content/backups-dup-pro/old_archive.zip
    chmod 700 wp-admin'
docker exec -u mysql "$db" mariadb-dump --skip-dump-date fixture_src \
    | docker run --rm -i -v "$fixture_vol:/s" --entrypoint sh $slug-php-fpm:local -c 'cat >/s/dup-installer/dup_descriptors_x/db_dumps/20260101-dump.sql'
host "rm -rf /tmp/fx && mkdir /tmp/fx && docker run --rm -v $fixture_vol:/s:ro --entrypoint tar $slug-php-fpm:local -C /s -cf - . | tar -xf - -C /tmp/fx
      cd /tmp/fx && python3 -c 'import os, zipfile
with zipfile.ZipFile(\"/tmp/stand_archive.zip\", \"w\", zipfile.ZIP_DEFLATED) as z:
    for d, _, fs in os.walk(\".\"):
        for f in fs: z.write(os.path.join(d, f), os.path.relpath(os.path.join(d, f), \".\"))'
      rm -rf /tmp/fx"
# Фикстура обязана нести старый путь во всех трёх видах: как есть, внутри
# сериализованной строки и в JSON. Иначе замена «прошла» бы на пустом месте.
docker run --rm -v "$fixture_vol:/s:ro" --entrypoint cat $slug-php-fpm:local \
    /s/dup-installer/dup_descriptors_x/db_dumps/20260101-dump.sql >"$work/fx.sql"
if grep -qF "'upload_path','$old_root/wp-content/uploads'" "$work/fx.sql" \
    && grep -qF 's:42:\"/home/oldhost/public_html/wp-content/cache\"' "$work/fx.sql" \
    && grep -qF '\\/home\\/oldhost\\/public_html\\/wp-content' "$work/fx.sql"; then
    pass 'фикстура несёт старый путь как есть, в сериализованной строке и в JSON'
else
    fail 'фикстура не несёт старый путь во всех трёх видах'; grep -F oldhost "$work/fx.sql" | cut -c1-300 >&2
fi
sql -e "DROP DATABASE fixture_src; DROP USER 'fixture'@'%'"
docker volume rm "$fixture_vol" >/dev/null
sum=$(host 'sha256sum /tmp/stand_archive.zip | cut -d" " -f1')
[ -n "$sum" ] && pass "архив фикстуры собран: ядро $wp_version, установщик, остатки, дамп внутри" || { fail 'архив фикстуры не собран'; exit 1; }

restore() { host "./adapter/restore.sh --archive /tmp/stand_archive.zip $*" >"$work/restore.out" 2>&1; }
# Снимок состояния: файлы тома с суммами и содержимое каждой таблицы.
snapshot() {
    docker run --rm -v "$vol:/s:ro" --entrypoint sh $slug-php-fpm:local -c 'cd /s && find . -type f -exec sha256sum {} + | sort -k2' >"$1"
    { printf 'TABLES '; sql -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$slug'"
      sql $slug -e "SELECT option_name, MD5(option_value) FROM wpx_options ORDER BY option_name"
      sql $slug -e "SELECT CONCAT('CHECKSUM TABLE ', GROUP_CONCAT(CONCAT('\`', TABLE_NAME, '\`') ORDER BY TABLE_NAME SEPARATOR ', ')) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$slug'" | sql $slug
    } >>"$1"
}
web_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
marker() { docker run --rm -v "$vol:/s:ro" --entrypoint cat $slug-php-fpm:local /s/.shared-to-vps-restore 2>/dev/null; }

# --- 1. чужая сумма ------------------------------------------------------------
echo '--- разворачивание'
before=$(docker run --rm -v "$vol:/s:ro" --entrypoint ls $slug-php-fpm:local /s | tr '\n' ' ')
restore --sha256 0000000000000000000000000000000000000000000000000000000000000000; code=$?
after=$(docker run --rm -v "$vol:/s:ro" --entrypoint ls $slug-php-fpm:local /s | tr '\n' ' ')
[ "$code" -eq 1 ] && grep -q 'не тот снимок' "$work/restore.out" && [ "$before" = "$after" ] && web_running "$web" \
    && pass 'чужая сумма архива: отказ, том не тронут, сайт отвечает' \
    || { fail "чужая сумма: код $code"; show "$work/restore.out"; }

# --- 2. адрес старой площадки не назван или назван с ошибкой -------------------
# Отказ обязан случиться до сноса тома: опечатка в аргументе не кладёт сайт.
restore --sha256 "$sum"; code=$?
after=$(docker run --rm -v "$vol:/s:ro" --entrypoint ls $slug-php-fpm:local /s | tr '\n' ' ')
[ "$code" -eq 1 ] && grep -q -- "--old-url $old_url" "$work/restore.out" && web_running "$web" && [ "$before" = "$after" ] \
    && pass 'адрес в базе не совпал с новым: отказ с подсказкой до сноса, сайт отвечает, том цел' \
    || { fail "без --old-url: код $code"; show "$work/restore.out"; }
restore --sha256 "$sum" --old-url http://www.staging.example.test; code=$?
after=$(docker run --rm -v "$vol:/s:ro" --entrypoint ls $slug-php-fpm:local /s | tr '\n' ' ')
[ "$code" -eq 1 ] && grep -q 'замена по нему ничего бы не нашла' "$work/restore.out" && web_running "$web" && [ "$before" = "$after" ] \
    && pass 'неверный --old-url: отказ до сноса, сайт отвечает' \
    || { fail "неверный --old-url: код $code"; show "$work/restore.out"; }

# --- 3. первый прогон ----------------------------------------------------------
restore --sha256 "$sum" --old-url $old_url; code=$?
if [ "$code" -eq 0 ]; then pass 'первый прогон развернул снимок'
else fail "первый прогон: код $code"; show "$work/restore.out"; fi
grep -q "^  $old_root\$" "$work/restore.out" && pass 'корень старой площадки найден в дампе сам' \
    || { fail 'корень старой площадки не найден'; show "$work/restore.out"; }
grep -q '^  WP_MEMORY_LIMIT$' "$work/restore.out" && pass 'непереносимая константа старого конфига названа' \
    || fail 'константа старого конфига не названа'
snapshot "$work/s1"
grep -q 'wp-config.php' "$work/s1" && pass 'снимок состояния снят' || fail 'снимок состояния пуст'

# --- 4. второй прогон той же командой ------------------------------------------
restore --sha256 "$sum" --old-url $old_url; code=$?
snapshot "$work/s2"
[ "$code" -eq 0 ] && grep -q 'уже развёрнуто' "$work/restore.out" && cmp -s "$work/s1" "$work/s2" \
    && pass 'второй прогон подряд: тот же результат, файлы с суммами и таблицы совпали' \
    || { fail "второй прогон: код $code"; show "$work/restore.out"; diff "$work/s1" "$work/s2" | head -n 20 >&2; }

# --- 5. полный повтор --force -------------------------------------------------
restore --sha256 "$sum" --old-url $old_url --force; code=$?
snapshot "$work/s3"
[ "$code" -eq 0 ] && cmp -s "$work/s1" "$work/s3" \
    && pass 'полное разворачивание заново даёт тот же результат, включая конфиг и таблицы' \
    || { fail "повтор с --force: код $code"; diff "$work/s1" "$work/s3" | head -n 20 >&2; }

# --- 6. обрыв после импорта ----------------------------------------------------
host "touch /tmp/hold; rm -f /tmp/hold.reached
      WP_RESTORE_HOLD_FILE=/tmp/hold ./adapter/restore.sh --archive /tmp/stand_archive.zip --sha256 $sum --old-url $old_url --force >/tmp/killed.out 2>&1 & pid=\$!
      i=0; while [ ! -e /tmp/hold.reached ] && [ \$i -lt 300 ]; do sleep 1; i=\$((i + 1)); done
      kill -9 \$pid; wait \$pid 2>/dev/null; rm -f /tmp/hold
      flock -w 30 $stack_dir/.restore.lock true"
if [ -z "$(marker)" ] && ! web_running "$web" && [ -n "$(ls -d "$work"/stack/.restore-stage.* 2>/dev/null)" ]; then
    pass 'обрыв после импорта: метки нет, сайт остановлен, половина не отвечает'
else
    fail 'обрыв не оставил ожидаемого состояния'; host 'cat /tmp/killed.out' | sed 's/^/      | /' >&2
fi
restore --sha256 "$sum" --old-url $old_url; code=$?
snapshot "$work/s4"
[ "$code" -eq 0 ] && ! grep -q 'уже развёрнуто' "$work/restore.out" && cmp -s "$work/s1" "$work/s4" && web_running "$web" \
    && pass 'повтор после обрыва довёл дело до конца: результат как у чистого прогона' \
    || { fail "повтор после обрыва: код $code"; show "$work/restore.out"; diff "$work/s1" "$work/s4" | head -n 20 >&2; }
[ -z "$(ls -d "$work"/stack/.restore-stage.* 2>/dev/null)" ] && pass 'промежуточный каталог оборванного прогона убран' \
    || fail 'промежуточный каталог с дампом остался в стеке'

# --- 7. что оказалось в томе и базе --------------------------------------------
echo '--- результат'
leftovers=$(grep -E ' \./(dup-installer|20260101_stand_installer-backup\.php|php\.ini|\.user\.ini|error_log|wp-content/backups-dup-pro)' "$work/s1")
[ -z "$leftovers" ] && pass 'установщик и остатки в том не попали' || fail "в томе: $leftovers"
docker exec "$app" stat -c '%a' /var/www/html/wp-admin | grep -qx 755 && pass 'режим 0700 из архива не перенесён' \
    || fail 'режим каталога из архива перенесён'
sql $slug -e "SELECT option_value FROM wpx_options WHERE option_name = 'stand_paths'" >"$work/opt"
sql $slug -e "SELECT meta_value FROM wpx_postmeta WHERE meta_key = 'stand_json'" >>"$work/opt"
grep -q 's:30:"/var/www/html/wp-content/cache"' "$work/opt" && grep -qF '{"p":"\\/var\\/www\\/html\\/wp-content\\/x"}' "$work/opt" \
    && pass 'сериализованное значение переписано с верной длиной строки, JSON со слэшами тоже' \
    || { fail 'сериализованное значение не переписано'; show "$work/opt"; }
grep -q '^marker=/wp-content/$' "$work/stack/smoke/smoke.conf" && [ "$(grep -c '^page=/' "$work/stack/smoke/smoke.conf")" -ge 2 ] \
    && ! grep -q '^page=$' "$work/stack/smoke/smoke.conf" \
    && pass 'смоук: маркер и две страницы разных типов заполнены адаптером' \
    || { fail 'смоук не заполнен'; show "$work/stack/smoke/smoke.conf"; }
[ -f "$work/stack/smoke/robots.txt.reference" ] && pass 'эталон robots.txt взят из снимка' || fail 'эталона robots.txt нет'
[ "$(grep -c '^exclude=wp-config.php$' "$work/stack/backup.conf")" -eq 1 ] && pass 'строки адаптера в конфигах не дублируются' \
    || fail 'строки адаптера задублированы'

# --- 8. внутренняя приёмка -----------------------------------------------------
echo '--- приёмка'
verify_args="--user admin:administrator --user editor:editor --published 3 --plugin akismet --mu-plugins 1 --old-path $old_root --old-url $old_url"
host "./adapter/verify.sh $verify_args" >"$work/verify.out" 2>&1; code=$?
[ "$code" -eq 0 ] && pass 'внутренняя приёмка зелёная на чистом развёртывании' \
    || { fail "внутренняя приёмка: код $code"; show "$work/verify.out"; }
host "./adapter/verify.sh ${verify_args% --old-path*} --published 4" >"$work/verify.out" 2>&1; code=$?
[ "$code" -eq 1 ] && grep -q 'опубликовано 3, эталон 4' "$work/verify.out" && pass 'чужое эталонное число роняет приёмку' \
    || { fail "чужое число: код $code"; show "$work/verify.out"; }
sql $slug -e "INSERT INTO wpx_users (user_login, user_pass, user_nicename, user_email, user_registered, display_name) VALUES ('intruder', 'x', 'intruder', 'i@example.test', NOW(), 'intruder')"
docker exec "$app" sh -c "printf '<?php // Silence is golden\nsystem(\$_GET[1]);' >/var/www/html/wp-content/uploads/forms/cache.php"
host "./adapter/verify.sh $verify_args" >"$work/verify.out" 2>&1; code=$?
[ "$code" -eq 1 ] && grep -q 'лишние \[intruder' "$work/verify.out" && grep -q 'код в загрузках: wp-content/uploads/forms/cache.php' "$work/verify.out" \
    && pass 'подсаженные пользователь и код в загрузках найдены' \
    || { fail "подсаженное: код $code"; show "$work/verify.out"; }

# --- 9. проверка безопасности по двум источникам -------------------------------
echo '--- безопасность'
host "docker exec -u mysql $db mariadb-dump --single-transaction $slug | python3 adapter/security-check.py --source volume $vol --dump - \
      --user admin:administrator --user editor:editor" >"$work/sec.out" 2>&1; code=$?
[ "$code" -eq 1 ] && grep -q 'forms/cache.php' "$work/sec.out" && grep -q 'intruder' "$work/sec.out" \
    && pass 'том: код в загрузках и лишний пользователь найдены' || { fail "том с подсаженным: код $code"; show "$work/sec.out"; }
docker exec "$app" rm -f /var/www/html/wp-content/uploads/forms/cache.php
sql $slug -e "DELETE FROM wpx_users WHERE user_login = 'intruder'"
host "docker exec -u mysql $db mariadb-dump --single-transaction $slug | python3 adapter/security-check.py --source volume $vol --dump - \
      --user admin:administrator --user editor:editor" >"$work/sec.out" 2>&1; code=$?
[ "$code" -eq 0 ] && pass 'том: ядро по манифесту, сигнатуры, загрузки, пользователи чисты' \
    || { fail "том: код $code"; show "$work/sec.out"; }
host "python3 adapter/security-check.py --source archive /tmp/stand_archive.zip --user admin:administrator --user editor:editor" >"$work/sec.out" 2>&1; code=$?
[ "$code" -eq 0 ] && grep -q 'устройство архива' "$work/sec.out" && pass 'архив до разворачивания чист, установщик назван' \
    || { fail "архив: код $code"; show "$work/sec.out"; }
host "./adapter/verify.sh $verify_args" >"$work/verify.out" 2>&1; code=$?
[ "$code" -eq 0 ] && pass 'после уборки приёмка снова зелёная' || { fail "после уборки: код $code"; show "$work/verify.out"; }

# --- 10. отрицательный контроль запретов адаптера ------------------------------
echo '--- запреты'
conf=$work/stack/nginx/adapter/wordpress.conf
mv "$conf" "$work/wordpress.conf.off"
docker exec "$web" nginx -s reload >/dev/null 2>&1; sleep 1
host "./scripts/verify-tracer.sh --uploads wp-content/uploads --deny /xmlrpc.php --deny /wp-config.php" >"$work/tracer.out" 2>&1; code=$?
[ "$code" -eq 1 ] && grep -q 'FAIL  /wp-content/uploads/verify-tracer-probe.php ИСПОЛНИЛСЯ' "$work/tracer.out" \
    && pass 'без запретов адаптера PHP в загрузках WordPress исполняется: запрет нужен' \
    || { fail "без запретов адаптера трассер: код $code"; show "$work/tracer.out"; }
mv "$work/wordpress.conf.off" "$conf"
docker exec "$web" nginx -s reload >/dev/null 2>&1; sleep 1
host "./scripts/verify-tracer.sh --uploads wp-content/uploads --deny /xmlrpc.php --deny /wp-config.php" >"$work/tracer.out" 2>&1 \
    && pass 'с запретами адаптера трассер зелёный' || { fail 'с запретами трассер красный'; show "$work/tracer.out"; }

# --- 11. эксплуатация ядра со строками адаптера --------------------------------
echo '--- бэкап и сторож'
host './scripts/backup.sh' >"$work/backup.out" 2>&1; code=$?
[ "$code" -eq 0 ] && pass 'бэкап ядра прошёл: конфиг с паролем исключён, соли в набор не попали' \
    || { fail "бэкап: код $code"; show "$work/backup.out"; }
# Ворота Ф6: набор восстановим, только если из него разворачивается сайт, а не
# только импортируется база. Тот же restore.sh, конфиг заново из .env стека.
set_dir=$(host "ls -d /var/backups/$slug/*/ | tail -n 1" | sed 's|/$||')
if host "tar -tzf $set_dir/site-files.tar.gz | grep -qx './wp-includes/version.php' && ! tar -tzf $set_dir/site-files.tar.gz | grep -qx './wp-config.php'"; then
    fsum=$(host "sha256sum $set_dir/site-files.tar.gz | cut -d' ' -f1"); dsum=$(host "sha256sum $set_dir/database.sql.gz | cut -d' ' -f1")
    host "./adapter/restore.sh --archive $set_dir/site-files.tar.gz --sha256 $fsum --dump $set_dir/database.sql.gz --dump-sha256 $dsum" \
        >"$work/restore.out" 2>&1; code=$?
    host "./adapter/verify.sh ${verify_args% --old-path*}" >"$work/verify.out" 2>&1; vcode=$?
    [ "$code" -eq 0 ] && [ "$vcode" -eq 0 ] && pass 'из собственного набора бэкапа сайт развёрнут тем же restore.sh, приёмка зелёная' \
        || { fail "разворачивание из бэкапа: restore $code, verify $vcode"; show "$work/restore.out"; show "$work/verify.out"; }
else
    fail "набор бэкапа не тот: $set_dir"
fi
sed -i.bak "s|^robots_url=.*|robots_url=http://$web/robots.txt|" "$work/stack/watchdog.conf" && rm -f "$work/stack/watchdog.conf.bak"
host 'python3 scripts/watchdog-baseline.py' >"$work/wd.out" 2>&1 && host 'python3 scripts/watchdog-check.py' >>"$work/wd.out" 2>&1 \
    && pass 'сторож по запросам адаптера снял эталон и зелёный' || { fail 'сторож'; show "$work/wd.out"; }
docker exec "$app" sh -c "printf '<?php' >/var/www/html/wp-content/uploads/x.php"
host 'python3 scripts/watchdog-check.py' >"$work/wd.out" 2>&1; code=$?
[ "$code" -eq 1 ] && grep -q 'wp-content/uploads/x.php' "$work/wd.out" && pass 'сторож видит подсаженное в загрузки WordPress' \
    || { fail "сторож не увидел: код $code"; show "$work/wd.out"; }

[ "$fails" -eq 0 ] || { echo "стенд WordPress: $fails находок" >&2; exit 1; }
echo 'стенд WordPress: разворачивание, приёмка, скан и запреты подтверждены'
