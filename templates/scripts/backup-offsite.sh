#!/bin/sh
# Внешняя копия последнего проверенного набора, шифрованная публичным ключом.
#
#   scripts/backup-offsite.sh            из каталога отрендеренного стека, от root
#   scripts/backup-offsite.sh --verify   сверить обратным чтением и эту копию
#
# Отдельно от backup.sh намеренно: сломанное внешнее хранилище не должно
# лишать площадку локальных наборов.
#
# Шифрование age по получателю (age1...). Закрытого ключа на сервере нет, и
# строку с ним скрипт отвергает: одна компрометация сервера не должна забирать
# и площадку, и архив. Следствие: расшифровать копию здесь нельзя, поэтому
# доставка сверяется обратным чтением шифротекста, а расшифровку проверяет
# владелец ключа по BACKUP-RECOVERY.md.
#
# Первая копия в каждое хранилище сверяется всегда: пока хоть раз не
# доказано, что оно отдаёт то, что приняло, расписанию верить не на чем. Смена
# remote= снова делает копию первой. Последующие только по --verify, чтобы не
# качать архив целиком каждую неделю.
#
# Старые копии этот скрипт не удаляет и не должен: учётка, которой сервер
# может стирать внешние копии, отдаёт их вместе с сервером. Срок хранения
# задаётся правилами самого хранилища.
#
# Код 0: копия отправлена (и сверена, если сверялась). Код 1: сбой отправки
# или сверки. Код 2: настройки неполны или небезопасны.
set -eu
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
stack=$(cd "$script_dir/.." && pwd)
conf=${OFFSITE_CONF:-$stack/offsite.conf}
backup_conf=${BACKUP_CONF:-$stack/backup.conf}
slug={{SLUG}}

fail() { echo "внешняя копия: $*" >&2; exit 1; }
refuse() { echo "внешняя копия: $*" >&2; exit 2; }

verify_always=0
while [ "$#" -gt 0 ]; do
    case $1 in
        --verify) verify_always=1; shift ;;
        *) refuse "неизвестный аргумент: $1" ;;
    esac
done

[ -f "$conf" ] || refuse "нет файла настроек: $conf"
[ -f "$backup_conf" ] || refuse "нет файла настроек бэкапа: $backup_conf"
# Пробелы вокруг ключа и значения срезаются, как в backup.sh и у сторожа.
conf_get() { sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | sed 's/[[:space:]]*$//' | tail -n 1; }

recipient=$(conf_get "$conf" recipient)
remote=$(conf_get "$conf" remote)
backup_dir=$(conf_get "$backup_conf" backup_dir)

# Сначала проверка на закрытый ключ, и без эха значения: сообщение об ошибке
# уходит в журнал systemd, а там ключу не место тем более.
case $recipient in
    *AGE-SECRET-KEY*) refuse 'в recipient закрытый ключ; на сервере держат только публичный age1...' ;;
    age1*) ;;
    '') refuse 'recipient не задан' ;;
    *) refuse 'recipient должен быть публичным ключом age1...' ;;
esac
[ -n "$remote" ] || refuse 'remote не задан'
remote=${remote%/}

[ "$(id -u)" -eq 0 ] || fail 'запускать от root: каталог наборов закрыт для остальных'
for tool in age rclone tar sha256sum flock awk; do
    command -v "$tool" >/dev/null 2>&1 || fail "нет $tool"
done
[ -d "$backup_dir" ] || fail "нет каталога наборов $backup_dir"

exec 9>"$backup_dir/.offsite.lock"
flock -n 9 || fail 'другая внешняя копия уже идёт'

# Последний завершённый набор по дате в имени, как считает ротация бэкапа.
latest=''
for d in "$backup_dir"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-"$slug"; do
    [ -f "$d/SHA256SUMS" ] && latest=$(basename "$d")
done
[ -n "$latest" ] || fail 'ни одного завершённого набора нет'
(cd "$backup_dir/$latest" && sha256sum -c --quiet SHA256SUMS) || fail "набор $latest не сходится со своими суммами"

cipher=$backup_dir/.offsite-$latest.tar.age
tar_failed=$cipher.tar-failed
trap 'rm -f -- "$cipher" "$tar_failed"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Код tar в конвейере теряется, а оборванный архив age зашифрует исправно.
{ tar -C "$backup_dir" -cf - "$latest" || : >"$tar_failed"; } | age -r "$recipient" -o "$cipher"
[ ! -e "$tar_failed" ] || fail "tar оборвался на наборе $latest"
[ -s "$cipher" ] || fail 'шифрование не дало результата'
local_sum=$(sha256sum "$cipher" | awk '{print $1}')

target=$remote/$latest.tar.age
rclone copyto "$cipher" "$target" || fail "отправка в $target не удалась"
echo "отправлено: $latest -> $target ($(wc -c <"$cipher" | tr -d ' ') байт)"

marker=$backup_dir/.offsite-verified
verified_here() { [ -f "$marker" ] && awk -v r="$remote/" 'index($3, r) == 1 { found = 1 } END { exit !found }' "$marker"; }
if [ "$verify_always" -eq 1 ] || ! verified_here; then
    remote_sum=$(rclone cat "$target" | sha256sum | awk '{print $1}')
    [ "$remote_sum" = "$local_sum" ] || fail "обратное чтение не совпадает с отправленным: $target"
    printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$latest" "$target" >>"$marker"
    echo 'обратное чтение: совпало'
else
    echo 'обратное чтение: пропущено, первая копия в это хранилище уже сверена; --verify сверит эту'
fi
