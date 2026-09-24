#!/bin/sh
# Трассер запретов: доказывает живыми пробниками, что запреты веб-сервера
# работают на поднятом стеке, а не только написаны в конфиге.
#
#   scripts/verify-tracer.sh                          из каталога отрендеренного стека
#   scripts/verify-tracer.sh --uploads wp-content/uploads --deny /xmlrpc.php
#
#   --uploads DIR   каталог загрузок относительно docroot (по умолчанию uploads)
#   --deny PATH     путь, закрытый адаптером CMS: точка входа для перебора
#                   паролей, свой конфиг с реквизитами. Повторяемый.
#   --allow DIR     каталог, где PHP обязан исполняться: точки входа
#                   расширений CMS, которые вызывает браузер посетителя.
#                   Повторяемый. Без этой проверки запрет, накрывший лишнее,
#                   зелёный, а формы и каталог сайта мертвы.
#
# Если в nginx/adapter/ лежат запреты адаптера, --uploads обязателен: трассер
# по обобщённому /uploads/ ядра зелёный и тогда, когда PHP в загрузках CMS
# исполняется по прямой ссылке.
#
# Смотрит глазами обратного прокси: запросы идут к веб-серверу по внутренней
# сети из контейнера приложения, с настоящим именем хоста. Проверяется и код,
# и тело: закрытый файл не должен отдавать содержимое даже с кодом отказа.
#
# Безопасен на живом сайте: пробник создаётся ТОЛЬКО если такого файла ещё
# нет, а убирается ровно то, что создал этот прогон. Иначе уборка снесла бы
# настоящий конфиг сайта.
#
# Код 0: запреты подтверждены. Код 1: находка. Код 2: стек не доступен.
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir/.." || exit 2

HOST={{DOMAIN}}
web={{SLUG}}-nginx
docroot=/var/www/html
uploads=uploads
uploads_given=0
extra_deny=''
extra_allow=''

while [ "$#" -gt 0 ]; do
    case $1 in
        --uploads) [ "$#" -ge 2 ] || { echo '--uploads без значения' >&2; exit 2; }; uploads=${2#/}; uploads=${uploads%/}; uploads_given=1; shift 2 ;;
        --allow) [ "$#" -ge 2 ] || { echo '--allow без значения' >&2; exit 2; }; a=${2#/}; extra_allow="$extra_allow ${a%/}"; shift 2 ;;
        --deny) [ "$#" -ge 2 ] || { echo '--deny без значения' >&2; exit 2; }; extra_deny="$extra_deny $2"; shift 2 ;;
        -h | --help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
    esac
done

# Запреты адаптера это любой файл каталога, кроме пустой заглушки ядра.
if [ "$uploads_given" -eq 0 ]; then
    for f in nginx/adapter/*.conf; do
        case $f in */00-none.conf | 'nginx/adapter/*.conf') continue ;; esac
        echo "в стеке запреты адаптера ($f), а --uploads не задан" >&2
        echo 'трассер по /uploads/ ядра ничего не скажет о загрузках CMS: укажите их каталог, например --uploads wp-content/uploads' >&2
        exit 2
    done
fi

fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }
note() { printf 'note  %s\n' "$1"; }

app() {
    docker compose exec -T php-fpm "$@"
}

app true >/dev/null 2>&1 || { echo 'контейнер приложения не отвечает: стек поднят?' >&2; exit 2; }

# fetch PATH [аргументы curl]: ответ целиком, с заголовками. stderr в ответ не
# подмешивается: предупреждение docker compose встало бы первой строкой, и
# код ответа из неё не прочитался бы.
fetch() {
    fetch_path=$1
    shift
    app curl -sS -i --max-time 10 -H "Host: $HOST" "$@" "http://$web$fetch_path" 2>/dev/null \
        || printf 'CURL-FAILED\n'
}

status_of() {
    printf '%s\n' "$1" | sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p'
}

# Создаётся только отсутствующее, убирается только созданное. Список ведётся
# здесь, а не угадывается в уборке.
created_files=''
created_dirs=''
cleanup() {
    [ -n "$created_files$created_dirs" ] || return 0
    app sh -c '
        cd "$1" || exit 0
        for f in $2; do rm -f -- "$f"; done
        # rmdir, а не rm -rf: каталог с чужим содержимым он не тронет.
        for d in $3; do rmdir -- "$d" 2>/dev/null || true; done
    ' sh "$docroot" "$created_files" "$created_dirs" >/dev/null 2>&1 || true
    created_files=''
    created_dirs=''
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# probe_dir DIR: создать каталог, если его нет, и запомнить только созданные
# уровни, от глубокого к корню, чтобы rmdir убрал их по порядку.
probe_dir() {
    probe_path=''
    for part in $(printf '%s' "$1" | tr '/' ' '); do
        probe_path=${probe_path:+$probe_path/}$part
        if ! app test -d "$docroot/$probe_path"; then
            app mkdir "$docroot/$probe_path" || { fail "не создать каталог $probe_path"; return 1; }
            created_dirs="$probe_path $created_dirs"
        fi
    done
}

# probe_file PATH CONTENT: 0, если файл создан этим прогоном; 1, если он уже
# был, и тогда проверяется как есть, без записи и без уборки.
probe_file() {
    if app test -e "$docroot/$1"; then
        note "$1 уже есть в docroot: проверяется как есть, не создаётся и не удаляется"
        return 1
    fi
    printf '%s' "$2" | app sh -c 'cat > "$1"' sh "$docroot/$1"
    created_files="$1 $created_files"
}

probe_php='<?php echo "PROBE-", "EXECUTED";'

echo '--- Путь до приложения ---'
# Положительный контроль. Без него каждое «не исполняется» ниже зелёное и
# тогда, когда PHP не работает вовсе.
runtime=verify-tracer-runtime.php
if probe_file "$runtime" "$probe_php"; then
    response=$(fetch "/$runtime")
    case $response in
        *PROBE-EXECUTED*) pass 'пробник в корне исполнился: путь веб-сервер, приложение жив' ;;
        *) fail "пробник в корне не исполнился, запреты ниже ничего не доказывают: $(status_of "$response")" ;;
    esac
else
    fail "$runtime уже лежит в docroot: чужой файл не трогаю, положительный контроль не выполнен"
fi

echo '--- Исполняемый код там, где его быть не должно ---'
probe_dir "$uploads/verify-tracer-dir"
probe_dir .verify-tracer-hidden
probe_file "$uploads/verify-tracer-probe.php" "$probe_php" || true
probe_file .verify-tracer-hidden/shell.php "$probe_php" || true
probe_file .verify-tracer-probe.php "$probe_php" || true

# Ровно эти три пути исполнялись на заражённом хостинге: вебшелл в
# загрузках, в точечном каталоге и точечный файл в корне. Два последних
# исполняются, как только запрет точечных файлов уезжает ниже общего блока PHP.
for path in "/$uploads/verify-tracer-probe.php" /.verify-tracer-hidden/shell.php /.verify-tracer-probe.php; do
    response=$(fetch "$path")
    code=$(status_of "$response")
    case $response in
        *PROBE-EXECUTED*) fail "$path ИСПОЛНИЛСЯ: через такую дыру заражали сайт" ;;
        *)
            if [ "$code" = 403 ]; then pass "$path не исполняется, 403"
            else fail "$path не исполнился, но ответил ${code:-без кода}, а не 403"; fi ;;
    esac
done

# Обратная сторона запрета: там, где адаптер оставил исполнение, PHP обязан
# исполниться. Запрет, накрывший коннекторы расширений, этим и виден.
for dir in $extra_allow; do
    probe_dir "$dir"
    if probe_file "$dir/verify-tracer-allowed.php" "$probe_php"; then
        response=$(fetch "/$dir/verify-tracer-allowed.php")
        case $response in
            *PROBE-EXECUTED*) pass "/$dir/ исполняет PHP, как и должен" ;;
            *) fail "/$dir/ не исполнил пробник: $(status_of "$response"). Запрет накрыл точки входа расширений" ;;
        esac
    else
        fail "/$dir/verify-tracer-allowed.php уже есть: чужой файл не трогаю, проверка не выполнена"
    fi
done

echo '--- Закрытые файлы: код и тело ---'
# expect_closed PATH: 403, и в теле нет первой строки самого файла. Строка
# читается из docroot, поэтому проверка работает одинаково на пробнике и на
# настоящем файле, приехавшем со снимком.
expect_closed() {
    content=$(app sh -c 'grep -m 1 . "$1"' sh "$docroot/${1#/}" 2>/dev/null)
    response=$(fetch "$1")
    code=$(status_of "$response")
    if [ "$code" != 403 ]; then
        fail "$1 ответил ${code:-без кода}, а не 403"
    elif [ -n "$content" ] && printf '%s' "$response" | grep -qF -- "$content"; then
        fail "$1 закрыт кодом, но отдал содержимое в теле"
    else
        pass "$1 закрыт, 403, содержимое не отдаётся"
    fi
}

probe_file readme.html 'PROBE-README' || true
expect_closed /readme.html
# Безвредный комментарий, а не директива: настоящая применилась бы к сайту и
# висела бы в кэше PHP ещё минуты после удаления пробника.
probe_file .user.ini '; PROBE-USERINI' || true
expect_closed /.user.ini
# Не .env: сайт на dotenv подхватил бы пробник как свой конфиг, пока идёт
# прогон. Запрет точечных файлов закрывает любое имя с точкой.
probe_file .verify-tracer.env 'DB_PASSWORD=PROBE-SECRET' || true
expect_closed /.verify-tracer.env
probe_file verify-tracer-config.php.bak "<?php \$db_password = 'PROBE-SECRET';" || true
expect_closed /verify-tracer-config.php.bak
probe_file verify-tracer-dump.sql 'INSERT INTO users VALUES (PROBE-SECRET);' || true
expect_closed /verify-tracer-dump.sql

# Свои точки входа CMS: адаптер передаёт их --deny. Пробник исполняемый, чтобы
# отличить «закрыт» от «исполнился и ничего не вывел».
for path in $extra_deny; do
    rel=${path#/}
    case $rel in */*) probe_dir "${rel%/*}" ;; esac
    probe_file "$rel" "$probe_php" || true
    response=$(fetch "$path")
    code=$(status_of "$response")
    case $response in
        *PROBE-EXECUTED*) fail "$path ИСПОЛНИЛСЯ, хотя адаптер его закрывает" ;;
        *) if [ "$code" = 403 ]; then pass "$path закрыт, 403"; else fail "$path ответил ${code:-без кода}, а не 403"; fi ;;
    esac
    response=$(fetch "$path" -X POST)
    [ "$(status_of "$response")" = 403 ] && pass "$path закрыт и для POST" \
        || fail "$path на POST ответил $(status_of "$response"), а не 403"
done

echo '--- Листинг каталога ---'
probe_file "$uploads/verify-tracer-dir/probe.txt" 'PROBE-IN-DIR' || true
response=$(fetch "/$uploads/verify-tracer-dir/")
code=$(status_of "$response")
case $response in
    *'Index of'* | *PROBE-IN-DIR*) fail 'веб-сервер отдаёт листинг каталога' ;;
    *)
        # Отказ, а не любой ответ: таймаут или 502 ничего не доказывают.
        case $code in
            403 | 404) pass "листинг каталога не отдаётся, $code" ;;
            *) fail "каталог без индекса ответил ${code:-без кода}, ждали 403 или 404" ;;
        esac ;;
esac

cleanup
echo
if [ "$fails" -eq 0 ]; then
    echo 'трассер: запреты подтверждены живыми пробниками'
    exit 0
fi
echo "трассер: находок $fails" >&2
exit 1
