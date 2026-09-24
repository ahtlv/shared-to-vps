#!/bin/sh
# Внешний смоук площадки чёрным ящиком: жив ли весь сайт, а не одна главная.
#
#   smoke.sh                                  публичное имя через публичный DNS
#   smoke.sh --resolve IP                     один сервер по http, до переключения DNS
#   smoke.sh --resolve IP --scheme https      то же, когда сервер уже уводит http на https
#   smoke.sh --config FILE ...                конфиг площадки; по умолчанию smoke.conf рядом
#
# Код 0: все применимые проверки прошли. Код 1: хотя бы одна упала. Код 2:
# неверные аргументы или конфиг, нет нужной команды, либо сервер уже уводит
# http на https и запуск нужно повторить с --scheme https.
#
# Проверки, которым нужен публичный DNS (сертификат, www, http на https), в
# режиме --resolve печатаются как defer и на код не влияют. Зелёный прогон с
# --resolve доказывает сервер, а не переключение: после смены записи
# повторить без --resolve.
#
# Только чтение: форма уходит с пустыми обязательными полями, валидация её
# отвергает, и обращение не создаётся. Собственный тест: selftest/run.sh.
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
config="$script_dir/smoke.conf"
resolve_ip=''
scheme=''
port=''

# usage [КОД]: справка в stdout с 0, ошибка в stderr с 2. Текст берётся из шапки.
usage() {
    if [ "${1:-2}" -eq 0 ]; then
        sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"
    else
        sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0" >&2
    fi
    exit "${1:-2}"
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --config) [ "$#" -ge 2 ] || usage; config=$2; shift 2 ;;
        --resolve) [ "$#" -ge 2 ] || usage; resolve_ip=$2; shift 2 ;;
        --scheme) [ "$#" -ge 2 ] || usage; scheme=$2; shift 2 ;;
        # Нестандартный порт сервера в режиме --resolve: стенд, самотест.
        --port) [ "$#" -ge 2 ] || usage; port=$2; shift 2 ;;
        -h | --help) usage 0 ;;
        *) echo "неизвестный аргумент: $1" >&2; usage ;;
    esac
done

if [ -n "$resolve_ip" ]; then
    mode=resolve
    scheme=${scheme:-http}
else
    mode=direct
    [ -z "$scheme" ] || { echo '--scheme имеет смысл только с --resolve' >&2; exit 2; }
    [ -z "$port" ] || { echo '--port имеет смысл только с --resolve' >&2; exit 2; }
    scheme=https
fi
case $scheme in
    http | https) ;;
    *) echo "--scheme бывает http или https, получено: $scheme" >&2; exit 2 ;;
esac

for command_name in curl openssl xmllint; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "нет команды: $command_name (xmllint в Debian и Ubuntu из пакета libxml2-utils)" >&2
        exit 2
    }
done

[ -f "$config" ] || { echo "конфиг не найден: $config" >&2; exit 2; }
config_dir=$(CDPATH= cd -- "$(dirname -- "$config")" && pwd)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Конфиг: строки ключ=значение, значение от первого `=` до конца строки, как
# есть. Повторяемый ключ копит значения по одному на строку. Разбирается, а не
# исполняется: source выполнил бы конфиг как код.
mkdir "$tmp/cfg"
config_error() { echo "конфиг $config, строка $line_no: $1" >&2; exit 2; }
line_no=0
while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    line=${line%"$(printf '\r')"}
    case $line in '' | '#'*) continue ;; esac
    case $line in *=*) ;; *) config_error "нет знака =: $line" ;; esac
    key=${line%%=*}
    value=${line#*=}
    case $key in
        host | marker | sitemap | robots | www_path | compare_titles | form_page | form_url | form_status)
            [ ! -f "$tmp/cfg/$key" ] || config_error "ключ $key задан дважды" ;;
        page | expect | forbid | form_param | form_capture | form_header | form_rejected | form_accepted)
            # Пустая строка повторяемого ключа это заготовка из шаблона, а не
            # значение: иначе она заслонила бы заполненные строки под собой.
            [ -n "$value" ] || continue ;;
        form_field)
            # Поле называется, но не заполняется: так пробник по построению не
            # может создать обращение, даже если валидацию на сайте выключили.
            case $value in *=*) config_error "form_field это только имя поля, без значения: смоук не шлёт заполненных полей" ;; esac ;;
        *) config_error "неизвестный ключ: $key" ;;
    esac
    printf '%s\n' "$value" >>"$tmp/cfg/$key"
done <"$config"

# cfg КЛЮЧ: значение одиночного ключа, пусто если не задан.
cfg() {
    [ -f "$tmp/cfg/$1" ] && head -n 1 "$tmp/cfg/$1"
}
has_cfg() {
    [ -s "$tmp/cfg/$1" ] && [ -n "$(head -n 1 "$tmp/cfg/$1")" ]
}

for key in host marker page expect robots form_url; do
    has_cfg "$key" || { echo "конфиг $config: не заполнено обязательное поле $key" >&2; exit 2; }
done
# Одной страницы мало: копия бывает и не главной, а соседней страницы, и
# поймать её можно только попарным сравнением.
if [ "$(grep -c . "$tmp/cfg/page")" -lt 2 ]; then
    echo "конфиг $config: нужно хотя бы два page, для попарного сравнения тел" >&2
    exit 2
fi
# expect это ПУТЬ ТЕКСТ через первый пробел: в пути пробела нет, а в тексте
# слепка он почти всегда есть. none отказывается от сравнения явно, и отказ
# печатается в выводе.
if [ "$(cfg expect)" = none ]; then
    [ "$(grep -c . "$tmp/cfg/expect")" -eq 1 ] || { echo "конфиг $config: expect=none вместе с другими expect" >&2; exit 2; }
else
    while IFS= read -r e; do
        case $e in
            /*' '?*) ;;
            *) echo "конфиг $config: expect это «/путь текст из слепка», получено: $e" >&2; exit 2 ;;
        esac
    done <"$tmp/cfg/expect"
fi
compare_titles=$(cfg compare_titles)
compare_titles=${compare_titles:-yes}
case $compare_titles in
    yes | no) ;;
    *) echo "конфиг $config: compare_titles бывает yes или no, получено: $compare_titles" >&2; exit 2 ;;
esac
HOST=$(cfg host)
case $HOST in */* | *:* | *' '*) echo "host это имя без схемы, порта и пути, получено: $HOST" >&2; exit 2 ;; esac
robots_reference=$(cfg robots)
case $robots_reference in /*) ;; *) robots_reference="$config_dir/$robots_reference" ;; esac
[ -f "$robots_reference" ] || { echo "эталон robots.txt не найден: $robots_reference" >&2; exit 2; }
sitemap_path=$(cfg sitemap)
sitemap_path=${sitemap_path:-/sitemap.xml}
www_path=$(cfg www_path)
www_path=${www_path:-$(head -n 1 "$tmp/cfg/page")}
form_url=$(cfg form_url)
form_page=$(cfg form_page)
form_page=${form_page:-/}
# Без признаков отказа проверка формы прошла бы на любом ответе.
if [ "$form_url" != none ] && ! has_cfg form_rejected; then
    echo "конфиг $config: при form_url нужен хотя бы один form_rejected" >&2
    exit 2
fi
form_status=$(cfg form_status)
form_status=${form_status:-200}

# Только для самотеста: заменяют публичный DNS и публичный центр сертификации,
# которых у подставного сайта нет. Формат SMOKE_TEST_CONNECT: IP:HTTP:HTTPS.
test_connect=${SMOKE_TEST_CONNECT:-}
test_cacert=${SMOKE_TEST_CACERT:-}
if [ -n "$test_connect" ]; then
    test_ip=${test_connect%%:*}
    test_rest=${test_connect#*:}
    test_http=${test_rest%%:*}
    test_https=${test_rest#*:}
fi

default_port=80
[ "$scheme" = https ] && default_port=443
origin="$scheme://$HOST"
[ -z "$port" ] || origin="$origin:$port"

failed=0
deferred=0

# curl_site [аргументы curl]: curl с маршрутизацией текущего режима. Все
# запросы делят одну банку кук, как браузер: форма держит свой ключ в сессии,
# и POST без куки главной для неё чужой.
curl_site() {
    [ -z "$test_cacert" ] || set -- --cacert "$test_cacert" "$@"
    if [ "$mode" = resolve ]; then
        set -- --resolve "$HOST:${port:-$default_port}:$resolve_ip" "$@"
    elif [ -n "$test_connect" ]; then
        set -- --connect-to "$HOST:80:$test_ip:$test_http" --connect-to "$HOST:443:$test_ip:$test_https" \
            --connect-to "www.$HOST:80:$test_ip:$test_http" --connect-to "www.$HOST:443:$test_ip:$test_https" "$@"
    fi
    curl -sS --connect-timeout 10 -m 20 -b "$tmp/cookies" -c "$tmp/cookies" "$@" </dev/null
}

# fetch_url URL [аргументы curl]: ставит $status, тело и заголовки в $tmp.
fetch_url() {
    fetch_target=$1
    shift
    status=$(curl_site -o "$tmp/body" -D "$tmp/headers" -w '%{http_code}' "$@" "$fetch_target" 2>"$tmp/error") \
        || status=000
    if [ "$status" = 000 ]; then
        : >"$tmp/body"
        : >"$tmp/headers"
    fi
}

fetch() {
    fetch_path=$1
    shift
    fetch_url "$origin$fetch_path" "$@"
}

# header ИМЯ: значение заголовка последнего ответа, пусто если его нет.
header() {
    awk -v wanted="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" '
        { name = tolower(substr($0, 1, index($0, ":") - 1)) }
        name == wanted { sub(/^[^:]*:[ \t]*/, ""); sub(/\r$/, ""); print; exit }
    ' "$tmp/headers"
}

contains() {
    case $1 in *"$2"*) return 0 ;; *) return 1 ;; esac
}

# has ФАЙЛ СТРОКА: файл содержит строку буквально.
has() {
    grep -qF -- "$2" "$1"
}

# no_forbidden ФАЙЛ: ни одного фрагмента из forbid. Им отмечают то, что
# появляется в теле при живом коде 200: сырой шаблон, фатальная ошибка движка.
forbidden_found=''
no_forbidden() {
    forbidden_found=''
    [ -f "$tmp/cfg/forbid" ] || return 0
    while IFS= read -r fragment; do
        [ -z "$fragment" ] || ! has "$1" "$fragment" || { forbidden_found=$fragment; return 1; }
    done <"$tmp/cfg/forbid"
}

# Источник с ведущим двойным слэшем без точки в имени: //uploads/a.webp.
# Браузер читает uploads как имя хоста, картинки не грузятся, а страница
# остаётся зелёной. Протокол-относительная ссылка на //cdn.example.net с точкой
# в имени законна и не ловится.
no_double_slash() {
    ! grep -Eq "(=[\"']?|url\([\"']?)//[^/\"'. )]+/" "$1"
}

# Абсолютная ссылка на внутренний адрес: localhost, петля, частная сеть или
# имя без точки (имя контейнера, короткое имя сервиса). Так выглядит адрес
# сайта, который CMS вывела из имени хоста чужого запроса и положила в кэш
# для всех следующих посетителей.
no_internal_links() {
    ! grep -Eiq "(=[\"']?|url\([\"']?)https?://(localhost|127\.[0-9.]+|0\.0\.0\.0|10\.[0-9.]+|192\.168\.[0-9.]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9.]+|[a-z0-9_-]+)([:/\"' )]|$)" "$1"
}

# Разбор ошибок xmllint в выводе смоука только шумит: достаточно вердикта.
valid_xml() {
    xmllint --noout "$1" >/dev/null 2>&1
}

# title_of ФАЙЛ: первый <title> страницы, пусто если его нет.
title_of() {
    tr '\r\n' '  ' <"$1" | grep -qi '<title' || return 0
    tr '\r\n' '  ' <"$1" | sed 's#</[Tt][Ii][Tt][Ll][Ee]>.*##; s/.*<[Tt][Ii][Tt][Ll][Ee][^>]*>//'
}

# same_page A B: две выдачи это одна и та же страница. Побайтового сравнения
# мало: одноразовый токен в теле делает копию главной «другой», и оборванное
# восстановление прошло бы. Совпавший непустой <title> тоже считается копией.
# Сайту с одним заголовком на всех страницах это ложный отказ: для него в
# конфиге compare_titles=no, и остаётся только сравнение тел.
same_page() {
    cmp -s "$1" "$2" && return 0
    [ "$compare_titles" = yes ] || return 1
    title_a=$(title_of "$1")
    [ -n "$title_a" ] && [ "$title_a" = "$(title_of "$2")" ]
}

# check МЕТКА ПОЯСНЕНИЕ КОМАНДА...: условие это команда.
check() {
    check_label=$1
    check_detail=$2
    shift 2
    if "$@"; then
        printf '  ok    %s\n' "$check_label"
    else
        printf '  FAIL  %s%s\n' "$check_label" "${check_detail:+ ($check_detail)}"
        failed=$((failed + 1))
    fi
}

defer() {
    printf '  defer %s (%s)\n' "$1" "$2"
    deferred=$((deferred + 1))
}

got() {
    if [ "$status" = 000 ]; then
        printf 'нет ответа: %s' "$(tr '\n' ' ' <"$tmp/error")"
    else
        printf 'код %s' "$status"
    fi
}

if [ "$mode" = resolve ]; then
    echo "смоук $HOST: $origin через $resolve_ip, публичный DNS не спрашивается"
else
    echo "смоук $HOST: $origin через публичный DNS"
fi

# Сертификат проверяется до всего остального: с плохим сертификатом не
# ответит ни один адрес по https, и без этой проверки отказ выглядел бы как
# «сервер молчит», а не назывался своим именем.
tls_min_days=14
tls_label="TLS: сертификат доверенный, выдан на $HOST и действует ещё $tls_min_days дней"
www_label='www отдаёт 301 на основное имя'
http_label='http уходит на https'
tls_detail=''
# curl проверяет цепочку и имя, openssl добавляет срок.
tls_certificate_ok() {
    if ! curl_site -o /dev/null "https://$HOST/" 2>"$tmp/error"; then
        tls_detail=$(tr '\n' ' ' <"$tmp/error")
        return 1
    fi
    tls_address="$HOST:443"
    [ -z "$test_connect" ] || tls_address="$test_ip:$test_https"
    if ! openssl s_client -connect "$tls_address" -servername "$HOST" </dev/null 2>/dev/null \
        | openssl x509 -noout -checkend $((tls_min_days * 86400)) >/dev/null; then
        tls_detail="истекает раньше чем через $tls_min_days дней"
        return 1
    fi
}
if [ "$mode" = direct ]; then
    echo 'Сертификат:'
    if tls_certificate_ok; then tls_ok=0; else tls_ok=1; fi
    check "$tls_label" "$tls_detail" test "$tls_ok" = 0
fi

echo 'Главная:'
fetch /
cp "$tmp/body" "$tmp/home"
# Получив сертификат, обратный прокси уводит http на https, и каждая проверка
# ниже упала бы по одной причине. Сказать это один раз.
if [ "$mode" = resolve ] && [ "$scheme" = http ] \
    && { [ "$status" = 301 ] || [ "$status" = 308 ]; } \
    && contains "$(header location)" 'https://'; then
    echo "сервер уводит http на https ($(header location)): повторите с --scheme https" >&2
    exit 2
fi
check 'главная отвечает 200' "$(got)" test "$status" = 200
# Не ответил никто: каждая проверка ниже отсидела бы свой таймаут и повторила
# ту же новость. Именно в такой момент смоук обычно и запускают.
if [ "$status" = 000 ]; then
    echo >&2
    echo 'смоук УПАЛ: сервер не отвечает, остальные проверки не запускались' >&2
    exit 1
fi
check 'главная несёт маркер приложения' "нет в теле: $(cfg marker)" has "$tmp/home" "$(cfg marker)"
no_forbidden "$tmp/home" && home_clean=0 || home_clean=1
check 'главная без запрещённых фрагментов' "в теле: $forbidden_found" test "$home_clean" = 0
check 'главная без ссылок с двойным слэшем' 'источник вида //каталог/, браузер примет его за имя хоста' \
    no_double_slash "$tmp/home"
check 'главная без ссылок на внутренние адреса' 'ссылка на localhost, частный адрес или имя контейнера' \
    no_internal_links "$tmp/home"

# Главный отказ этой области: после оборванного восстановления каждый адрес
# отвечает 200 и рендерит главную. По кодам такой сайт исправен, поэтому
# сравниваются тела.
echo 'Внутренние страницы:'
page_count=0
while IFS= read -r page_path; do
    [ -n "$page_path" ] || continue
    page_count=$((page_count + 1))
    fetch "$page_path"
    cp "$tmp/body" "$tmp/page.$page_count"
    printf '%s\n' "$page_path" >"$tmp/page.$page_count.path"
    check "$page_path отвечает 200" "$(got)" test "$status" = 200
    if same_page "$tmp/body" "$tmp/home"; then page_is_home=1; else page_is_home=0; fi
    check "$page_path не копия главной" 'тело или <title> совпадают с главной' test "$page_is_home" = 0
    no_forbidden "$tmp/body" && page_clean=0 || page_clean=1
    check "$page_path без запрещённых фрагментов" "в теле: $forbidden_found" test "$page_clean" = 0
    check "$page_path без ссылок с двойным слэшем" 'источник вида //каталог/' no_double_slash "$tmp/body"
    check "$page_path без ссылок на внутренние адреса" 'localhost, частный адрес или имя контейнера' no_internal_links "$tmp/body"
done <"$tmp/cfg/page"

# Сравнение тел между собой не видит того, что испорчено одинаково везде:
# кириллица, ставшая вопросами, пропавший блок шаблона. Эталон это текст,
# выписанный из слепка старой площадки: он обязан найтись буквально.
echo 'Слепок старой площадки:'
if [ "$(cfg expect)" = none ]; then
    printf '  note  сравнение со слепком не выполнено: expect=none, эталона старой площадки нет\n'
else
    while IFS= read -r e; do
        expect_path=${e%% *}
        expect_text=${e#* }
        fetch "$expect_path"
        if [ "$status" = 200 ] && has "$tmp/body" "$expect_text"; then expect_ok=0; else expect_ok=1; fi
        check "$expect_path несёт текст слепка" "код $status, нет в теле: $expect_text" test "$expect_ok" = 0
    done <"$tmp/cfg/expect"
fi

# Попарно: копия может быть и не главной, а соседней страницы.
if [ "$page_count" -ge 2 ]; then
    duplicate=''
    i=1
    while [ "$i" -lt "$page_count" ] && [ -z "$duplicate" ]; do
        j=$((i + 1))
        while [ "$j" -le "$page_count" ]; do
            if same_page "$tmp/page.$i" "$tmp/page.$j"; then
                duplicate="$(cat "$tmp/page.$i.path") и $(cat "$tmp/page.$j.path")"
                break
            fi
            j=$((j + 1))
        done
        i=$((i + 1))
    done
    check 'тела внутренних страниц различаются' "совпадают $duplicate" test -z "$duplicate"
fi

echo 'Карта сайта и robots.txt:'
fetch "$sitemap_path"
check 'карта сайта отвечает 200' "$sitemap_path: $(got)" test "$status" = 200
check 'карта сайта это валидный XML' 'xmllint отверг ответ' valid_xml "$tmp/body"
check 'карта сайта это urlset или sitemapindex' 'в ответе нет ни <urlset, ни <sitemapindex' \
    grep -Eq '<(urlset|sitemapindex)[ >]' "$tmp/body"

# На заражённом хостинге robots.txt подменяли заглушкой, и 200 тут ничего не
# доказывает: сравнивается содержимое, байт в байт.
fetch /robots.txt
check 'robots.txt совпадает с эталоном побайтово' "$(got); эталон $robots_reference" \
    cmp -s "$tmp/body" "$robots_reference"

# Пустые обязательные поля отвергаются валидацией раньше отправки письма и
# сохранения обращения. Так проверяется путь веб-сервер, приложение, форма, и
# менеджеры площадки ничего не получают. Что письмо доходит до человека,
# доказывается отдельно, глазами во входящих.
echo 'Форма:'
if [ "$form_url" = none ]; then
    echo '  skip  формы на площадке нет (form_url=none): доказательство заявки не из этого смоука'
else
    # Страница с формой запрашивается заново прямо перед отправкой: CMS,
    # которая выдаёт токен формы на каждый рендер, к этому моменту уже
    # перевыпустила его на внутренних страницах, и токен с первой выдачи
    # главной был бы отвергнут как устаревший.
    fetch "$form_page"
    cp "$tmp/body" "$tmp/form_page"
    set --
    captured=1
    if [ -f "$tmp/cfg/form_capture" ]; then
        separator=$(printf '\001')
        while IFS= read -r capture; do
            capture_name=${capture%%=*}
            capture_regex=${capture#*=}
            capture_value=$(tr '\r\n' '  ' <"$tmp/form_page" \
                | sed -n "s${separator}.*${capture_regex}.*${separator}\\1${separator}p" | head -n 1)
            [ -n "$capture_value" ] || captured=0
            set -- "$@" --data-urlencode "$capture_name=$capture_value"
        done <"$tmp/cfg/form_capture"
        check 'форма найдена на странице' "form_capture не нашёл значение на $form_page" test "$captured" = 1
    fi
    [ ! -f "$tmp/cfg/form_param" ] || while IFS= read -r param; do
        set -- "$@" --data-urlencode "$param"
    done <"$tmp/cfg/form_param"
    [ ! -f "$tmp/cfg/form_field" ] || while IFS= read -r field; do
        set -- "$@" --data-urlencode "$field="
    done <"$tmp/cfg/form_field"
    [ ! -f "$tmp/cfg/form_header" ] || while IFS= read -r form_header; do
        set -- "$@" -H "$form_header"
    done <"$tmp/cfg/form_header"
    # Без единого поля curl ушёл бы GET-ом, а проверяется именно POST.
    fetch "$form_url" -X POST "$@"
    check 'форма: POST дошёл до обработчика' "$form_url: $(got), ждали $form_status" \
        test "$status" = "$form_status"
    form_rejected=1
    [ ! -f "$tmp/cfg/form_rejected" ] || while IFS= read -r marker; do
        has "$tmp/body" "$marker" || form_rejected=0
    done <"$tmp/cfg/form_rejected"
    [ ! -f "$tmp/cfg/form_accepted" ] || while IFS= read -r marker; do
        ! has "$tmp/body" "$marker" || form_rejected=0
    done <"$tmp/cfg/form_accepted"
    check 'форма отвергает пустую отправку' 'нет ошибок валидации по пустым полям, либо ответ об успехе' \
        test "$form_rejected" = 1
    set --
fi

# Дальше всё зависит от публичной записи: сертификат и www обратный прокси
# получает только после переключения. До него эти проверки пройти не могут, и
# честнее сказать это вслух, чем промолчать.
echo 'Публичное имя: www, https:'
if [ "$mode" = resolve ]; then
    for label in "$tls_label" "$www_label" "$http_label"; do
        defer "$label" 'проверяется только через публичный DNS: повторите без --resolve после переключения'
    done
else
    fetch_url "https://www.$HOST$www_path"
    www_location=$(header location)
    check "$www_label" "$(got), Location: $www_location" \
        test "$status:$www_location" = "301:https://$HOST$www_path"

    # Обратный прокси отвечает 308; 301 от другого фронта ничем не хуже.
    fetch_url "http://$HOST/"
    http_location=$(header location)
    if { [ "$status" = 301 ] || [ "$status" = 308 ]; } && [ "$http_location" = "https://$HOST/" ]; then
        http_ok=0
    else
        http_ok=1
    fi
    check "$http_label" "$(got), Location: $http_location" test "$http_ok" = 0
fi

echo
if [ "$failed" -ne 0 ]; then
    printf 'смоук УПАЛ: проверок не прошло %s, отложено %s\n' "$failed" "$deferred" >&2
    exit 1
fi
printf 'смоук OK (режим %s): отложено проверок %s\n' "$mode" "$deferred"
