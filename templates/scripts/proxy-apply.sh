#!/bin/sh
# Добавляет блок этой площадки в общий /opt/stacks/caddy/Caddyfile и применяет
# его перезагрузкой конфигурации. Запускать на VPS от root, после рендера
# стека, до и после переключения DNS.
#
# Ради чего вся осторожность: в общем Caddyfile обычным делом стоят соседние
# площадки, каждая уже продаёт. `docker compose up` на контейнере обратного
# прокси уронил бы их всех разом, поэтому контейнер не пересоздаётся ни при
# каких обстоятельствах — только правка файла и `caddy reload`.
#
# Две грабли, обе не гипотетические:
#
# 1. Caddyfile смонтирован в контейнер отдельным файлом, то есть привязан к
#    inode. `sed -i` и `mv` подменяют файл новым, контейнер продолжает читать
#    старый, а `caddy validate` и `reload` рапортуют успех по той копии,
#    которой уже нет. Поэтому запись идёт через `cat >` (тот же inode), а
#    дальше контрольная сумма сверяется внутри и снаружи.
# 2. Блок до переключения DNS обязан быть http://. Домен пока указывает на
#    старый хостинг, HTTP-01 уйдёт туда, и повторные отказы упрутся в лимиты
#    Let's Encrypt.
#
# Скрипт идемпотентен: повторный запуск с уже добавленным блоком ничего не
# дописывает, но проверки прогоняет.
set -eu

caddy_dir=/opt/stacks/caddy
caddy_container=caddy
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
block_source=$root/caddy/site.Caddyfile

while [ "$#" -gt 0 ]; do
    case $1 in
        --caddy-dir)       caddy_dir=${2:?}; shift 2 ;;
        --caddy-container) caddy_container=${2:?}; shift 2 ;;
        --block-source)    block_source=${2:?}; shift 2 ;;
        *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
    esac
done
caddyfile=$caddy_dir/Caddyfile

[ -f "$caddyfile" ] || { echo "Нет $caddyfile" >&2; exit 1; }
[ -f "$block_source" ] || { echo "Нет $block_source" >&2; exit 1; }

say() { printf '%s\n' "$*"; }
die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

# Домен и активный блок площадки читаются из отрендеренного файла, а не
# передаются отдельным аргументом: {{DOMAIN}} в нём уже подставлен рендером, и
# держать значение в двух местах значит дать им разойтись.
domain=$(sed -n 's/^http:\/\/\([^ {]*\) {$/\1/p' "$block_source" | head -1)
[ -n "$domain" ] || die "не нашёл активный блок http://<домен> в $block_source"

block=$(awk -v start="^http://$(printf '%s' "$domain" | sed 's/[.[\*^$/]/\\&/g') \\{" '
    $0 ~ start { inside = 1 }
    inside { print }
    inside && $0 == "}" { exit }
' "$block_source")
[ -n "$block" ] || die "не собрал блок http://$domain из $block_source"

# Сосед жив, если отвечает через обратный прокси по настоящему имени. Список
# соседей не хранится нигде: он читается прямо из общего Caddyfile на момент
# запуска, поэтому скрипт не может забыть про площадку, добавленную вчера.
#
# Блок соседа до его собственного переключения DNS выглядит как
# `http://домен {`, после — как `домен, www.домен {`. Оба top-level (без
# отступа), у обоих на строке первым идёт домен. Строка со схемой снимается
# до разбора имени: иначе `http://` соседа ловится символьным классом первого
# домена и остаётся в списке кандидатом на резолв.
list_neighbours() {
    grep -E '^[^#[:space:]].*\{[[:space:]]*$' "$caddyfile" \
        | sed -E 's/^http:\/\///' \
        | sed -E 's/^([^, ]+).*/\1/' \
        | grep -vFx "$domain" \
        | sort -u || true
}

# До собственного переключения DNS сосед обслуживается блоком `http://домен`
# без TLS, и Caddy его не поднимает сам. Поэтому сперва https, и только на
# отказе — http: иначе площадка в процессе переезда всегда числилась бы
# недоступной, хотя на самом деле просто ещё не переключена.
neighbour_status() {
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
        --resolve "$1:443:127.0.0.1" "https://$1/" 2>/dev/null) || true
    code=${code:-000}
    case $code in
        000)
            code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
                --resolve "$1:80:127.0.0.1" "http://$1/" 2>/dev/null) || true
            ;;
    esac
    printf '%s' "${code:-000}"
}

# Список битых соседей собирается в файл, а не в переменную обычного цикла:
# `printf | while` запускает тело в подоболочке, и `failed=1`, выставленный
# там, до `return` в этой функции не доедет — проверка после правки молча
# считала бы упавшего соседа живым.
check_neighbours() {
    stage=$1
    neighbours=$(list_neighbours)
    [ -n "$neighbours" ] || { say "  $stage: соседей в общем конфиге нет"; return 0; }
    down=$(mktemp)
    printf '%s\n' "$neighbours" > "$down.hosts"
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        code=$(neighbour_status "$host")
        case "$code" in
            2??|3??) say "  $stage: $host → $code" ;;
            *) say "  $stage: $host → $code — НЕ ОТВЕЧАЕТ"; echo "$host" >> "$down" ;;
        esac
    done < "$down.hosts"
    failed=0
    [ -s "$down" ] && failed=1
    rm -f "$down" "$down.hosts"
    return $failed
}

container_sum() { docker exec "$caddy_container" md5sum /etc/caddy/Caddyfile | cut -d' ' -f1; }
host_sum() { md5sum "$caddyfile" | cut -d' ' -f1; }
container_inode() { docker exec "$caddy_container" stat -c '%i' /etc/caddy/Caddyfile; }
host_inode() { stat -c '%i' "$caddyfile"; }

# Без живого контейнера дальше идти нельзя: все сверки и reload ходят через
# docker exec, и без этой проверки скрипт упал бы на невнятной ошибке exec.
# Проверка через `docker ps --filter`, не `docker inspect --format`: формат
# инспекции у Docker использует тот же синтаксис двойных фигурных скобок, что
# и заглушки этого репозитория, и рендер принял бы его за незаменённую.
running=$(docker ps --filter "name=^/${caddy_container}\$" --filter status=running -q)
[ -n "$running" ] || \
    die "контейнер $caddy_container не запущен — сначала поднять его, иначе соседи и так лежат"

say '--- Соседи до правки ---'
check_neighbours 'до' || die 'до правки уже что-то не отвечает, разбираться с этим, а не деплоить'

# Расхождение содержимого до начала работы означает, что кто-то правил файл
# мимо этого скрипта. Перезагрузка тогда применила бы не то, что лежит на диске.
[ "$(host_sum)" = "$(container_sum)" ] || \
    die 'Caddyfile на хосте и в контейнере разошлись по содержимому ещё до правки — сначала разобраться, чья копия верная'

# Совпадения контрольной суммы мало: если однажды бинд отвязали пересозданием
# контейнера мимо этого скрипта, он держит отдельный прибитый инод, а
# совпадение содержимого это просто следствие того, что в прошлый раз записали
# оба места. Инод показывает правду: пока он разный, запись на хосте до Caddy
# НЕ доезжает, и дальше пишем в оба места явно, а не полагаясь на бинд.
if [ "$(host_inode)" = "$(container_inode)" ]; then
    say 'Бинд Caddyfile целый: запись на хосте видна контейнеру'
else
    say 'ВНИМАНИЕ: бинд Caddyfile отвязан — контейнер держит отдельный инод.'
    say '  Файл на хосте источник правды для будущего пересоздания контейнера,'
    say '  но не живой конфиг. Пишем в оба места.'
fi

backup=$caddy_dir/Caddyfile.bak-$(date -u +%Y%m%dT%H%M%SZ)
cp -p "$caddyfile" "$backup"
say "Резервная копия: $backup"

original=$(cat "$caddyfile")

restore() {
    say 'Откат к резервной копии'
    printf '%s\n' "$original" > "$caddyfile"
    docker exec -i "$caddy_container" sh -c 'cat > /etc/caddy/Caddyfile' < "$caddyfile"
    docker exec "$caddy_container" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile || \
        say 'ВНИМАНИЕ: откат записан, но reload не прошёл — проверить Caddy руками'
}

# Совпадение ищется по домену в любой форме блока, а не только по http-форме:
# после переключения блок станет «домен, www.домен {», и проверка ровно на
# http-форму не нашла бы его и дописала бы второй, уже лишний блок.
domain_re=$(printf '%s' "$domain" | sed 's/\./\\./g')
if grep -Eq "^[[:space:]]*(http://)?${domain_re}[[:space:],{]" "$caddyfile"; then
    say "Блок $domain уже на месте, файл не меняется"
else
    printf '%s\n\n%s\n' "$original" "$block" > "$caddyfile"
    say "Блок $domain дописан"
fi

# В контейнер пишем всегда, а не только при расхождении: при отвязанном бинде
# запись на хосте до Caddy не доходит, и условная ветка молча оставила бы его
# со старым конфигом. Лишняя запись тем же содержимым ничего не портит.
docker exec -i "$caddy_container" sh -c 'cat > /etc/caddy/Caddyfile' < "$caddyfile"
[ "$(host_sum)" = "$(container_sum)" ] || { restore; die 'контрольная сумма хоста и контейнера так и не сошлась'; }
say "контрольная сумма совпала внутри и снаружи: $(host_sum)"

docker exec "$caddy_container" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || {
    restore
    die 'caddy validate не принял конфигурацию'
}
say 'Конфигурация валидна'

docker exec "$caddy_container" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile || {
    restore
    die 'reload не прошёл'
}
say 'Caddy перечитал конфигурацию'

say '--- Соседи после правки ---'
check_neighbours 'после' || { restore; die 'после правки сосед перестал отвечать, откатились'; }

say '--- Трассер нового стека ---'
tracer=$(curl -sS -i --max-time 15 -H "Host: $domain" http://127.0.0.1/ 2>/dev/null || true)
if printf '%s' "$tracer" | grep -qi '^x-stack-tracer: php-fpm'; then
    say "  $domain отдаёт трассер от php-fpm"
else
    restore
    die "$domain не отдал трассер: $(printf '%s' "$tracer" | head -1)"
fi

say 'Готово'
