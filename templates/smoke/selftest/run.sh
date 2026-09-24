#!/bin/sh
# Доказывает, что smoke.sh делает свою работу: зелёный на здоровом сайте и
# красный, причём ИМЕННО названной проверкой, на каждом способе его сломать.
# Смоук, который видели только зелёным, ничего не обнаруживает.
#
# Сайт это fake_site.py, поэтому нужны python3, curl, openssl и xmllint. Сеть,
# сервер и докер не нужны.
#
# Код 0: все ожидания сбылись. Код 1: хотя бы одно нет. Код 2: не поднялось
# окружение самотеста.
set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
smoke="$here/../smoke.sh"
config="$here/site.conf"
work=$(mktemp -d)
out="$work/out"
site_pid=''
failed=0

cleanup() {
    [ -z "$site_pid" ] || kill "$site_pid" 2>/dev/null
    rm -rf "$work"
}
# Одного EXIT мало: не каждый sh выполняет его при сигнале, и без INT и TERM
# подставной сайт пережил бы Ctrl-C.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command_name in python3 curl openssl xmllint; do
    command -v "$command_name" >/dev/null 2>&1 || { echo "нет команды: $command_name" >&2; exit 2; }
done

free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
http_port=$(free_port)
https_port=$(free_port)

# Три сертификата: правильный, выданный на чужое имя и истекающий через сутки.
# Все три лежат в одном наборе доверенных, поэтому отказ по имени это отказ по
# имени, а не по доверию, а отказ по сроку только по сроку.
cert() {
    openssl req -x509 -newkey rsa:2048 -nodes -days "$3" -subj "/CN=$2/O=selftest-$1" \
        -addext "subjectAltName=DNS:$2,DNS:www.$2" \
        -keyout "$work/$1.key" -out "$work/$1.crt" >/dev/null 2>&1 \
        || { echo "openssl не выпустил сертификат $1" >&2; exit 2; }
}
cert ok example.test 90
cert wrong other.test 90
cert short example.test 1
cat "$work/ok.crt" "$work/wrong.crt" "$work/short.crt" >"$work/ca.pem"

# start_site STAGE [DEFECT]
start_site() {
    python3 "$here/fake_site.py" "$http_port" "$https_port" "$work" "$1" "${2:-}" &
    site_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        curl -s -o /dev/null "http://127.0.0.1:$http_port/__leads" && return 0
        sleep 0.25
    done
    echo "подставной сайт не поднялся (дефект: ${2:-нет})" >&2
    exit 2
}

stop_site() {
    kill "$site_pid" 2>/dev/null
    wait "$site_pid" 2>/dev/null
    site_pid=''
}

# Режимы запуска смоука. До переключения: подмена адреса по http. После:
# без подмены, а публичный DNS и доверенный центр заменяют тестовые
# переменные, которые знает только смоук.
run_resolve() {
    "$smoke" --config "$config" --resolve 127.0.0.1 --port "$http_port" "$@" >"$out" 2>&1
    rc=$?
}
# Тот же конфиг с compare_titles=no, для сайта с одним заголовком на всех страницах.
run_resolve_body_only() {
    { cat "$config"; echo 'compare_titles=no'; } >"$work/body-only.conf"
    cp "$here/robots.txt" "$work/robots.txt"
    "$smoke" --config "$work/body-only.conf" --resolve 127.0.0.1 --port "$http_port" >"$out" 2>&1
    rc=$?
}
# Конфиг с изъяном из bad_config, в режиме подмены по http.
run_resolve_bad() {
    "$smoke" --config "$work/bad.conf" --resolve 127.0.0.1 --port "$http_port" >"$out" 2>&1
    rc=$?
}
run_resolve_https() {
    SMOKE_TEST_CACERT="$work/ca.pem" \
        "$smoke" --config "$config" --resolve 127.0.0.1 --scheme https --port "$https_port" >"$out" 2>&1
    rc=$?
}
run_direct() {
    SMOKE_TEST_CONNECT="127.0.0.1:$http_port:$https_port" SMOKE_TEST_CACERT="$work/ca.pem" \
        "$smoke" --config "$config" >"$out" 2>&1
    rc=$?
}

report() {
    if [ "$1" = ok ]; then
        printf '  ok    %s\n' "$2"
    else
        printf '  FAIL  %s\n' "$2"
        sed 's/^/          | /' "$out"
        failed=$((failed + 1))
    fi
}

# expect_pass RUNNER STAGE LABEL [DEFECT]: DEFECT здесь это то, что НЕ должно
# ронять прогон в этом режиме.
expect_pass() {
    start_site "$2" "${4:-}"
    "$1"
    if [ "$rc" -eq 0 ] && ! grep -q '^  FAIL' "$out"; then report ok "$3"; else report fail "$3 (код $rc)"; fi
    stop_site
}

# expect_fail RUNNER STAGE DEFECT LABEL: код 1 и среди упавших есть названная
# проверка. Вместе с ней могут упасть и другие: мёртвая страница тянет за собой
# сравнение тел.
expect_fail() {
    start_site "$2" "$3"
    "$1"
    if [ "$rc" -eq 1 ] && grep -qF -- "  FAIL  $4" "$out"; then
        report ok "$3 ловится проверкой «$4»"
    else
        report fail "$3 не пойман проверкой «$4» (код $rc)"
    fi
    stop_site
}

# expect_no_lead: пробник формы не создаёт обращение, иначе оно ушло бы
# живым менеджерам площадки.
expect_no_lead() {
    start_site before
    run_resolve
    leads=$(curl -s "http://127.0.0.1:$http_port/__leads")
    if [ "$rc" -eq 0 ] && [ "$leads" = 0 ]; then report ok "$1"; else report fail "$1 (код $rc, обращений: $leads)"; fi
    stop_site
}

# expect_deferred LABEL...: в режиме подмены эти проверки объявлены
# отложенными, а не пропущены молча, и код возврата не трогают.
expect_deferred() {
    start_site before
    run_resolve
    for label in "$@"; do
        if [ "$rc" -eq 0 ] && grep -qF -- "  defer $label" "$out"; then
            report ok "в режиме подмены отложена: $label"
        else
            report fail "не объявлена отложенной: $label (код $rc)"
        fi
    done
    stop_site
}

# expect_usage_error LABEL ARGS...: код 2 и причина в stderr, ни одной проверки.
expect_usage_error() {
    label=$1
    shift
    "$smoke" "$@" >"$out" 2>&1
    rc=$?
    if [ "$rc" -eq 2 ] && ! grep -q '^  ok' "$out"; then report ok "код 2: $label"; else report fail "ждали код 2: $label (код $rc)"; fi
}

# expect_hint: http уже уходит на https, и вместо каскада FAIL звучит одна
# понятная просьба повторить с другой схемой.
expect_hint() {
    start_site after
    run_resolve
    if [ "$rc" -eq 2 ] && grep -q 'повторите с --scheme https' "$out" && ! grep -q '^  FAIL' "$out"; then
        report ok "$1"
    else
        report fail "$1 (код $rc)"
    fi
    stop_site
}

# expect_unreachable: никто не слушает. Вердикт сразу и один раз, а не после
# того, как каждая проверка отсидит свой таймаут.
expect_unreachable() {
    started=$(date +%s)
    run_resolve
    elapsed=$(($(date +%s) - started))
    fails=$(grep -c '^  FAIL' "$out")
    if [ "$rc" -eq 1 ] && [ "$fails" -eq 1 ] && grep -q '^  FAIL  главная отвечает 200 (нет ответа' "$out" \
        && [ "$elapsed" -le 10 ]; then
        report ok "$1"
    else
        report fail "$1 (код $rc, строк FAIL: $fails, ${elapsed} с)"
    fi
}

expect_help() {
    "$smoke" --help >"$out" 2>/dev/null
    rc=$?
    if [ "$rc" -eq 0 ] && grep -q 'smoke.sh --resolve IP' "$out"; then report ok "$1"; else report fail "$1 (код $rc)"; fi
}

# Конфиги с изъяном: смоук обязан отказаться до первого запроса.
bad_config() {
    grep -v "$1" "$config" >"$work/bad.conf"
    [ -z "${2:-}" ] || printf '%s\n' "$2" >>"$work/bad.conf"
    # Эталон robots ищется рядом с конфигом.
    cp "$here/robots.txt" "$work/robots.txt"
}

echo 'Здоровый сайт:'
expect_pass run_resolve before 'до переключения, подмена адреса по http: всё зелёное'
expect_pass run_resolve_https after 'подмена адреса по https: всё зелёное'
expect_pass run_direct after 'после переключения, публичное имя: всё зелёное'
expect_unreachable 'молчащий сервер: один FAIL и быстро'

echo 'Главная:'
expect_fail run_resolve before home-500 'главная отвечает 200'
expect_fail run_resolve before home-no-marker 'главная несёт маркер приложения'
expect_fail run_resolve before home-unrendered 'главная без запрещённых фрагментов'
expect_fail run_resolve before media-double-slash 'главная без ссылок с двойным слэшем'
expect_fail run_resolve before internal-link 'главная без ссылок на внутренние адреса'
expect_fail run_resolve before container-link 'главная без ссылок на внутренние адреса'

echo 'Слепок старой площадки:'
expect_fail run_resolve before unicode-lost '/about/ несёт текст слепка'
bad_config '^expect=' 'expect=none'
start_site before
run_resolve_bad
if [ "$rc" -eq 0 ] && grep -q '^  note  сравнение со слепком не выполнено' "$out"; then
    report ok 'expect=none: отказ от сравнения объявлен в выводе, а не молчит'
else
    report fail "expect=none не объявлен в выводе (код $rc)"
fi
stop_site
# Шаблонная пустая строка остаётся в конфиге выше заполненных: она не
# значение и не должна ни ронять конфиг, ни заслонять эталоны под собой.
bad_config '^nothing-to-drop' 'expect='
{ printf 'expect=\npage=\n'; cat "$work/bad.conf"; } >"$work/bad.conf.new" && mv "$work/bad.conf.new" "$work/bad.conf"
start_site before
run_resolve_bad
if [ "$rc" -eq 0 ] && grep -q '^  ok    /about/ несёт текст слепка' "$out"; then
    report ok 'пустые шаблонные expect= и page= рядом с заполненными не мешают'
else
    report fail "пустые шаблонные строки сломали конфиг (код $rc)"
fi
stop_site

echo 'Внутренние страницы, сравнение тел:'
expect_fail run_resolve before every-path-is-home '/about/ не копия главной'
expect_fail run_resolve before page-is-home '/about/ не копия главной'
expect_fail run_resolve before pages-identical 'тела внутренних страниц различаются'
expect_fail run_resolve before page-404 '/about/ отвечает 200'
expect_fail run_resolve before same-titles '/about/ не копия главной'
expect_pass run_resolve_body_only before 'один <title> на всех страницах при compare_titles=no не ложный отказ' same-titles

echo 'Карта сайта и robots.txt:'
expect_fail run_resolve before sitemap-500 'карта сайта отвечает 200'
expect_fail run_resolve before sitemap-broken 'карта сайта это валидный XML'
expect_fail run_resolve before sitemap-not-sitemap 'карта сайта это urlset или sitemapindex'
expect_fail run_resolve before robots-stub 'robots.txt совпадает с эталоном побайтово'
expect_fail run_resolve before robots-one-byte 'robots.txt совпадает с эталоном побайтово'
expect_fail run_resolve before robots-404 'robots.txt совпадает с эталоном побайтово'

echo 'Форма:'
expect_fail run_resolve before form-missing 'форма найдена на странице'
expect_fail run_resolve before form-500 'форма: POST дошёл до обработчика'
expect_fail run_resolve before form-accepts-empty 'форма отвергает пустую отправку'
expect_no_lead 'пробник формы не создаёт обращение'
expect_pass run_resolve before 'токен формы перевыпускается на каждый рендер: не ложный отказ' token-rotates

echo 'Публичное имя: www, https, сертификат:'
expect_deferred 'TLS: сертификат' 'www отдаёт 301 на основное имя' 'http уходит на https'
# Те же поломки, что ниже роняют прямой режим: в режиме подмены они обязаны
# остаться отложенными и не тронуть код возврата.
expect_pass run_resolve_https after 'в режиме подмены сломанный www не влияет на код' www-no-redirect
expect_pass run_resolve_https after 'в режиме подмены http без редиректа не влияет на код' http-no-redirect
expect_fail run_direct after www-no-redirect 'www отдаёт 301 на основное имя'
expect_fail run_direct after www-302 'www отдаёт 301 на основное имя'
expect_fail run_direct after http-no-redirect 'http уходит на https'
expect_fail run_direct after cert-wrong-name 'TLS: сертификат'
expect_fail run_direct after cert-expiring 'TLS: сертификат'

echo 'Аргументы и конфиг:'
expect_help '--help печатает справку, код 0'
expect_hint 'http уже уходит на https: код 2 и просьба повторить с --scheme https'
expect_usage_error '--scheme без --resolve' --config "$config" --scheme http
expect_usage_error '--port без --resolve' --config "$config" --port 8080
expect_usage_error '--resolve без значения' --config "$config" --resolve
expect_usage_error 'неизвестная схема' --config "$config" --resolve 127.0.0.1 --scheme ftp
expect_usage_error 'неизвестный аргумент' --config "$config" --no-such-option
expect_usage_error 'конфига нет' --config "$work/nope.conf"
bad_config '^marker='
expect_usage_error 'в конфиге не заполнен marker' --config "$work/bad.conf" --resolve 127.0.0.1
bad_config '^nothing-to-drop' 'hots=example.test'
expect_usage_error 'в конфиге неизвестный ключ' --config "$work/bad.conf" --resolve 127.0.0.1
bad_config '^page=/contacts/'
expect_usage_error 'одна page, попарное сравнение невозможно' --config "$work/bad.conf" --resolve 127.0.0.1
bad_config '^expect='
expect_usage_error 'в конфиге не заполнен expect' --config "$work/bad.conf" --resolve 127.0.0.1
bad_config '^expect=/contacts/' 'expect=/contacts/'
expect_usage_error 'expect без текста слепка' --config "$work/bad.conf" --resolve 127.0.0.1
bad_config '^form_rejected='
expect_usage_error 'форма без признаков отказа' --config "$work/bad.conf" --resolve 127.0.0.1
bad_config '^form_field=name' 'form_field=name=Иван'
expect_usage_error 'заполненное поле формы запрещено' --config "$work/bad.conf" --resolve 127.0.0.1

if [ "$failed" -ne 0 ]; then
    printf '\nсамотест смоука: не сбылось ожиданий: %s\n' "$failed" >&2
    exit 1
fi
echo 'самотест смоука: OK'
