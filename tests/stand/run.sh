#!/bin/sh
# Локальный стенд ядра: рендер, подъём, проверка изоляции живыми пробниками,
# снос. Боевой сервер не нужен. Проверяется поведение, не устройство.
set -u
cd "$(dirname "$0")/../.."
work=tests/stand/.work
fails=0
fail() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }
pass() { printf 'PASS  %s\n' "$1"; }

command -v docker >/dev/null 2>&1 || { echo 'docker не найден' >&2; exit 2; }

# Общая сеть объявлена в стеке как external: без неё compose падает невнятно.
if ! docker network inspect stand-edge >/dev/null 2>&1; then
    echo 'общей сети stand-edge нет' >&2
    echo 'создайте её: docker network create stand-edge' >&2
    exit 2
fi

rm -rf "$work"; mkdir -p "$work"
sed 's/^edge_network:.*/edge_network: stand-edge/' tests/fixtures/example-site.yaml > "$work/profile.yaml"
./bin/render --profile "$work/profile.yaml" --out "$work/stack" || exit 1

cleanup() {
    docker rm -f example-stand-runner >/dev/null 2>&1 || true
    docker volume rm example-stand-backups example-stand-offsite >/dev/null 2>&1 || true
    (cd "$work/stack" && docker compose down -v >/dev/null 2>&1) || true
}
trap cleanup EXIT

(cd "$work/stack" && docker compose up -d --build) || { fail 'стек не поднялся'; exit 1; }
sleep 20

web=example-nginx
app=example-php-fpm
db=example-mariadb

# 1. Ни одного опубликованного порта.
published=$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E "^($web|$app|$db) " | grep '\->' || true)
[ -z "$published" ] && pass 'наружу не опубликован ни один порт' \
  || fail "опубликованы порты: $published"

# 2. База недостижима из веб-сервера: она только во внутренней сети с приложением.
if docker exec "$web" sh -c "nc -z -w2 $db 3306" >/dev/null 2>&1; then
    fail 'веб-сервер достаёт до базы'
else
    pass 'база недостижима из веб-сервера'
fi

# 3. Запреты: трассер живыми пробниками, из каталога отрендеренного стека.
tracer="$work/stack/scripts/verify-tracer.sh"
if "$tracer" >"$work/tracer.out" 2>&1; then
    pass 'трассер: запреты подтверждены'
else
    fail 'трассер нашёл дыру в запретах'
    sed 's/^/      | /' "$work/tracer.out" >&2
fi

# 3a. Отрицательный контроль: трассер, который никогда не падал, ничего не
#     гарантирует. Блок запрета точечных файлов переставляется ниже общего
#     блока PHP, и трассер обязан упасть ровно на точечных путях. Заливка через
#     `cat >`, не заменой файла: конфиг смонтирован по иноду, и подменённый
#     файл контейнер бы не увидел, а reload отчитался бы по старой копии.
conf="$work/stack/nginx/default.conf"
cp "$conf" "$work/default.conf.orig"
python3 - "$conf" >"$work/default.conf.broken" <<'PY' || { fail 'блок запрета точечных файлов в шаблоне не найден: стенд отстал от шаблона'; exit 1; }
import sys
text = open(sys.argv[1]).read()
block = "    location ~ /\\.(?!well-known/) {\n        deny all;\n    }\n"
assert block in text, "блок запрета точечных файлов не найден"
text = text.replace(block, "", 1)
cut = text.rstrip().rfind("}")
sys.stdout.write(text[:cut] + "\n" + block + "}\n")
PY
reload_web() {
    docker exec "$web" nginx -t >/dev/null 2>&1 && docker exec "$web" nginx -s reload >/dev/null 2>&1
    sleep 1
}
cat "$work/default.conf.broken" >"$conf"
reload_web
"$tracer" >"$work/tracer-broken.out" 2>&1; broken_code=$?
if [ "$broken_code" -eq 1 ] \
    && grep -q 'FAIL  /.verify-tracer-hidden/shell.php ИСПОЛНИЛСЯ' "$work/tracer-broken.out" \
    && grep -q 'FAIL  /.verify-tracer-probe.php ИСПОЛНИЛСЯ' "$work/tracer-broken.out"; then
    pass 'переставленный запрет точечных файлов роняет трассер'
else
    fail "трассер не заметил переставленный запрет (код $broken_code)"
    sed 's/^/      | /' "$work/tracer-broken.out" >&2
fi
cat "$work/default.conf.orig" >"$conf"
reload_web
if "$tracer" >/dev/null 2>&1; then
    pass 'порядок возвращён, трассер снова зелёный'
else
    fail 'после возврата порядка трассер не зелёный'
fi

# 3b. Путь, закрытый адаптером, ядро не закрывает. Значит --deny обязан
#     покраснеть, иначе адаптерная проверка ничего не доказывает.
if "$tracer" --deny /verify-tracer-api.php >"$work/tracer-deny.out" 2>&1; then
    fail '--deny на незакрытом пути не покраснел'
elif grep -q 'FAIL  /verify-tracer-api.php ИСПОЛНИЛСЯ' "$work/tracer-deny.out"; then
    pass '--deny ловит незакрытую точку входа'
else
    fail '--deny покраснел не той проверкой'
    sed 's/^/      | /' "$work/tracer-deny.out" >&2
fi

# 3d. Запреты адаптера в стеке, а каталог загрузок CMS не назван: трассер по
#     /uploads/ ядра был бы зелёным при открытой медиатеке CMS, поэтому отказ.
printf '# запреты адаптера стенда\n' >"$work/stack/nginx/adapter/stand.conf"
"$tracer" >"$work/tracer-noup.out" 2>&1; code=$?
[ "$code" -eq 2 ] && grep -q -- '--uploads не задан' "$work/tracer-noup.out" \
    && pass 'запреты адаптера без --uploads: отказ, а не зелень по /uploads/ ядра' \
    || { fail "запреты адаптера без --uploads: код $code, ждали 2"; sed 's/^/      | /' "$work/tracer-noup.out" >&2; }
"$tracer" --uploads uploads >/dev/null 2>&1 && pass 'с явным --uploads трассер идёт и при запретах адаптера' \
    || fail 'с явным --uploads трассер не зелёный'
rm -f "$work/stack/nginx/adapter/stand.conf"

# 3e. --allow с двух сторон: каталог, где PHP исполняется, зелёный; каталог,
#     накрытый запретом, красный. Иначе проверка ничего не доказывает.
"$tracer" --allow verify-tracer-open >"$work/tracer-allow.out" 2>&1 \
    && grep -q 'PASS  /verify-tracer-open/ исполняет PHP' "$work/tracer-allow.out" \
    && pass '--allow: исполняемый каталог подтверждён' \
    || { fail '--allow на исполняемом каталоге не зелёный'; sed 's/^/      | /' "$work/tracer-allow.out" >&2; }
"$tracer" --allow uploads/verify-tracer-shut >"$work/tracer-allow.out" 2>&1; code=$?
[ "$code" -eq 1 ] && grep -q 'FAIL  /uploads/verify-tracer-shut/ не исполнил пробник' "$work/tracer-allow.out" \
    && pass '--allow ловит запрет, накрывший исполняемый каталог' \
    || { fail "--allow под запретом: код $code, ждали 1"; sed 's/^/      | /' "$work/tracer-allow.out" >&2; }

# Уборка после прогонов выше, пока в docroot не положили ничего своего.
leftovers=$(docker exec "$app" sh -c 'cd /var/www/html && find . -name "*verify-tracer*" -o -name readme.html -o -name .user.ini')
[ -z "$leftovers" ] && pass 'после трассера в docroot не осталось пробников' \
  || fail "трассер оставил после себя: $leftovers"

# 3c. Уборка: настоящий файл сайта, совпавший по имени с пробником, трассер
#     не трогает, а своё убирает целиком. Настоящий readme.html несёт
#     содержимое, и трассер обязан проверить, что тело закрыто и для него.
docker exec "$app" sh -c "printf 'REAL-SITE-FILE' > /var/www/html/readme.html"
"$tracer" >"$work/tracer-real.out" 2>&1 || { fail 'трассер покраснел на настоящем readme.html'; sed 's/^/      | /' "$work/tracer-real.out" >&2; }
if [ "$(docker exec "$app" cat /var/www/html/readme.html)" = REAL-SITE-FILE ]; then
    pass 'чужой файл с именем пробника пережил трассер'
else
    fail 'трассер перезаписал или удалил чужой readme.html'
fi
docker exec "$app" rm -f /var/www/html/readme.html
leftovers=$(docker exec "$app" sh -c 'cd /var/www/html && find . -name "*verify-tracer*"')
[ -z "$leftovers" ] && pass 'после прогона рядом с чужим файлом пробников не осталось' \
  || fail "трассер оставил после себя: $leftovers"

# 4. Короткого псевдонима в общей сети нет: иначе он столкнётся с соседом.
aliases=$(docker inspect "$web" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{range $v.Aliases}}{{.}} {{end}};{{end}}')
case $aliases in
    *"=nginx "*|*"=nginx;"*) fail "в сетях есть короткий псевдоним nginx: $aliases" ;;
    *) pass 'короткого псевдонима nginx в сетях нет' ;;
esac

# 5. Лимиты заданы: всплеск одного арендатора не должен двигать соседа.
for c in "$web" "$app" "$db"; do
    lim=$(docker inspect "$c" --format '{{.HostConfig.Memory}}')
    [ "$lim" -gt 0 ] && pass "$c: лимит памяти задан" || fail "$c: лимит памяти не задан"
done

# 6. Эксплуатация: бэкап, внешняя копия, сторож.
. tests/stand/ops.sh

[ "$fails" -eq 0 ] || { echo "стенд: $fails находок" >&2; exit 1; }
echo 'стенд: изоляция, запреты, бэкапы и сторож подтверждены'
