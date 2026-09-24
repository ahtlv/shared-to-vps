# Стенд Ф6: бэкап, внешняя копия, сторож. Подключается из run.sh точкой, когда
# стек уже поднят: разделяет с ним счётчик находок, pass/fail и имена
# контейнеров. Отдельным файлом только ради читаемости.
#
# Бэкап и сторож на сервере запускаются с хоста. Здесь хостом служит
# контейнер с сокетом докера: точку монтирования тома машина разработчика не
# видит, а сценарий должен пройти ровно тот путь, что и на сервере.

runner=example-stand-runner
stack_dir=/opt/stacks/example
backups=/var/backups/example
# Значение длиннее порога проверки и нигде больше не встречается: находка по
# нему однозначна. В выводе скриптов его быть не должно ни при каком исходе.
secret=stand-secret-4f9a2c71

docker build -q -t shared-to-vps-stand-runner - <tests/stand/runner.Dockerfile >/dev/null \
    || { fail 'образ подставного хоста не собрался'; return; }
docker run -d --name "$runner" --network stand-edge \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$PWD/$work/stack:$stack_dir" \
    -v example-stand-backups:$backups \
    -v example-stand-offsite:/offsite \
    -w "$stack_dir" shared-to-vps-stand-runner sleep infinity >/dev/null \
    || { fail 'подставной хост не запустился'; return; }

# host 'команда': выполнить на подставном хосте из каталога стека.
host() { docker exec -i "$runner" sh -c "$1"; }
sql() { docker exec -i -u mysql "$db" mariadb -N -B "$@"; }
sets() { host "cd $backups && for d in [0-9]*-example; do [ -f \"\$d/SHA256SUMS\" ] && echo \"\$d\"; done; true" | sort; }
no_secret() {
    if grep -qF "$secret" "$1"; then fail "$2: значение пароля попало в вывод"
    else pass "$2: значение пароля в выводе отсутствует"; fi
}

# --- подготовка площадки: база, файлы, реквизиты ---
if ! sql -e 'SELECT 1' >/dev/null 2>&1; then
    fail 'админ базы через сокет недоступен: init-скрипт ядра не отработал'
    return
fi
sql <<'SQL'
CREATE DATABASE example CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE example;
CREATE TABLE marker (id INT PRIMARY KEY) ENGINE=InnoDB;
INSERT INTO marker VALUES (1), (2), (3);
CREATE TABLE users (id INT PRIMARY KEY, login VARCHAR(32)) ENGINE=InnoDB;
INSERT INTO users VALUES (1, 'admin'), (2, 'editor');
CREATE TABLE objects (id INT PRIMARY KEY, status VARCHAR(16)) ENGINE=InnoDB;
INSERT INTO objects VALUES (1, 'published'), (2, 'published'), (3, 'draft');
CREATE TRIGGER objects_touch BEFORE UPDATE ON objects FOR EACH ROW SET NEW.status = NEW.status;
SQL
docker exec -i "$app" sh -c "cd /var/www/html && mkdir -p uploads cache \
    && printf 'photo' >uploads/photo.jpg \
    && printf 'User-agent: *\nDisallow: /cache/\n' >robots.txt \
    && printf '<?php \$password = \"$secret\";\n' >config.php"
# DB_USER не секрет, а его значение встречается в дампе: проверка паролей
# обязана его пропустить, иначе бэкап падал бы каждую ночь.
printf 'DB_PASSWORD=%s\nDB_USER=published\nSHORT_PASSWORD=abc\n' "$secret" >"$work/stack/.env"
chmod 600 "$work/stack/.env"
# Конфиг сайта с паролем исключает адаптер своей строкой. Без неё бэкап обязан
# упасть на проверке секретов, так что каждый зелёный прогон ниже заодно
# доказывает, что исключение сработало.
cat >>"$work/stack/backup.conf" <<'EOF'
keep=3
exclude=config.php
expect=index.php
expect=uploads/photo.jpg
EOF

# --- 0. Отпечаток базы видит правку, которую счётчики не видят ---
# Ворота Ф3: повтор разворачивания меняет содержимое строки, а не их число.
host './scripts/db-fingerprint.sh >/tmp/fp.before' >"$work/fp.out" 2>&1 \
    && [ "$(host 'wc -l </tmp/fp.before' | tr -d ' ')" -eq 3 ] \
    && pass 'отпечаток снят: строка на каждую таблицу' || { fail 'отпечаток не снят'; sed 's/^/      | /' "$work/fp.out" >&2; }
host './scripts/db-fingerprint.sh --compare /tmp/fp.before' >"$work/fp.out" 2>&1 \
    && pass 'повторный отпечаток той же базы совпал' || { fail 'отпечаток нестабилен между прогонами'; sed 's/^/      | /' "$work/fp.out" >&2; }
counts_before=$(sql -e 'SELECT COUNT(*) FROM example.users')
sql -e "UPDATE example.users SET login = 'root' WHERE id = 2"
host './scripts/db-fingerprint.sh --compare /tmp/fp.before' >"$work/fp.out" 2>&1; code=$?
if [ "$code" -eq 1 ] && grep -qx 'изменена: users' "$work/fp.out" \
    && [ "$(sql -e 'SELECT COUNT(*) FROM example.users')" = "$counts_before" ]; then
    pass 'правка внутри строки найдена при том же числе строк'
else
    fail "правка внутри строки не найдена: код $code"; sed 's/^/      | /' "$work/fp.out" >&2
fi
sql -e "UPDATE example.users SET login = 'editor' WHERE id = 2"
host './scripts/db-fingerprint.sh --compare /tmp/fp.before' >/dev/null 2>&1 \
    && pass 'после возврата отпечаток снова совпал' || fail 'после возврата отпечаток не совпал'
host './scripts/db-fingerprint.sh --db no_such_schema' >/dev/null 2>&1; code=$?
[ "$code" -eq 2 ] && pass 'пустая схема: отказ, а не пустой отпечаток' || fail "пустая схема: код $code, ждали 2"
host 'rm -f /tmp/fp.before'

# --- 1. Оборванный прогон не оставляет видимого набора ---
# Обрыв в худший момент: все проверки пройдены, набор собран, остался только
# переименовать. kill -9 не даёт отработать уборке.
host "touch /tmp/hold; rm -f /tmp/hold.reached
      BACKUP_HOLD_FILE=/tmp/hold ./scripts/backup.sh >/tmp/killed.out 2>&1 & pid=\$!
      i=0; while [ ! -e /tmp/hold.reached ] && [ \$i -lt 300 ]; do sleep 1; i=\$((i + 1)); done
      ls $backups/.staging-*/ >/tmp/staged.lst 2>/dev/null
      kill -9 \$pid; wait \$pid 2>/dev/null; rm -f /tmp/hold
      flock -w 30 $backups/.backup.lock true"
# Замок держит и осиротевший потомок убитого прогона, пока не выйдет сам:
# так и должно быть, поэтому стенд ждёт замок, а не время.
if [ "$(host 'sort /tmp/staged.lst | tr "\n" " "')" = 'RESTORE.md SHA256SUMS database.sql.gz site-files.tar.gz ' ]; then
    pass 'к моменту обрыва набор был собран и проверен целиком'
else
    fail 'бэкап не дошёл до публикации, обрыв ничего не доказывает'
    host 'cat /tmp/killed.out' | sed 's/^/      | /' >&2
fi
[ -z "$(sets)" ] && pass 'оборванный прогон: видимых наборов ноль' \
  || fail "оборванный прогон оставил набор: $(sets)"

# --- 2. Живой пароль в наборе роняет бэкап и не печатается ---
docker exec "$app" sh -c "mkdir -p /var/www/html/leak && printf 'note $secret\n' >/var/www/html/leak/notes.txt"
host './scripts/backup.sh' >"$work/leak-files.out" 2>&1; code=$?
[ "$code" -eq 1 ] && grep -q 'пароль' "$work/leak-files.out" \
    && pass 'пароль в файлах сайта роняет бэкап' \
    || { fail "пароль в файлах сайта: код $code"; sed 's/^/      | /' "$work/leak-files.out" >&2; }
no_secret "$work/leak-files.out" 'утечка в файлах'
docker exec "$app" rm -rf /var/www/html/leak

sql example -e "CREATE TABLE leaky (v VARCHAR(64)); INSERT INTO leaky VALUES ('$secret');"
host './scripts/backup.sh' >"$work/leak-db.out" 2>&1; code=$?
[ "$code" -eq 1 ] && grep -q 'пароль' "$work/leak-db.out" \
    && pass 'пароль в дампе роняет бэкап' \
    || { fail "пароль в дампе: код $code"; sed 's/^/      | /' "$work/leak-db.out" >&2; }
no_secret "$work/leak-db.out" 'утечка в дампе'
sql example -e 'DROP TABLE leaky'
[ -z "$(sets)" ] && pass 'после отказов видимых наборов ноль' || fail "отказ оставил набор: $(sets)"

# --- 3. Успешный прогон, ротация по числу завершённых наборов ---
# Самый старый по имени набор трогается последним, чтобы его mtime стал
# самым свежим: ротация по времени изменения оставила бы именно его.
host "cd $backups
      for d in 2020-01-01 2020-01-02 2020-01-03 2020-01-04; do mkdir \$d-example; touch \$d-example/SHA256SUMS; done
      mkdir 2019-12-31-example
      sleep 1; touch 2020-01-01-example 2020-01-01-example/SHA256SUMS
      touch -d '2 days ago' .staging-*"
sql -e 'CREATE DATABASE backup_check_stale'
host './scripts/backup.sh' >"$work/backup.out" 2>&1; code=$?
if [ "$code" -eq 0 ]; then pass 'бэкап прошёл'
else fail "бэкап упал с кодом $code"; sed 's/^/      | /' "$work/backup.out" >&2; fi
today=$(host 'date -u +%F')-example
expected=$(printf '2020-01-03-example\n2020-01-04-example\n%s\n' "$today" | sort)
[ "$(sets)" = "$expected" ] && pass 'ротация оставила три самых новых по имени, а не по mtime' \
  || fail "после ротации: $(sets | tr '\n' ' ')"
host "[ -d $backups/2019-12-31-example ]" && pass 'каталог без контрольных сумм ротация не считает и не трогает' \
  || fail 'ротация удалила каталог, который не является набором'
[ -z "$(host "ls -d $backups/.staging-* 2>/dev/null")" ] && pass 'брошенный промежуточный каталог старше суток убран' \
  || fail 'брошенный промежуточный каталог остался'
[ -z "$(sql -e "SHOW DATABASES LIKE 'backup\\_check\\_%'")" ] && pass 'временных схем проверки не осталось, включая брошенную' \
  || fail "остались временные схемы: $(sql -e "SHOW DATABASES LIKE 'backup\\_check\\_%'" | tr '\n' ' ')"
no_secret "$work/backup.out" 'успешный прогон'
host './scripts/backup.sh' >"$work/backup-again.out" 2>&1; code=$?
[ "$code" -eq 0 ] && grep -q 'уже есть' "$work/backup-again.out" && [ "$(sets | wc -l | tr -d ' ')" -eq 3 ] \
    && pass 'повторный прогон за день зелёный и набор не плодит' \
    || { fail "повторный прогон за день: код $code"; sed 's/^/      | /' "$work/backup-again.out" >&2; }

# --- 4. Набор проверяется независимо от скрипта, который его собрал ---
set_dir=$backups/$today
[ "$(host "ls $set_dir | sort | tr '\n' ' '")" = 'RESTORE.md SHA256SUMS database.sql.gz site-files.tar.gz ' ] \
    && pass 'в наборе ровно архив, дамп, контрольные суммы и инструкция' \
    || fail "состав набора: $(host "ls $set_dir" | tr '\n' ' ')"
host "cd $set_dir && sha256sum -c SHA256SUMS" >/dev/null 2>&1 && pass 'контрольные суммы сходятся' \
  || fail 'контрольные суммы не сходятся'
host "rm -rf /tmp/unpack && mkdir /tmp/unpack && tar -xzf $set_dir/site-files.tar.gz -C /tmp/unpack \
      && [ -f /tmp/unpack/index.php ] && [ -f /tmp/unpack/uploads/photo.jpg ] && [ -f /tmp/unpack/robots.txt ]" \
    && pass 'архив распаковывается в отдельный каталог с файлами сайта' || fail 'архив не распаковывается или неполон'
host '[ ! -e /tmp/unpack/config.php ] && [ ! -e /tmp/unpack/.env ]' && pass 'реквизиты из архива исключены' \
  || fail 'в архиве реквизиты'
sql -e 'CREATE DATABASE stand_restore'
host "gzip -dc $set_dir/database.sql.gz" | sql stand_restore
[ "$(sql stand_restore -e 'SELECT COUNT(*) FROM marker')" = 3 ] && pass 'дамп импортируется в отдельную схему, таблица-маркер цела' \
  || fail 'дамп не импортировался'
sql -e 'DROP DATABASE stand_restore'
host "gzip -dc $set_dir/database.sql.gz | grep -q 'DEFINER='" && fail 'в дампе остался DEFINER: панель его не импортирует' \
  || pass 'в дампе нет DEFINER, триггер импортируется без привилегий'
host "grep -q 'доступа к этому серверу больше нет' $set_dir/RESTORE.md" && pass 'инструкция покрывает потерю доступа к серверу' \
  || fail 'в инструкции нет случая «доступа к серверу нет»'

# --- 5. Внешняя копия: шифр публичным ключом, обратное чтение первой ---
host "age-keygen -o /tmp/stand-id 2>/dev/null && sed -i \"s|^recipient=.*|recipient=\$(age-keygen -y /tmp/stand-id)|; s|^remote=.*|remote=/offsite/example|\" offsite.conf"
host "sed 's|^recipient=.*|recipient='\"\$(grep AGE-SECRET-KEY /tmp/stand-id)\"'|' offsite.conf >/tmp/bad.conf
      OFFSITE_CONF=/tmp/bad.conf ./scripts/backup-offsite.sh" >"$work/offsite-bad.out" 2>&1; code=$?
if [ "$code" -eq 2 ] && ! grep -q 'AGE-SECRET-KEY' "$work/offsite-bad.out" && [ -z "$(host 'ls /offsite 2>/dev/null')" ]; then
    pass 'закрытый ключ в конфиге отвергнут, ничего не отправлено, ключ не напечатан'
else
    fail "закрытый ключ в конфиге: код $code"; sed 's/^/      | /' "$work/offsite-bad.out" >&2
fi
host './scripts/backup-offsite.sh' >"$work/offsite.out" 2>&1; code=$?
if [ "$code" -eq 0 ] && grep -q 'обратное чтение: совпало' "$work/offsite.out"; then
    pass 'первая внешняя копия сверена обратным чтением'
else
    fail "первая внешняя копия: код $code"; sed 's/^/      | /' "$work/offsite.out" >&2
fi
remote_file=/offsite/example/$today.tar.age
host "tar -tf $remote_file" >/dev/null 2>&1 && fail 'внешняя копия читается как обычный tar' \
  || pass 'внешняя копия не читается без ключа'
host "! grep -aq 'CREATE TABLE' $remote_file && ! grep -aq 'SHA256SUMS' $remote_file" \
    && pass 'в шифротексте нет открытых имён и SQL' || fail 'в шифротексте видны открытые данные'
host "rm -rf /tmp/dec && mkdir /tmp/dec && age -d -i /tmp/stand-id $remote_file | tar -xf - -C /tmp/dec \
      && cd /tmp/dec/$today && sha256sum -c SHA256SUMS" >/dev/null 2>&1 \
    && pass 'закрытым ключом копия расшифровывается в целый набор' || fail 'копия не расшифровывается в целый набор'
host './scripts/backup-offsite.sh' >"$work/offsite2.out" 2>&1; code=$?
[ "$code" -eq 0 ] && grep -q 'обратное чтение: пропущено' "$work/offsite2.out" \
    && pass 'повторная копия без --verify обратное чтение пропускает' \
    || { fail "повторная копия: код $code"; sed 's/^/      | /' "$work/offsite2.out" >&2; }
host "sed -i 's|^remote=.*|remote=/offsite/moved|' offsite.conf && ./scripts/backup-offsite.sh" >"$work/offsite3.out" 2>&1; code=$?
[ "$code" -eq 0 ] && grep -q 'обратное чтение: совпало' "$work/offsite3.out" \
    && pass 'первая копия в новое хранилище снова сверена обратным чтением' \
    || { fail "смена хранилища: код $code"; sed 's/^/      | /' "$work/offsite3.out" >&2; }
# Отрицательный контроль: хранилище отдаёт не то, что приняло.
host "mkdir -p /tmp/fakebin && printf '#!/bin/sh\nif [ \"\$1\" = cat ]; then /usr/bin/rclone \"\$@\"; printf x; else exec /usr/bin/rclone \"\$@\"; fi\n' >/tmp/fakebin/rclone
      chmod +x /tmp/fakebin/rclone; PATH=/tmp/fakebin:\$PATH ./scripts/backup-offsite.sh --verify" >"$work/offsite-bad2.out" 2>&1; code=$?
[ "$code" -eq 1 ] && grep -q 'не совпадает' "$work/offsite-bad2.out" \
    && pass 'искажённое обратное чтение роняет внешнюю копию' \
    || { fail "искажённое обратное чтение: код $code"; sed 's/^/      | /' "$work/offsite-bad2.out" >&2; }
host 'rm -rf /tmp/stand-id /tmp/dec /tmp/fakebin /tmp/bad.conf'

# --- 6. Сторож: находит подсаженный файл, после удаления снова зелёный ---
sed -i.bak "s|^robots_url=.*|robots_url=http://$web/robots.txt|" "$work/stack/watchdog.conf" && rm -f "$work/stack/watchdog.conf.bak"
cat >>"$work/stack/watchdog.conf" <<'EOF'
users_sql=SELECT COUNT(*) FROM users
objects_sql=SELECT COUNT(*) FROM objects WHERE status = 'published'
exclude=cache/
EOF
watch() { host "python3 scripts/watchdog-check.py" >"$work/watch.out" 2>&1; }
expect_watch() {
    watch; code=$?
    if [ "$code" -eq "$1" ] && { [ -z "${3:-}" ] || grep -qF "$3" "$work/watch.out"; }; then pass "$2"
    else fail "$2 (код $code)"; sed 's/^/      | /' "$work/watch.out" >&2; fi
}
expect_watch 2 'сторож без эталона отказывает, а не молчит' 'эталон'
host 'python3 scripts/watchdog-baseline.py' >"$work/baseline.out" 2>&1 && pass 'эталон снят' \
  || { fail 'эталон не снялся'; sed 's/^/      | /' "$work/baseline.out" >&2; }
host 'python3 scripts/watchdog-baseline.py' >/dev/null 2>&1 && fail 'эталон перезаписан без --force' \
  || pass 'эталон без --force не перезаписывается'
expect_watch 0 'сторож по свежему эталону зелёный'
docker exec "$app" sh -c 'printf tmp >/var/www/html/cache/page.html; touch /var/www/html/uploads/photo.jpg'
expect_watch 0 'кэш и смена одного mtime находкой не считаются'
docker exec "$app" sh -c "printf '<?php system(\$_GET[1]);' >/var/www/html/uploads/shell.php"
expect_watch 1 'подсаженный в загрузки файл найден' 'uploads/shell.php'
docker exec "$app" rm -f /var/www/html/uploads/shell.php
expect_watch 0 'после удаления подсаженного файла сторож снова зелёный'
sql example -e "INSERT INTO users VALUES (3, 'intruder')"
expect_watch 1 'лишний пользователь найден' 'пользовател'
sql example -e 'DELETE FROM users WHERE id = 3'
sql example -e "UPDATE objects SET status = 'published' WHERE id = 3"
expect_watch 1 'новый опубликованный объект найден' 'опубликован'
sql example -e "UPDATE objects SET status = 'draft' WHERE id = 3"
docker exec "$app" sh -c 'printf "User-agent: *\nDisallow: /\n" >/var/www/html/robots.txt'
expect_watch 1 'подменённый robots.txt найден' 'robots.txt'
docker exec "$app" sh -c 'printf "User-agent: *\nDisallow: /cache/\n" >/var/www/html/robots.txt'
expect_watch 0 'всё возвращено, сторож зелёный'
cp "$work/stack/watchdog.conf" "$work/watchdog.conf.orig"
echo 'exclude=uploads/' >>"$work/stack/watchdog.conf"
expect_watch 2 'исключить каталог загрузок сторож не даёт' 'загруз'
cat "$work/watchdog.conf.orig" >"$work/stack/watchdog.conf"

# --- 7. Юниты ссылаются на то, что есть в стеке ---
units_ok=1
for unit in "$work"/stack/systemd/*.service; do
    exe=$(sed -n 's/^ExecStart=//p' "$unit" | tr ' ' '\n' | grep "^$stack_dir/" | head -1)
    [ -n "$exe" ] && [ -x "$work/stack/${exe#"$stack_dir"/}" ] || { units_ok=0; fail "$(basename "$unit"): ExecStart не указывает на исполняемый скрипт стека"; }
done
for timer in "$work"/stack/systemd/*.timer; do
    # В стеке юниты лежат без слага, при установке получают префикс.
    target=$(sed -n 's/^Unit=//p' "$timer")
    case $target in example-*) ;; *) false ;; esac && [ -f "$work/stack/systemd/${target#example-}" ] || { units_ok=0; fail "$(basename "$timer"): Unit=$target нет в стеке"; }
done
[ "$(ls "$work"/stack/systemd | wc -l | tr -d ' ')" -eq 6 ] || { units_ok=0; fail 'юнитов не шесть'; }
[ "$units_ok" -eq 1 ] && pass 'шесть юнитов, ExecStart и Unit= указывают на существующее'
